## isonim/web/hmr_component.nim
##
## The `{.uiComponent.}` pragma macro and the runtime that backs it.
## Active machinery only under `-d:isonimHmr`; without the flag the
## pragma is a no-op and component calls are direct proc calls.
##
## Usage:
##
##   import isonim
##   import isonim/web/hmr_component
##
##   proc childA(): Node {.uiComponent.} =
##     ui(r): span: text "A"
##
##   proc app(): Node {.uiComponent.} =
##     ui(r): div: childA()
##
##   # Parametric components (v2) — components that take args:
##   proc panel(r: WebRenderer; vm: PanelVM): Node {.uiComponent.} =
##     ui(r):
##       div: text vm.title.val
##
##   when defined(isonimHmr):
##     bootstrapHmr()
##
## See `codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload.md` for the
## full design rationale.

import std/macros

proc cloneParamsWithFreshNames*(params: NimNode): (NimNode, seq[NimNode]) =
  ## Copy a `nnkFormalParams` node, replacing parameter-name symbols
  ## with fresh untyped idents (so the new proc binds them as its own
  ## locals when type-checked). Type and default nodes are copied as
  ## subtrees — type sym refs resolve back to the same types when the
  ## generated dispatch is checked in the caller's scope. Returns the
  ## new params node and the list of fresh argument idents in
  ## declaration order.
  ##
  ## Hoisted out of the JS arm on 2026-09-18 (NH-M3) so the native arm
  ## calls the SAME proc rather than a second copy of it — two copies of
  ## one rule is `Verification-Harness-Traps` §30, and a parametric
  ## signature that the two backends cloned differently would be exactly
  ## that defect with a compile error for a symptom.
  let cloned = newTree(nnkFormalParams)
  cloned.add(params[0].copyNimTree)  # return type slot
  var argNames: seq[NimNode] = @[]
  for i in 1 ..< params.len:
    let identDef = params[i]
    doAssert identDef.len >= 3,
      "uiComponent: malformed parameter definition"
    let typeNode = identDef[identDef.len - 2].copyNimTree
    let defaultNode = identDef[identDef.len - 1].copyNimTree
    for j in 0 ..< identDef.len - 2:
      let originalName = identDef[j]
      let freshName = ident($originalName)
      argNames.add(freshName)
      cloned.add(newIdentDefs(freshName, typeNode.copyNimTree,
                              defaultNode.copyNimTree))
  (cloned, argNames)

proc uiComponentSlotLoc*(procDef: NimNode): string =
  ## `file:line:col` of a `{.uiComponent.}`-marked proc — the slot key.
  ## One definition, used by BOTH arms, because the native/web control
  ## arm in NH-M3 asserts the two locations are EQUAL before it compares
  ## hashes, and a location computed by two expressions could agree or
  ## disagree for reasons that have nothing to do with the subject.
  let info = procDef.lineInfoObj()
  info.filename & ":" & $info.line & ":" & $info.column

when defined(isonimHmr) and defined(js):
  import std/[jsffi, tables]
  import isonim/web/dom_api
  import isonim/web/hmr_ui_registry
  import isonim/core/[signals, computation, owner]
  export hmr_ui_registry  # so users get hmrRegisterFactory etc. from one import

  # ---------------------------------------------------------------------------
  # Parametric component runtime
  #
  # Zero-arg `{.uiComponent.}` procs go through `hmrInvokeComponent` (per-slot
  # memo). Parametric procs (`proc Name(args...): T`) cannot use a per-slot
  # memo — the same slot is reachable from multiple call sites with different
  # args, and a single memo would be either incorrect (returns a stale Node
  # for a different arg set) or a deopt (re-computes always but at the cost of
  # the memo machinery). So parametric components use a thinner dispatch path:
  # read `slot.factory.val` (subscribes to swaps) and call through to the
  # current factory. The reactive boundary that gives DOM-identity preservation
  # in v2 is `mountUiHot`, not the call site.
  # ---------------------------------------------------------------------------

  proc newJsArray*(): JsObject =
    ## Returns an empty JS array as a JsObject. Used by the parametric
    ## dispatch to package args before invoking the slot factory via
    ## `Function.prototype.apply`. We use a small `{.emit.}` body
    ## because `importjs: "[]"` is rejected as a pattern with no
    ## placeholders.
    {.emit: [result, " = [];"].}

  proc jsArrayPush*(arr, item: JsObject) =
    ## Appends `item` to the JS array. Caller is responsible for
    ## wrapping raw values in `toJs`.
    {.emit: [arr, ".push(", item, ");"].}

  proc applyJsFunction*(fn, argsArr: JsObject): JsObject =
    ## Invokes `fn` (a JS function value) with the given args array.
    ## Equivalent to `fn(...argsArr)`. We use `apply` rather than
    ## spread syntax so this stays compatible with any JS engine the
    ## bundle might be evaluated in.
    {.emit: [result, " = ", fn, ".apply(null, ", argsArr, ");"].}

  proc hmrInvokeParametric*(loc: string; args: JsObject): JsObject =
    ## Runtime entry point for parametric `{.uiComponent.}` calls.
    ##
    ## - Looks up the slot at `loc` and asserts it has been registered.
    ##   Missing slots indicate a registration ordering bug (the
    ##   `{.uiComponent.}` pragma should have emitted a top-level
    ##   `hmrRegisterFactory` call that ran during module init).
    ## - Marks the slot as claimed in the current generation so it
    ##   survives the next prune sweep.
    ## - Reads `slot.factory.val` so the calling reactive scope
    ##   subscribes to slot swaps. When the factory signal is rewritten
    ##   (because a hash change made the slot factory update on bundle
    ##   reload) the surrounding render effect — typically the one set
    ##   up by `mountUiHot` — re-runs and the DOM is reconciled.
    ## - Calls the current factory with the supplied args and returns
    ##   the JsObject result. The dispatch proc generated by the
    ##   `{.uiComponent.}` macro applies a typed `.to(T)` to coerce the
    ##   result back to the user-declared return type.
    ##
    ## Errors raised inside the factory propagate to the caller. The
    ## `mountUiHot` boundary is responsible for catching them so the
    ## previous DOM stays intact across a failed swap. We also surface
    ## the error through `globalUiOnError` for transports / overlays.
    ensureUiRegistry()
    let reg = globalUiRegistry
    let slot = reg.entries.getOrDefault(loc)
    if slot == nil:
      raise newException(Defect,
        "HMR: no factory registered for parametric component at " & loc &
        ". The {.uiComponent.} pragma should have emitted a top-level " &
        "registration. If you're seeing this, the registration block " &
        "didn't run — typically because the module containing the " &
        "component wasn't imported/evaluated.")
    slot.claimedGen = reg.currentGen
    let factoryProc = slot.factory.val
    try:
      return applyJsFunction(factoryProc, args)
    except Exception as err:
      if globalUiOnError != nil:
        globalUiOnError(loc, err)
      raise

  proc hmrInvokeComponent*(loc: string): Node =
    ## Runtime entry point inserted at every component-call site by the
    ## `{.uiComponent.}` pragma. Looks up the slot (must have been
    ## registered at module init by the pragma's emitted top-level
    ## block), gets its memo (creating once on first use under the
    ## persistent HMR owner so it survives outer-effect re-runs), and
    ## returns the cached Node.
    ensureUiRegistry()
    let reg = globalUiRegistry
    let slot = reg.entries.getOrDefault(loc)
    if slot == nil:
      raise newException(Defect,
        "HMR: no factory registered for component at " & loc &
        ". The {.uiComponent.} pragma should have emitted a top-level " &
        "registration. If you're seeing this, the registration block " &
        "didn't run — typically because the module containing the " &
        "component wasn't imported/evaluated.")
    slot.claimedGen = reg.currentGen
    if not slot.hasMemo:
      runWithOwner(reg.persistentOwner, proc() =
        slot.memo = createMemo(proc(): Node =
          # The slot stores the user's body proc as a JsObject (type
          # erased so all slots share one registry entry shape). Cast
          # back to the typed proc we know it is and call.
          let factoryProc = slot.factory.val.to(proc(): Node)
          try:
            let n = factoryProc()
            slot.lastGoodNode = n
            return n
          except Exception as err:
            # Contain the failure at the memo boundary: report and return
            # the most recent good Node. Returning the same ref makes
            # insertExpression's pointer-equality short-circuit kick in,
            # so the DOM doesn't mutate. If we don't have a prior good
            # Node yet (initial render also threw), there's nothing to
            # short-circuit to — re-raise.
            if globalUiOnError != nil:
              globalUiOnError(loc, err)
            if slot.lastGoodNode != nil:
              return slot.lastGoodNode
            raise)
      )
      slot.hasMemo = true
    slot.memo.val

  proc buildParametricDispatch(realName, locLit, returnType: NimNode;
                                argNames: seq[NimNode]): NimNode =
    ## Build the body of a parametric dispatch proc:
    ##
    ##   let _hmrArgs = newJsArray()
    ##   jsArrayPush(_hmrArgs, toJs(arg1))
    ##   jsArrayPush(_hmrArgs, toJs(arg2))
    ##   ...
    ##   cast[<ReturnType>](hmrInvokeParametric(<locStr>, _hmrArgs))
    ##
    ## We use `cast` rather than `.to(T)` for the JS→Nim coercion at the
    ## end. `to(JsObject, typedesc)` from std/jsffi resolves to the wrong
    ## overload in this macro-generated context (the typedesc travels as
    ## a value argument), and on the JS backend `cast[T](jsObj)` is a
    ## type-only assertion — the same machine code as `.to(T)` would
    ## have produced. `realName` is unused here (the caller assembles
    ## the proc with this body) but kept in the signature for symmetry
    ## with future variants.
    let argsVar = genSym(nskLet, "hmrArgs")
    var body = newStmtList()
    body.add(newLetStmt(argsVar, newCall(bindSym"newJsArray")))
    for arg in argNames:
      body.add(newCall(bindSym"jsArrayPush", argsVar,
                        newCall(bindSym"toJs", arg)))
    let invocation = newCall(bindSym"hmrInvokeParametric", locLit, argsVar)
    let coerce = newTree(nnkCast, returnType, invocation)
    body.add(coerce)
    body

  macro uiComponentTyped(realName: untyped;
                          procDef: typed): untyped =
    ## Stage 2 of the `{.uiComponent.}` pragma: receives the proc def
    ## with name resolved (typed), so `symBodyHash` can compute the
    ## transitive content hash of its body. Generates two flavours of
    ## dispatch:
    ##
    ## - Zero-arg (`proc Name(): Node`) → memoised dispatch through
    ##   `hmrInvokeComponent`. The per-slot memo means a parent reactive
    ##   effect re-running for unrelated reasons gets the cached Node
    ##   back, preserving DOM identity. This is the original v1 path.
    ##
    ## - Parametric (`proc Name(args...): T`) → unmemoised dispatch
    ##   through `hmrInvokeParametric`. The same slot is reachable from
    ##   multiple call sites with different args, so a per-slot memo
    ##   would be wrong. DOM-identity preservation across unrelated
    ##   parent re-runs is therefore not a guarantee inside parametric
    ##   subtrees in v2; the boundary that *is* preserved is the
    ##   `mountUiHot` mount point. Editing one mount's components leaves
    ##   the DOM under every other mount untouched.
    expectKind procDef, nnkProcDef
    let implSym = procDef.name
    let h = symBodyHash(implSym)
    let locStr = uiComponentSlotLoc(procDef)
    let locLit = newLit(locStr)

    # `params[0]` is the return type slot; subsequent entries are
    # IdentDefs — one per group of parameters sharing a type.
    let isParametric = procDef.params.len > 1

    var dispatchProc: NimNode
    if isParametric:
      let (newParams, argNames) = cloneParamsWithFreshNames(procDef.params)
      let returnType = procDef.params[0].copyNimTree
      let body = buildParametricDispatch(realName, locLit, returnType, argNames)
      dispatchProc = newProc(name = realName, body = body)
      dispatchProc.params = newParams
    else:
      # Zero-arg path — preserved verbatim from v1 (per-slot memo via
      # `hmrInvokeComponent`).
      dispatchProc = newProc(
        name = realName,
        params = @[ident"Node"],
        body = newCall(bindSym"hmrInvokeComponent", locLit))

    # Module-top registration. The `let regVar = block: ...; true`
    # construct runs the block at module init time. Re-evaluating the
    # block on bundle reload (because the new bundle has its own JS
    # globals and re-runs init) hits hmrRegisterFactory which compares
    # hashes and writes the slot signal only when the body's effective
    # code actually changed.
    let regVar = genSym(nskLet, "isonimHmrReg_" & $realName)
    let factoryCast = quote do:
      hmrRegisterFactory(`locStr`, `h`, toJs(`implSym`))
      true
    let registration = newLetStmt(regVar, newBlockStmt(factoryCast))

    # Emit a `<ProcName>Loc*: string = "<full-location>"` const so user
    # code (especially tests) can refer to the slot without depending
    # on the absolute file path the macro embedded.
    let locConstName = ident($realName & "Loc")
    let locConst = newConstStmt(
      postfix(locConstName, "*"),
      newLit(locStr))

    # And the `symBodyHash` the macro just computed, as
    # `<ProcName>Hash*`. ADDED 2026-09-18 (NH-M3). Without it the hash is
    # reachable only from inside the registry at runtime, which is why
    # every gate up to now asserted on a hash string the FIXTURE chose.
    # A test that reads this const is reading the compiler's answer.
    let hashConstName = ident($realName & "Hash")
    let hashConst = newConstStmt(
      postfix(hashConstName, "*"),
      newLit(h))

    result = newStmtList(procDef, dispatchProc, registration, locConst,
                         hashConst)

  macro uiComponent*(procDef: untyped): untyped =
    ## Stage 1 of the pragma. Renames the user's proc with a genSym'd
    ## "_impl" suffix so the original name can be reused for the
    ## dispatcher proc, and forwards to the typed analyzer.
    expectKind procDef, nnkProcDef
    let realName = procDef.name
    procDef.name = genSym(nskProc, $realName & "_impl")
    result = newCall(bindSym"uiComponentTyped", realName, procDef)

  macro bootstrapHmr*(): untyped =
    ## Place this at the bottom of every module that defines
    ## `{.uiComponent.}` procs. In v1 this is mostly a no-op (each
    ## component pragma already emits its own registration) but we
    ## keep the call so future versions (which may want to do a
    ## per-module sweep) can hook in without changing user code.
    result = newStmtList()

elif defined(isonimHmr):
  # ---------------------------------------------------------------------------
  # THE NATIVE ARM — added 2026-09-18 for NH-M3.
  #
  # Until this existed the branch above was the ONLY arm, so under `nim c`
  # `{.uiComponent.}` was a transparent no-op and `symBodyHash` was never
  # called on native at all. Every native HMR gate therefore had to supply
  # the hash a patched body "would have" produced, as a literal — which is
  # a defensible fixture for "one loc, two hashes" (a real patch replaces a
  # body in place, so that IS the shape) and proves nothing whatsoever
  # about the only claim that makes a hash load-bearing: that a CHANGED
  # BODY produces a DIFFERENT hash. See NH-M3's
  # `test_uicomponent_native_arm_hashes_a_changed_body_differently`.
  #
  # What it emits, per `{.uiComponent.}`-marked proc `Name`:
  #
  #   <impl>                       the user's body, under a genSym'd name
  #   proc Name(...): T            the dispatch (see below)
  #   proc NameHmrRegister*()      registers loc + hash + factory
  #   let _ = block: hmrDeclareSlot(loc, NameHmrRegister); true
  #   const NameLoc*  = "file:line:col"
  #   const NameHash* = "<symBodyHash>"
  #
  # THE REGISTRATION IS A PROC, NOT A TOP-LEVEL CALL, and the difference
  # is the whole reason this arm is shaped the way it is. On the web the
  # pragma emits a top-level `hmrRegisterFactory` because a reloaded
  # bundle RE-RUNS module init, so the new hash arrives by itself. Native
  # has no such event: Reprobuild replaces function BODIES in place and
  # never re-executes a module's top level. So the hash literal has to
  # live inside a proc body — `NameHmrRegister` — which the patch
  # replaces along with the component, and the re-registration pass
  # (`hmrRegisterDeclaredSlots`, run from `HmrRoot`'s entry inside
  # `after_reload`) calls it through the trampoline and reads the NEW
  # literal. A `seq` of (loc, hash) captured at module init would be
  # frozen at the pre-patch value forever, and the failure mode is a
  # reload that silently does nothing.
  #
  # DISPATCH, in two shapes, mirroring the web arm's two:
  #
  # - Zero-arg → `hmrInvokeSlot[T](loc)`: the per-slot memo, which is what
  #   makes "unchanged ui block → unchanged native subtree" true.
  # - Parametric → `hmrTouchSlot(loc)` then a DIRECT call to the impl. The
  #   same slot is reachable from several call sites with different args,
  #   so a per-slot memo would be wrong (web says the same and for the
  #   same reason). `hmrTouchSlot` supplies the one thing the memo was
  #   also providing — the dependency edge from the mount to the slot's
  #   factory signal — and the direct call lands on the patched body
  #   because it goes through Reprobuild's trampoline.
  # ---------------------------------------------------------------------------
  import isonim/native/hmr as native_hmr
  export native_hmr

  macro uiComponentTypedNative(realName: untyped;
                               procDef: typed): untyped =
    expectKind procDef, nnkProcDef
    let implSym = procDef.name
    let h = symBodyHash(implSym)
    let locStr = uiComponentSlotLoc(procDef)
    let locLit = newLit(locStr)
    let hashLit = newLit(h)

    let returnType = procDef.params[0]
    if returnType.kind == nnkEmpty:
      error("uiComponent: a ui component must return the renderer node " &
            "it builds. A `proc` with no return type builds nothing the " &
            "registry could hold, so a reload would have nothing to " &
            "swap. Give it a return type (e.g. `: TerminalNode`).",
            procDef)

    let isParametric = procDef.params.len > 1
    let registerName = ident($realName & "HmrRegister")

    var dispatchProc: NimNode
    if isParametric:
      let (newParams, argNames) = cloneParamsWithFreshNames(procDef.params)
      var body = newStmtList()
      body.add(newCall(bindSym"hmrTouchSlot", locLit))
      var directCall = newCall(implSym)
      for arg in argNames: directCall.add(arg)
      body.add(directCall)
      dispatchProc = newProc(name = realName, body = body)
      dispatchProc.params = newParams
    else:
      dispatchProc = newProc(
        name = realName,
        params = @[returnType.copyNimTree],
        body = newCall(
          newTree(nnkBracketExpr, bindSym"hmrInvokeSlot",
                  returnType.copyNimTree),
          locLit))

    # The factory the slot holds. Zero-arg components hand over their own
    # body; parametric ones cannot — there is no zero-arg form of them —
    # so they register a factory that RAISES if anything ever invokes it.
    # A raising factory rather than a silent `nil` or a default value is
    # deliberate: `hmrInvokeSlot` on a parametric slot means some call
    # site took the memoised path for a component that must not be
    # memoised, and the quiet version of that bug is a stale subtree.
    var factoryExpr: NimNode
    if isParametric:
      let msg = newLit(
        "isonim native HMR: ui component at " & locStr & " is " &
        "PARAMETRIC and has no zero-arg factory. It is reached through " &
        "its generated dispatch, which calls the body directly after " &
        "hmrTouchSlot(); hmrInvokeSlot() must never be used on it.")
      factoryExpr = quote do:
        uiSlotFactory[int](proc(): int =
          raise newException(Defect, `msg`))
    else:
      factoryExpr = newCall(
        newTree(nnkBracketExpr, bindSym"uiSlotFactory",
                returnType.copyNimTree),
        implSym)

    let registerProc = newProc(
      name = postfix(registerName, "*"),
      params = @[newEmptyNode()],
      body = newCall(bindSym"hmrRegisterFactory", locLit, hashLit,
                     factoryExpr))

    let declVar = genSym(nskLet, "isonimHmrDecl_" & $realName)
    let declaration = newLetStmt(declVar, newBlockStmt(quote do:
      hmrDeclareSlot(`locLit`, `registerName`)
      true))

    let locConst = newConstStmt(
      postfix(ident($realName & "Loc"), "*"), newLit(locStr))
    let hashConst = newConstStmt(
      postfix(ident($realName & "Hash"), "*"), newLit(h))

    result = newStmtList(procDef, registerProc, dispatchProc, declaration,
                         locConst, hashConst)

  macro uiComponent*(procDef: untyped): untyped =
    ## Stage 1, native. Identical in shape to the JS arm: rename the
    ## user's proc so the original name is free for the dispatcher, then
    ## forward to the typed analyzer, which is where `symBodyHash` can
    ## see a resolved symbol.
    expectKind procDef, nnkProcDef
    let realName = procDef.name
    procDef.name = genSym(nskProc, $realName & "_impl")
    result = newCall(bindSym"uiComponentTypedNative", realName, procDef)

  macro bootstrapHmr*(): untyped =
    ## Native counterpart of the JS no-op. Each pragma already emits its
    ## own declaration, so there is nothing to sweep per module; the call
    ## is kept so a module written for one backend compiles on the other.
    result = newStmtList()

else:
  # `-d:isonimHmr` not set. The pragma is a transparent no-op: user's
  # proc keeps its name, body, and behaviour; callers reach it directly
  # without going through any registry.
  macro uiComponent*(procDef: untyped): untyped =
    procDef

  macro bootstrapHmr*(): untyped =
    result = newStmtList()
