## Helper functions to create Voronoi geometry
extends Object

class_name VoronoiGenerator

# End-to-end function that samples points, creates tetrahedra, and generates voronoi cells (asyncronously).
# This is the best way to create fractures from a mesh. REQUIRES THE VoronoiWorker TO WORK!
# Make sure you listen to the signal as described in README.md. 
static func create_from_mesh(mesh: MeshInstance3D, options: VoronoiGeneratorConfig) -> void:
    var points = sample_points(mesh.mesh, options)
    var tetrahedra = create_delauney_tetrahedra(points)
    # Dictionary[Vector3, int]
    var point_to_index_map: Dictionary[Vector3, int] = {}
    for i in range(len(points)):
        if points[i] not in point_to_index_map:
            point_to_index_map[points[i]] = i

    generate_voronoi_cells(mesh, tetrahedra, points, point_to_index_map)

# This function is used to sample points inside a bounding box. These points
# can be used for Delauney Tetrahedronization.
static func sample_points(mesh: Mesh, options: VoronoiGeneratorConfig) -> Array[Vector3]:
    var aabb = mesh.get_aabb()
    var random_seed = options.random_seed
    var num_samples = options.num_samples
    var sample_points: Array[Vector3] = []
    var rng = RandomNumberGenerator.new()
    var offset = 0
    var texture3d = options.texture

    # Randomly sample points
    for i in range(num_samples):
        # Generate random position in AABB
        rng.seed = random_seed + offset
        var x_norm: float = rng.randf()
        offset += 1
        rng.seed = random_seed + offset
        var y_norm: float = rng.randf()
        offset += 1
        rng.seed = random_seed + offset
        var z_norm: float = rng.randf()
        offset += 1

        var pos_in_aabb = Vector3(x_norm, y_norm, z_norm)

        # If texture3d is provided, use rejection sampling based on texture value
        if texture3d != null:
            # Sample the texture at the normalized position (0-1)
            var texture_value = sample_3d_texture(texture3d, pos_in_aabb)

            # Reject sample if random value is greater than texture value
            rng.seed = random_seed + offset
            offset += 1
            if rng.randf() > texture_value:
                # Skip this sample and try again
                i -= 1
                continue

        # Convert normalized position to world position
        var x: float = aabb.position.x + x_norm * aabb.size.x
        var y: float = aabb.position.y + y_norm * aabb.size.y
        var z: float = aabb.position.z + z_norm * aabb.size.z

        sample_points.append(Vector3(x, y, z))

    # Missing geometry can happen if we don't add the 8 endpoints of the AABB
    var endpoints: Array[Vector3] = []
    for i in range(8):
        endpoints.append(aabb.get_endpoint(i))

    return sample_points + endpoints

# Helper function to sample a Texture3D
# Returns value in range 0.0 to 1.0
static func sample_3d_texture(texture: Texture3D, normalized_position: Vector3) -> float:
    # Ensure position is in 0-1 range
    var pos = normalized_position.clamp(Vector3.ZERO, Vector3.ONE)

    # Get texture dimensions
    var width = texture.get_width()
    var height = texture.get_height()
    var depth = texture.get_depth()

    # Convert normalized position to texture coordinates
    var tx = int(pos.x * (width - 1))
    var ty = int(pos.y * (height - 1))
    var tz = int(pos.z * (depth - 1))

    # Get color at position
    var color = texture.get_data()[tz].get_pixel(tx, ty)

    # Use grayscale value (or you could use a specific channel or combination)
    # Converting color to grayscale using standard luminance formula
    return color.r * 0.299 + color.g * 0.587 + color.b * 0.114

# Creates a set of tetrahedra from the given point cloud
static func create_delauney_tetrahedra(points: Array[Vector3]) -> Array[Tetrahedron]:
    var packed_points_array = PackedVector3Array(points)
    var delauney_indices = Geometry3D.tetrahedralize_delaunay(points)

    if delauney_indices == null or delauney_indices.size() == 0:
        VoronoiLog.err("Failed to tetrahedralize. This probably means all points are coplanar, e.g. the case of a plane or 2D geometry (this algorithm is meant for 3D shapes).")
        return []

    var tetrahedra: Array[Tetrahedron] = []

    # Process tetrahedra. Each tetrahedron has 4 points.
    for i in range(0, delauney_indices.size(), 4):
        var i0: int = delauney_indices.get(i)
        var i1: int = delauney_indices.get(i + 1)
        var i2: int = delauney_indices.get(i + 2)
        var i3: int = delauney_indices.get(i + 3)

        var v0: Vector3 = points[i0]
        var v1: Vector3 = points[i1]
        var v2: Vector3 = points[i2]
        var v3: Vector3 = points[i3]

        var tetrahedron = Tetrahedron.new()
        tetrahedron.vertices = [v0, v1, v2, v3] as Array[Vector3]
        tetrahedron.indices = [i0, i1, i2, i3] as Array[int]
        tetrahedra += [tetrahedron]

    return tetrahedra

# Create voronoi cell meshes using the circumcenters of the given tetrahedra
static func generate_voronoi_cells(clipping_mesh: MeshInstance3D, tetrahedra: Array[Tetrahedron], points: Array[Vector3], point_index_map: Dictionary) -> void:
    # Map: Site Index -> List of Circumcenters (potential Voronoi cell vertices)
    # Dictionary[int, Array[Vector3]]
    var potential_cell_vertices: Dictionary[int, Array] = {}

    for tetrahedron in tetrahedra:
        var center: Vector3 = tetrahedron.try_calculate_tetrahedron_circumcenter()

        if center != null:
            for point_index in tetrahedron.indices:
                # Is this point one of our target Voronoi sites?
                # Check efficiently if point_index corresponds to a key in point_index_map values
                # A reverse lookup or checking if points[point_index] is a site is needed.
                var current_point: Vector3 = points[point_index]
                # Efficient check if this point is a site
                if point_index_map.has(current_point):
                    # Get the index used as key for potential_cell_vertices
                    var site_list_index: int = point_index_map[current_point]

                    if !potential_cell_vertices.has(site_list_index):
                        potential_cell_vertices[site_list_index] = [] as Array[Vector3]

                    potential_cell_vertices[site_list_index] += [center]

    var cells: Array[VoronoiCell] = []

    for key in potential_cell_vertices:
        var voronoi_cell = VoronoiCell.new()

        voronoi_cell.vertices = potential_cell_vertices[key]
        voronoi_cell.site = points[key]
        cells += [voronoi_cell]

    var worker = Engine.get_singleton("EditorVoronoiWorker") as VoronoiWorker
    worker.create_geometry_from_sites_async(clipping_mesh, cells)
