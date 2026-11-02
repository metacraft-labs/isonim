## Actual SSR for the rejected hydration-raw equality/adoption control. No fake
## hydration flags or parser are used; the browser's real hydration path adopts
## the server div/b before its comparison template is created.
import isonim/dsl/ui
import isonim/ssr/[renderer,escape,markers]
echo "<!doctype html><body><main id='root'></main><main id='raw-root'>"
echo renderToString(proc(): string = ui: tdiv: raw "<b>x</b>")
echo "</main>"
echo generateHydrationScript()
