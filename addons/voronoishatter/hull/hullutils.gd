## Internal utility functions for creating the Voronoi geometry
extends Node

class_name HullUtils

# Used inernally for offloading non-thread-safe work onto the main thread
signal csg_clip_ready

# On the main thread: Creates a convex hull from the points and clips it to the given mask.
func _deferred_csg_clip(points: Array, csg_clip: CSGMesh3D, csg_mask: CSGMesh3D, sync: Semaphore) -> void:
    var shape_3d: ConvexPolygonShape3D = ConvexPolygonShape3D.new()
    shape_3d.set_points(PackedVector3Array(points))
    csg_clip.mesh = shape_3d.get_debug_mesh()
    
    add_child(csg_clip) # now safe
    csg_clip.add_child(csg_mask)

    # Resume waiting thread
    sync.post()

# Creates a mesh out of the points and clips it against the given mask_mesh
func clip_to_mesh(points: Array, mask_mesh: Mesh) -> VoronoiMesh:
    var center = mask_mesh.get_aabb().get_center()

    var csg_mask := CSGMesh3D.new()
    csg_mask.mesh = mask_mesh
    csg_mask.operation = CSGShape3D.OPERATION_INTERSECTION
    
    # Values will be filled in on the main thread
    var csg_clip := CSGMesh3D.new()

    var result_meshes = null

    # Defer CSG setup on main thread
    var sync := Semaphore.new()
    call_deferred("_deferred_csg_clip", points, csg_clip, csg_mask, sync )

    # Wait for deferred task to finish
    sync.wait() # blocks current thread until signaled

    # Now safe to access result
    csg_clip._update_shape()
   
    var resulting_mesh: ArrayMesh = csg_clip.bake_static_mesh()

    if not is_instance_valid(resulting_mesh):
        VoronoiLog.err("ClipCellToMesh: CSG result mesh is invalid for cell centered at %s." % center)
        return null
    
    if resulting_mesh.get_surface_count() == 0:
        return null

    var offset = resulting_mesh.get_aabb().get_center()
    resulting_mesh = recenter_mesh_origin(resulting_mesh)

    var voronoi_mesh = VoronoiMesh.new()
    voronoi_mesh.mesh = resulting_mesh
    voronoi_mesh.position = - offset

    return voronoi_mesh

func recenter_mesh_origin(mesh: ArrayMesh) -> ArrayMesh:
    var combined_aabb = mesh.get_aabb()
    var center = combined_aabb.get_center()

    var new_mesh = ArrayMesh.new()

    for surface in range(mesh.get_surface_count()):
        var arr = mesh.surface_get_arrays(surface)
        var vertices = arr[Mesh.ARRAY_VERTEX]

        if not len(vertices):
            continue

        # Offset all vertices by -center
        for i in range(vertices.size()):
            vertices[i] -= center

        # Preserve material
        var material = mesh.surface_get_material(surface)

        # Re-add the adjusted surface to the new mesh
        new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
        new_mesh.surface_set_material(surface, material)

    return new_mesh
