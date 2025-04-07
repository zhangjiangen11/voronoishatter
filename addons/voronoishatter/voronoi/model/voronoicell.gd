## Represents a voronoi "cell," a collection of vertices (Vector3) that are associated with a sample site
extends Object

class_name VoronoiCell

## Array[Vector3]
var vertices: Array = []
var site: Vector3

func is_valid() -> bool:
    return len(vertices) >= 4
