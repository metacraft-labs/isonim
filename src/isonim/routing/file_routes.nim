## isonim/routing/file_routes.nim
##
## File-based routing (M5). A compile-time macro scans a directory of
## `.nim` files and generates route definitions, following the convention
## used by SolidStart and Next.js:
##
##   pages/index.nim            → "/"
##   pages/about.nim            → "/about"
##   pages/users/index.nim      → "/users"
##   pages/users/[id].nim       → "/users/:id"
##   pages/users/[id]/posts.nim → "/users/:id/posts"
##
## Square brackets in file/directory names denote dynamic route segments.
## Since Nim cannot import modules whose names contain brackets, an
## underscore-prefixed alternative is also recognized:
##
##   pages/users/_id.nim        → "/users/:id"   (equivalent to [id].nim)
##   pages/users/_id/posts.nim  → "/users/:id/posts"
##
## Usage:
##   import isonim/routing/file_routes
##   # Components must be in scope (import page modules before this):
##   let routes = fileRoutes("pages")   # seq[RouteEntry] at compile time
##
## The `baseDir` path is resolved relative to the project directory
## (the directory containing the main `.nim` file being compiled).
##
## The macro references component procs by naming convention:
##   pages/about.nim       → expects `AboutPage` proc
##   pages/index.nim       → expects `IndexPage` proc
##   pages/users/[id].nim  → expects `IdPage` proc

import std/[strutils, macros, os]

proc pathFromFile*(baseDir, filePath: string): string =
  ## Derive a route path from a filesystem path relative to a base directory.
  ##
  ## Strips the base directory prefix and `.nim` suffix, converts
  ## `[param]` and `_param` segments to `:param`, and maps `index` to
  ## the parent directory path.
  ##
  ## This proc is public so it can be unit-tested without the macro.
  var rel = filePath
  # Strip the base directory prefix (with or without trailing slash)
  let base =
    if baseDir.endsWith("/"): baseDir[0 ..< baseDir.len - 1]
    else: baseDir
  if rel.startsWith(base):
    rel = rel[base.len .. ^1]
  # Strip leading separators
  while rel.len > 0 and rel[0] in {'/', '\\'}:
    rel = rel[1 .. ^1]
  # Strip .nim suffix
  if rel.endsWith(".nim"):
    rel = rel[0 ..< rel.len - 4]

  # Split into segments and transform
  var segments: seq[string]
  for part in rel.split('/'):
    if part.len == 0:
      continue
    if part == "index":
      # index maps to parent path — skip this segment
      continue
    # Convert [param] to :param
    if part.len > 2 and part[0] == '[' and part[^1] == ']':
      segments.add(":" & part[1 ..< part.len - 1])
    # Convert _param to :param (underscore prefix convention)
    elif part.len > 1 and part[0] == '_':
      segments.add(":" & part[1 .. ^1])
    else:
      segments.add(part)

  if segments.len == 0:
    return "/"
  result = ""
  for seg in segments:
    result.add('/')
    result.add(seg)

proc componentNameFromFile*(filePath: string): string =
  ## Derive the expected component proc name from a file path.
  ## Convention: capitalize the filename (without extension) and append "Page".
  ##
  ##   about.nim   → "AboutPage"
  ##   index.nim   → "IndexPage"
  ##   _id.nim     → "IdPage"
  ##   [id].nim    → "IdPage"
  ##   posts.nim   → "PostsPage"
  var name = filePath.extractFilename()
  if name.endsWith(".nim"):
    name = name[0 ..< name.len - 4]

  # Strip brackets
  if name.len > 2 and name[0] == '[' and name[^1] == ']':
    name = name[1 ..< name.len - 1]
  # Strip leading underscore (dynamic param convention)
  elif name.len > 1 and name[0] == '_':
    name = name[1 .. ^1]

  if name.len > 0:
    result = name[0].toUpperAscii & name[1 .. ^1] & "Page"
  else:
    result = "Page"

macro fileRoutes*(baseDir: static[string]): untyped =
  ## Compile-time macro that scans `baseDir` for `.nim` files and generates
  ## a `seq[RouteEntry]` literal with a route for each file.
  ##
  ## Each `.nim` file must export a `proc()` component matching the naming
  ## convention (e.g. `AboutPage` for `about.nim`). These procs must be
  ## in scope at the call site — import the page modules before calling
  ## this macro.
  ##
  ## The `baseDir` is resolved relative to the project directory (the
  ## directory of the main `.nim` file being compiled).
  ##
  ## Uses `staticExec("find ...")` to list files at compile time, so the
  ## directory scanning works identically on C and JS backends.

  # Resolve baseDir relative to the project directory (where the main
  # .nim file lives), since staticExec runs from the macro source file's
  # directory, not the caller's.
  let projDir = getProjectPath()
  let absDir =
    if baseDir.isAbsolute: baseDir
    else: projDir / baseDir

  let findCmd = "find " & absDir & " -name '*.nim' -type f | sort"
  let findOutput = staticExec(findCmd)

  let lines = findOutput.strip().splitLines()

  var routeNodes = newNimNode(nnkBracket)

  for line in lines:
    let filePath = line.strip()
    if filePath.len == 0:
      continue

    let routePath = pathFromFile(absDir, filePath)
    let compName = componentNameFromFile(filePath)

    let patternCall = newCall(
      newIdentNode("parsePattern"),
      newStrLitNode(routePath)
    )
    let compIdent = newIdentNode(compName)

    let entry = newNimNode(nnkObjConstr).add(
      newIdentNode("RouteEntry"),
      newNimNode(nnkExprColonExpr).add(newIdentNode("pattern"), patternCall),
      newNimNode(nnkExprColonExpr).add(newIdentNode("component"), compIdent),
    )
    routeNodes.add(entry)

  # Wrap in @[...] to produce seq[RouteEntry]
  result = newCall(newIdentNode("@"), routeNodes)
