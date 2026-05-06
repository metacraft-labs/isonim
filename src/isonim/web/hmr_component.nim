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
##   when defined(isonimHmr):
##     bootstrapHmr()
##
## See `codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload.md` for the
## full design rationale.

import std/macros

when defined(isonimHmr) and defined(js):
  import std/[jsffi, tables]
  import isonim/web/dom_api
  import isonim/web/hmr_ui_registry
  import isonim/core/[signals, computation, owner]
  export hmr_ui_registry  # so users get hmrRegisterFactory etc. from one import

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

  macro uiComponentTyped(realName: untyped;
                          procDef: typed): untyped =
    ## Stage 2 of the `{.uiComponent.}` pragma: receives the proc def
    ## with name resolved (typed), so `symBodyHash` can compute the
    ## transitive content hash of its body.
    expectKind procDef, nnkProcDef
    let implSym = procDef.name
    let h = symBodyHash(implSym)
    let info = procDef.lineInfoObj()
    let locStr = info.filename & ":" & $info.line & ":" & $info.column

    # The user-visible proc with the original name. Body forwards to
    # hmrInvokeComponent which dispatches through the slot. This is the
    # *only* way user code calls the component — the actual
    # implementation (`implSym`) is reached only via the slot's factory
    # signal, not by direct call from user code.
    let dispatchProc = newProc(
      name = realName,
      params = @[ident"Node"],
      body = newCall(bindSym"hmrInvokeComponent", newLit(locStr)))

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

    result = newStmtList(procDef, dispatchProc, registration, locConst)

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

else:
  # `-d:isonimHmr` not set, or not the JS target. The pragma is a
  # transparent no-op: user's proc keeps its name, body, and behaviour;
  # callers reach it directly without going through any registry.
  macro uiComponent*(procDef: untyped): untyped =
    procDef

  macro bootstrapHmr*(): untyped =
    result = newStmtList()
