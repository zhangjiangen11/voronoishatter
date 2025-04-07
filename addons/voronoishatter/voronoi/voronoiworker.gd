extends Node

class_name VoronoiWorker

# Approach 1: mainly done for debugging, this is way slower than using a thread pool with workers.
# Creates Voronoi cells from the given points by clipping them against a given mesh.
func create_geometry_from_sites(mesh: Mesh, cells: Array[VoronoiCell]) -> Array[VoronoiMesh]:
    var voronoi_meshes: Array[VoronoiMesh] = []
    for cell in cells:
        # Didn't find enough circumcenters to generate the sites from
        if not cell.is_valid():
            continue

        var hull_utils = HullUtils.new()

        # Some of these circumcenters may be outside the shape of the mesh, so clip them to size
        var clipped_hull: VoronoiMesh = hull_utils.clip_to_mesh(cell.vertices, mesh)

        if not clipped_hull:
            continue

        # Add the clipped mesh as the result
        voronoi_meshes += [clipped_hull]

    return voronoi_meshes

# Approach 2: multithreading for quicker generation
signal mesh_generated(result: VoronoiWorkerResult)
signal voronoi_fracture_finished(mesh_instance: MeshInstance3D)

# Array[MeshInstance3D, VoronoiCell]
var task_queue: Array[Array] = []
var task_queue_mutex := Mutex.new()
var task_queue_semaphore := Semaphore.new()

var threads: Array[Thread] = []
var shutdown := false

# Track how many tasks per mesh_instance are still pending
var mesh_task_counts := {}
var mesh_task_mutex := Mutex.new()

func start_worker(worker_count: int):
    for i in worker_count:
        var thread := Thread.new()
        thread.start(_hull_calculation_worker_loop)
        threads.append(thread)

func create_geometry_from_sites_async(mesh_instance: MeshInstance3D, cells: Array[VoronoiCell]) -> void:
    var valid_count := 0

    task_queue_mutex.lock()
    for cell in cells:
        if cell.is_valid():
            task_queue.append([mesh_instance, cell])
            task_queue_semaphore.post()
            valid_count += 1
    task_queue_mutex.unlock()

    if valid_count > 0:
        mesh_task_mutex.lock()
        mesh_task_counts[mesh_instance] = mesh_task_counts.get(mesh_instance, 0) + valid_count
        mesh_task_mutex.unlock()

func _hull_calculation_worker_loop(_arg = null) -> void:
    while true:
        task_queue_semaphore.wait()
        if shutdown:
            break

        var mesh_instance: MeshInstance3D = null
        var cell: VoronoiCell = null

        task_queue_mutex.lock()
        if task_queue.size() > 0:
            var mesh_and_cell = task_queue.pop_back()
            mesh_instance = mesh_and_cell[0]
            cell = mesh_and_cell[1]
        task_queue_mutex.unlock()

        if cell != null and mesh_instance != null:
            var hull_utils = HullUtils.new()
            var clipped = hull_utils.clip_to_mesh(cell.vertices, mesh_instance.mesh)

            if clipped:
                var result = VoronoiWorkerResult.new()
                result.target_mesh = mesh_instance
                result.voronoi_mesh = clipped
                mesh_generated.emit(result)

            # Decrement task count and emit `voronoi_fracture_finished` if we just finished the last Voronoi Mesh
            mesh_task_mutex.lock()
            if mesh_task_counts.has(mesh_instance):
                mesh_task_counts[mesh_instance] -= 1
                if mesh_task_counts[mesh_instance] <= 0:
                    mesh_task_counts.erase(mesh_instance)
                    mesh_task_mutex.unlock()
                    voronoi_fracture_finished.emit(mesh_instance)
                else:
                    mesh_task_mutex.unlock()
