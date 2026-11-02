## Reuse the ACTUAL frozen manifest task component without editing its fixture
## or rerunning its benchmark. A bounded source AST projection removes only its
## ordinary bootstrap; all component/helper bodies and source positions remain.
when defined(js):
  import std/macros
  macro originalTaskComponent(): untyped =
    let here=currentSourcePath()
    let path=here[0 ..< here.len-"client_routing_task.nim".len] & "stable_ids/task_app.nim"
    let source=parseStmt(staticRead(path),path)
    var count=0
    for node in source:
      if node.kind==nnkProcDef and node[0].eqIdent("taskApp"): inc count
    if count!=1 or source.len<2: error("original task component shape changed")
    let bootstrap=source[^1]
    if bootstrap.kind!=nnkWhenStmt or bootstrap.len!=2 or
        bootstrap[0].kind!=nnkElifBranch or bootstrap[0][0].repr!="defined(js)" or
        bootstrap[0][1].len!=4 or bootstrap[0][1][0].kind!=nnkProcDef or
        not bootstrap[0][1][0][0].eqIdent("inspect") or
        bootstrap[0][1][1].kind!=nnkLetSection or
        bootstrap[0][1][2].kind!=nnkCall or
        not bootstrap[0][1][2][0].eqIdent("hydrate"):
      error("original task bootstrap shape changed")
    result=newStmtList()
    for i in 0 ..< source.len-1: result.add(source[i].copyNimTree)
  originalTaskComponent()
  import isonim/dsl/stable_ids
  let context=newInternalClientCreationOrdinals()
  when defined(taskRoutingOrdinaryControl):
    let renderer=WebRenderer()
  else:
    let renderer=newInternalClientRenderer(context)
  let mount=document.getElementById("root")
  hydrate(proc():Node=Node(taskApp(renderer)),mount)
  proc query(element:Element):cstring=internalClientCreationOrdinal(context,element)
  proc later():Element=
    withStableInstance("later-task"):
      taskApp(renderer)
  proc callCount():int=calls
  {.emit:"globalThis.actualTask={query:`query`,later:`later`,callCount:`callCount`};".}
else:
  echo "<!doctype html><body><main id='root'>"
  include stable_ids/task_app
  echo "</main>"
