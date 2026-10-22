## Optional signal observation. Entries own metadata, never signal references.
## Native leases invalidate their raw address before the signal is destroyed;
## JS uses WeakRef because JS object lifetime is managed by the browser GC.
when not defined(isonimRecordable):
  {.error: "checkpoint_registry requires -d:isonimRecordable".}
import std/[strutils, typetraits, hashes, macros, os]
when defined(js): import std/jsffi

type
  SignalRegistration* = ref object
    ordinal*: int
    writes*: uint64
    active*: bool
    typeName*: string
    when defined(js):
      weak: JsObject
      contribution: proc(value: JsObject): string
    else:
      address: pointer
      leaseAddress: pointer
        ## Original allocation's lease field; never dereferenced or copied as
        ## ownership. Cleared by that field's destructor before deallocation.
      contribution: proc(value: pointer): string {.nimcall.}
  SignalLease* = object
    registration*: SignalRegistration

when not defined(js):
  proc `=destroy`*(lease: var SignalLease) =
    if lease.registration != nil and
        lease.registration.leaseAddress == cast[pointer](addr lease):
      lease.registration.active = false
      lease.registration.address = nil
      lease.registration.leaseAddress = nil
    `=destroy`(lease.registration)

  proc bindSignalLease*(lease: var SignalLease; entry: SignalRegistration) =
    ## Record the original heap field, not a temporary or a value copy. Default
    ## Nim copy/sink handling remains intact; copies only retain metadata.
    lease.registration = entry
    entry.leaseAddress = cast[pointer](addr lease)

var registrations {.threadvar.}: seq[SignalRegistration]
var nextOrdinal {.threadvar.}: int

proc mix*(state: var uint32; value: string) =
  ## FNV-1a with explicit field boundaries; arithmetic is modulo 2^32.
  for c in value:
    state = (state xor uint32(ord(c))) * 16777619'u32
  state = (state xor 255'u32) * 16777619'u32

macro declaredHash(call: typed): untyped =
  ## User declarations establish a value contract. Generic stdlib wrappers
  ## instead need recursive member classification; their hash may delegate to
  ## an identity hash. Nongeneric stdlib value contracts (e.g. JSON) still count.
  if call.kind notin {nnkCall, nnkCommand} or call[0].kind != nnkSym:
    return newLit(false)
  let implementation = call[0].getImpl
  let standardSource = getImpl(bindSym"Hash").lineInfoObj.filename
  let standardRoot = getImpl(bindSym"RootObj").lineInfoObj.filename.parentDir & DirSep
  let source = implementation.lineInfoObj.filename
  let inStandardLibrary = source.startsWith(standardRoot)
  # Nim 2.2.4 preserves instantiated generic parameters in declaration metadata
  # at slot 5; uninstantiated routines use slot 2. Do not inspect the hash body.
  let generic = (implementation[2].kind == nnkGenericParams and implementation[2].len > 0) or
    (implementation[5].kind == nnkBracket and implementation[5].len > 1 and
      implementation[5][1].kind == nnkGenericParams and implementation[5][1].len > 0)
  result = newLit(source != standardSource and (not inStandardLibrary or not generic))

template hasDeclaredHash(T: typedesc): bool =
  mixin hash
  when compiles(hash(default(T))):
    declaredHash(hash(default(T)))
  else:
    false

macro checkpointTypeIdentity(T: typedesc): untyped =
  ## Compiler symbol signatures distinguish equal-looking type names in
  ## different modules. This key is compile-time only, never checkpoint data.
  proc key(node: NimNode): string =
    if node.kind == nnkSym: return node.signatureHash
    if node.len == 0: return $node.kind & ":" & node.repr
    result = $node.kind & "["
    for child in node: result.add(key(child) & ";")
    result.add("]")
  result = newLit(key(T.getTypeInst))

proc stableStandardType[T](seen: seq[string] = @[]): bool {.compileTime.}

macro stableObjectFields(T: typedesc): untyped =
  ## Typed object metadata retains all case branches, unlike fields(default(T)).
  ## Expand inherited declarations themselves: a base's custom hash is not the
  ## hash of its inherited fields inside a standard-derived-object hash.
  ## This private helper expands only in stableStandardType's scope; `visited`
  ## is that classifier's traversal state, shared with tuple/sequence checks.
  var checks: seq[NimNode]
  proc inspect(node: NimNode) =
    case node.kind
    of nnkObjectTy:
      inspect(node[1])
      inspect(node[2])
    of nnkOfInherit:
      for base in node: inspect(base.getTypeImpl)
    of nnkRecList:
      for field in node: inspect(field)
    of nnkRecCase:
      inspect(node[0])
      for branch in node[1..^1]: inspect(branch[^1])
    of nnkIdentDefs:
      checks.add(newCall(newTree(nnkBracketExpr, bindSym"stableStandardType",
        node[^2].copyNimTree), ident"visited"))
    of nnkEmpty:
      discard
    else:
      checks.add(newLit(false))
  inspect(T.getTypeInst[1].getTypeImpl)
  result = newLit(true)
  for check in checks:
    result = newTree(nnkInfix, ident"and", result, check)

proc stableStandardType[T](seen: seq[string]): bool {.compileTime.} =
  const identity = checkpointTypeIdentity(T)
  # A repeated value type closes a structural cycle. Other fields on every
  # first visit still get checked, including identity fields in mutual cycles.
  if identity in seen: return true
  let visited = seen & @[identity]
  when hasDeclaredHash(T):
    true
  elif T is ref or T is ptr or T is proc or T is pointer:
    false
  elif distinctBase(T) isnot T:
    stableStandardType[distinctBase(T)](visited)
  elif T is object:
    stableObjectFields(T)
  elif T is tuple:
    var sample: T
    result = true
    for field in fields(sample):
      if not stableStandardType[typeof(field)](visited): result = false
  elif T is seq or T is array:
    stableStandardType[typeof(default(T)[0])](visited)
  else:
    T is string or T is cstring or T is SomeInteger or T is SomeFloat or T is bool or T is enum or T is char or T is set

proc stableContribution*[T](value: T): string =
  ## Generic identity hashes for ref/proc/pointer types are deliberately absent.
  mixin checkpointSerialize, checkpointHash, hash
  when compiles(checkpointSerialize(value)):
    "serialized:" & checkpointSerialize(value)
  elif compiles(checkpointHash(value)):
    "custom:" & $checkpointHash(value)
  elif compiles(hash(value)):
    when declaredHash(hash(value)) or stableStandardType[T]():
      "value:" & $hash(value)
    else:
      "writes"
  else:
    "writes"

when defined(js):
  proc weakRef(value: JsObject): JsObject {.importjs: "new WeakRef(#)".}
  proc deref(value: JsObject): JsObject {.importjs: "(#.deref() || null)".}
  proc registerSignal*(value: JsObject; typeName: string;
      contribution: proc(value: JsObject): string): SignalRegistration =
    inc nextOrdinal
    result = SignalRegistration(ordinal: nextOrdinal, active: true,
      typeName: typeName, weak: weakRef(value), contribution: contribution)
    registrations.add(result)
else:
  proc registerSignal*(value: pointer; typeName: string;
      contribution: proc(value: pointer): string {.nimcall.}): SignalRegistration =
    inc nextOrdinal
    result = SignalRegistration(ordinal: nextOrdinal, active: true,
      typeName: typeName, address: value, contribution: contribution)
    registrations.add(result)

proc liveSignalCount*(): int =
  ## Also compacts dead metadata, without renumbering surviving signals.
  var live: seq[SignalRegistration]
  for entry in registrations:
    when defined(js):
      if entry.active and entry.weak.deref() == nil: entry.active = false
    if entry.active: live.add(entry)
  registrations = live
  live.len

proc signalStateHash*(randomDraws: uint64): string =
  discard liveSignalCount()
  # Copy metadata into a separate sequence. An alias would let JS additions
  # extend this traversal; a contributor may also compact the global registry.
  var snapshot: seq[SignalRegistration]
  for entry in registrations: snapshot.add(entry)
  var hash = 2166136261'u32
  for entry in snapshot:
    if not entry.active: continue
    when defined(js):
      let value = entry.weak.deref()
      if value == nil: continue
      let contribution = entry.contribution(value)
    else:
      if entry.address == nil: continue
      let contribution = entry.contribution(entry.address)
    # A custom contributor can dispose this entry's owner as well as later
    # entries. Do not include a registration invalidated by its own callback.
    if not entry.active: continue
    hash.mix($entry.ordinal)
    hash.mix(entry.typeName)
    hash.mix(contribution)
    if contribution == "writes": hash.mix($entry.writes)
  hash.mix($randomDraws)
  toHex(hash, 8)

proc resetSignalOrdinals*() =
  ## Start a fresh recording universe only when no prior signals remain live.
  if liveSignalCount() != 0:
    raise newException(ValueError, "cannot reset ordinals while signals are live")
  nextOrdinal = 0
