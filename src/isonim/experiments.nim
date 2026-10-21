## Typed experiment reads. Registration metadata exists only in the compiler.
import std/[json, tables, macros, typetraits, os, strutils]
import ./core/context
import ./dsl/stable_ids

template experimentKey*(key: string) {.pragma.}
const experimentManifestDir* {.strdefine.} = ""
const experimentProjectRoot* {.strdefine.} = ""
const experimentRoute* {.strdefine.} = ""
type
  ExperimentExposure* = object
    key*: string
    arm*: int
    callSite*: string
  ExperimentAssignment* = ref object
    assign*: Table[string, int]
    qaOverrides*: Table[string, int]
    exposed*: seq[ExperimentExposure]
    day*: string
    production*: bool
    trackReads*: bool
      ## Static exporters opt in to collecting compiler descriptors.
    metadata*: Table[string, JsonNode]
      ## Descriptors of actually read keys, from compiler registration metadata.
let ExperimentCtx* = createContext[ExperimentAssignment](nil)
proc newExperimentAssignment*(day = ""; production = true): ExperimentAssignment =
  ## Hosts supply assignments; experiment reads never choose random arms.
  ExperimentAssignment(day: day, production: production)
proc beginExperiments*(assignment: ExperimentAssignment) =
  ## Call once inside each render root, before evaluating the page.
  if assignment != nil:
    assignment.exposed.setLen(0)
    assignment.metadata.clear()
  provide(ExperimentCtx, assignment)
template withExperiments*(assignment: ExperimentAssignment; body: untyped): untyped =
  block:
    beginExperiments(assignment)
    body
proc experimentTypeKey*[E: enum](): string {.compileTime.} =
  ## The pragma is the stable public key; the enum name is the default.
  when hasCustomPragma(E, experimentKey): getCustomPragmaVal(E, experimentKey)
  else: name(E)
var registrations {.compileTime.}: Table[string, JsonNode]
var registrationCounts {.compileTime.}: Table[string, int]
var sites {.compileTime.}: Table[string, JsonNode]
var siteIdentities {.compileTime.}: Table[string, string]
proc validDate(value: string): bool {.compileTime.} =
  if value.len != 10 or value[4] != '-' or value[7] != '-': return false
  for i, c in value:
    if i notin [4,7] and c notin {'0'..'9'}: return false
  let year = parseInt(value[0..3])
  let month = parseInt(value[5..6])
  let day = parseInt(value[8..9])
  if year < 1 or month < 1 or month > 12: return false
  var days = [31,28,31,30,31,30,31,31,30,31,30,31]
  if year mod 4 == 0 and (year mod 100 != 0 or year mod 400 == 0): days[1] = 29
  day >= 1 and day <= days[month-1]
proc registrationCount*(key: string): int {.compileTime.} =
  ## Counts actual executions of the generic's static registration block.
  registrationCounts.getOrDefault(key)
proc writeExperimentFragments() {.compileTime.} =
  if experimentManifestDir.len > 0:
    writeFile(experimentManifestDir / "experiments.json", $(%*{"experiments": registrations, "sites": sites}))
proc registerExperiment(key: string; arms: seq[string]; weights: seq[int]; window: JsonNode) {.compileTime.} =
  if key.len == 0: error("experiment key must not be empty")
  let data = %*{"arms": arms, "weights": weights, "window": window}
  if key in registrations and registrations[key] != data:
    error("duplicate experiment key with different arms or metadata: " & key)
  registrationCounts[key] = registrationCounts.getOrDefault(key) + 1
  registrations[key] = data
  writeExperimentFragments()
proc experimentSource(file: string): string {.compileTime.} =
  # Lexical relative paths work in the compiler VM for both C and JS. The
  # checkout prefix must never change either runtime tokens or lookup metadata.
  let source = file.replace('\\', '/').split('/')
  let root = (if experimentProjectRoot.len > 0: experimentProjectRoot
              else: getProjectPath()).replace('\\', '/').strip(leading=false, chars={'/'}).split('/')
  var common = 0
  while common < min(source.len, root.len) and source[common] == root[common]: inc common
  var parts: seq[string]
  for i in common ..< root.len: parts.add("..")
  for i in common ..< source.len: parts.add(source[i])
  parts.join("/")
proc experimentSiteId(file: string; line, column: int): string {.compileTime.} =
  stableIid(experimentSource(file) & ":" & $line & ":" & $column)
proc registerSite(key, file: string; line, column: int) {.compileTime.} =
  let source = experimentSource(file)
  let id = $(%*[key, source, line, column])
  let token = experimentSiteId(file, line, column)
  let identity = source & ":" & $line & ":" & $column
  if token in siteIdentities and siteIdentities[token] != identity:
    error("experiment call-site token collision")
  siteIdentities[token] = identity
  sites[id] = %*{"id": token, "key": key, "file": source, "line": line, "col": column, "route": experimentRoute}
  writeExperimentFragments()
proc useExperimentImpl*[E: enum](callSite: string): E =
  ## Plain owner-context read. Its generic static block runs once per E.
  mixin weights, window
  const key = experimentTypeKey[E]()
  static:
    var arms: seq[string]
    var expectedOrdinal = 0
    when E isnot Ordinal:
      error("experiment enums must be zero-based and contiguous")
    else:
      for arm in E:
        if ord(arm) != expectedOrdinal:
          error("experiment enums must be zero-based and contiguous")
        inc expectedOrdinal
        arms.add($arm)
    var allocation: seq[int]
    when compiles(weights(E)):
      allocation = weights(E)
      if allocation.len != arms.len: error("experiment weights must match arms")
      var total = 0
      for weight in allocation:
        if weight < 0: error("experiment weights must be nonnegative")
        total += weight
      if total == 0: error("experiment weights must have positive total")
    var dates = newJNull()
    when compiles(window(E)):
      let bounds = window(E)
      if not validDate(bounds.start) or not validDate(bounds.finish) or bounds.start >= bounds.finish:
        error("experiment window must contain ordered ISO calendar dates")
      dates = %*{"start": bounds.start, "end": bounds.finish}
    registerExperiment(key, arms, allocation, dates)
  const descriptor = $(registrations[key])
  result = low(E)
  let assignment = useContext(ExperimentCtx)
  if assignment == nil: return
  # The first observed value is constant for this page, even if the host
  # subsequently edits its input table. beginExperiments starts a new render.
  for exposure in assignment.exposed:
    if exposure.key == key:
      if exposure.arm >= ord(low(E)) and exposure.arm <= ord(high(E)):
        result = E(exposure.arm)
      return
  if assignment.trackReads: assignment.metadata[key] = parseJson(descriptor)
  var ordinal = assignment.assign.getOrDefault(key, ord(low(E)))
  if not assignment.production and key in assignment.qaOverrides:
    ordinal = assignment.qaOverrides[key]
  if ordinal >= ord(low(E)) and ordinal <= ord(high(E)): result = E(ordinal)
  assignment.exposed.add ExperimentExposure(key: key, arm: ord(result), callSite: callSite)
template useExperiment*[E: enum](): E =
  ## Register this source call site, then read the immutable page arm.
  const site = instantiationInfo(fullPaths = true)
  static: registerSite(experimentTypeKey[E](), site.filename, site.line, site.column)
  const siteId = experimentSiteId(site.filename, site.line, site.column)
  useExperimentImpl[E](siteId)
proc experimentResource*(assignment: ExperimentAssignment): JsonNode =
  ## Only assigned arms, observed exposures and day cross the hydration boundary.
  if assignment == nil: return newJNull()
  var effective = assignment.assign
  if not assignment.production:
    for key, arm in assignment.qaOverrides: effective[key] = arm
  for exposure in assignment.exposed: effective[exposure.key] = exposure.arm
  %*{"assign": effective, "exposed": assignment.exposed, "day": assignment.day}
proc assignmentFromResource*(resource: JsonNode): ExperimentAssignment =
  ## Malformed host data is an unassigned control page.
  result = newExperimentAssignment()
  if resource == nil or resource.kind != JObject: return
  if resource.hasKey("day") and resource["day"].kind == JString: result.day = resource["day"].getStr()
  if resource.hasKey("assign") and resource["assign"].kind == JObject:
    for key, value in resource["assign"]:
      if value.kind == JInt: result.assign[key] = value.getInt()
