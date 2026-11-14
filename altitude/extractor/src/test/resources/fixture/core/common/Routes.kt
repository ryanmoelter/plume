package fixture.core

enum class Method {
  GET
}

class PathMethod(val path: String, val method: Method)

class Route(val spec: PathMethod, val handler: (String) -> String)

infix fun String.bind(method: Method): PathMethod = PathMethod(this, method)

infix fun PathMethod.to(handler: (String) -> String): Route = Route(this, handler)

val route: Route = "/x" bind Method.GET to { it }
