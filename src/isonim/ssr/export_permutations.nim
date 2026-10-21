## Bounded static exports discovered from real typed experiment reads.
import std/[algorithm, json, os, strutils, tables, sets]
import ../experiments
import ./canonical

type
  ExperimentPageRenderer* = proc(route: string; assignment: ExperimentAssignment): string {.closure.}
  ExperimentExport* = object
    files*: seq[string]
    routes*: JsonNode

proc comboKey*(key: string): string =
  ## URL-safe, injective encoding. It has no percent escapes for servers to
  ## decode and no path separators, even for arbitrary UTF-8 experiment keys.
  result = "~"
  for c in key: result.add toHex(ord(c), 2).toLowerAscii

proc experimentCombo*(assignment: Table[string, int]): string =
  ## The wire format uses sorted decoded keys and numeric enum ordinals.
  var keys: seq[string]
  for key in assignment.keys: keys.add key
  keys.sort()
  for key in keys:
    if result.len > 0: result.add ','
    result.add comboKey(key) & "=" & $assignment[key]

proc combinations(metadata: Table[string, JsonNode]; route: string): seq[Table[string, int]] =
  var keys: seq[string]
  for key in metadata.keys: keys.add key
  keys.sort()
  result = @[initTable[string, int]()]
  for key in keys:
    let count = metadata[key]["arms"].len
    if count == 0 or result.len > 8 div count:
      raise newException(ValueError, "static experiment route " & route &
        " exceeds eight combinations (" & $result.len & " × " & $count & ")")
    var expanded: seq[Table[string, int]]
    for assignment in result:
      for arm in 0 ..< count:
        var next = assignment
        next[key] = arm
        expanded.add next
    result = expanded

proc exportExperimentRoutes*(outputDir, origin: string; routes: openArray[string];
                             render: ExperimentPageRenderer): ExperimentExport =
  ## Discover the closure of conditionally read keys before emitting any page
  ## of a route. Every pass explores the complete bounded Cartesian product.
  ## The callback starts an experiment context in its own rendering root.
  result.routes = newJObject()
  var seen = initHashSet[string]()
  for route in routes:
    let parts = route.split('/')
    if not route.startsWith('/') or route == "/__x" or route.startsWith("/__x/") or
        '\\' in route or '?' in route or '#' in route or '%' in route or
        "." in parts or ".." in parts or "//" in route or
        (route != "/" and route.endsWith('/')) or route in seen:
      raise newException(ValueError, "invalid static route: " & route)
    seen.incl route
  for route in routes:
    var metadata = initTable[string, JsonNode]()
    var assignments: seq[Table[string, int]]
    while true:
      assignments = combinations(metadata, route)
      var changed = false
      for arms in assignments:
        let assignment = newExperimentAssignment()
        assignment.trackReads = true
        assignment.assign = arms
        discard render(route, assignment)
        for key, descriptor in assignment.metadata:
          if key notin metadata:
            metadata[key] = descriptor
            changed = true
          elif metadata[key] != descriptor:
            raise newException(ValueError, "inconsistent experiment metadata: " & key)
      if not changed: break
    var keys: seq[string]
    for key in metadata.keys: keys.add key
    keys.sort()
    let routeMetadata = newJObject()
    for key in keys: routeMetadata[key] = metadata[key]
    result.routes[route] = routeMetadata
    let suffix = route.strip(chars={'/'}) / "index.html"
    let canonical = newExperimentAssignment()
    let canonicalBody = withCanonicalUrl(render(route, canonical), origin.strip(trailing=true, chars={'/'}) & route)
    let canonicalPath = outputDir / suffix
    createDir(parentDir(canonicalPath))
    writeFile(canonicalPath, canonicalBody)
    result.files.add canonicalPath
    if keys.len > 0:
      for arms in assignments:
        let assignment = newExperimentAssignment()
        assignment.assign = arms
        let path = outputDir / "__x" / experimentCombo(arms) / suffix
        createDir(parentDir(path))
        writeFile(path, withCanonicalUrl(render(route, assignment), origin.strip(trailing=true, chars={'/'}) & route))
        result.files.add path
  let manifestPath = outputDir / "experiments-routes.json"
  writeFile(manifestPath, $result.routes)
  result.files.add manifestPath
