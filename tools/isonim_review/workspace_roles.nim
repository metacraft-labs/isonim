## Workspace source paths belong to Repro's declared repository report.
## Standalone installations without a manifest retain optional sibling behavior.
import std/[json, os, strutils]

proc workspaceRoot*(project: string): string =
  var candidate = absolutePath(project)
  while true:
    if fileExists(candidate / ".repro-workspace.toml") or
        (fileExists(candidate / ".repro" / "workspace.toml") and
         dirExists(candidate / "projects") and dirExists(candidate / "repos")):
      return candidate
    let parent = candidate.parentDir
    if parent == candidate: return ""
    candidate = parent

proc canonical(path: string): string =
  if dirExists(path) or fileExists(path): expandFilename(path)
  else: normalizedPath(absolutePath(path))

proc declaredRole*(report: JsonNode; workspace, name: string;
                   required = true): string =
  if report.kind != JObject or not report.hasKey("schema") or
      report["schema"].kind != JString or
      report["schema"].getStr != "reprobuild.workspace-set-repos-list.v1":
    raise newException(IOError, "Unsupported Repro workspace repository report")
  if not report.hasKey("workspaceRoot") or report["workspaceRoot"].kind != JString or
      report["workspaceRoot"].getStr.len == 0 or
      canonical(report["workspaceRoot"].getStr) != canonical(workspace):
    raise newException(IOError, "Repro workspace repository report root mismatch")
  if not report.hasKey("repos") or report["repos"].kind != JArray:
    raise newException(IOError, "Malformed Repro workspace repository rows")
  var matches: seq[JsonNode]
  for row in report["repos"]:
    if row.kind != JObject:
      raise newException(IOError, "Malformed Repro workspace repository row")
    if row.hasKey("repo") and row["repo"].kind == JString and row["repo"].getStr == name:
      matches.add(row)
  if matches.len == 0 and not required:
    if dirExists(workspace / name) or fileExists(workspace / name) or symlinkExists(workspace / name):
      raise newException(IOError, "Undeclared source checkout cannot supply optional role: " & name)
    return ""
  if matches.len != 1:
    raise newException(IOError, "Expected exactly one declared workspace role: " & name)
  let row = matches[0]
  if not row.hasKey("enabled") or row["enabled"].kind != JBool or not row["enabled"].getBool:
    raise newException(IOError, "Required workspace role is disabled: " & name)
  if not row.hasKey("path") or row["path"].kind != JString or row["path"].getStr.len == 0:
    raise newException(IOError, "Missing workspace role path: " & name)
  let relative = row["path"].getStr
  if relative.isAbsolute or ".." in relative.replace('\\', '/').split('/'):
    raise newException(IOError, "Invalid workspace role path: " & name)
  result = canonical(workspace / relative)
  # A declared relative path may be a genuine borrowed compiler checkout.
  # The snapshot records its physical principal/HEAD/diff; it remains outside
  # the agent-writable project. Duplicate physical role paths still refuse.
  var aliases = 0
  for other in report["repos"]:
    if other.hasKey("path") and other["path"].kind == JString and
        canonical(workspace / other["path"].getStr) == result:
      inc aliases
  if aliases != 1:
    raise newException(IOError, "Ambiguous workspace role path: " & name)
  if not dirExists(result / ".git") and not fileExists(result / ".git"):
    raise newException(IOError, "Declared required workspace checkout missing: " & name)
