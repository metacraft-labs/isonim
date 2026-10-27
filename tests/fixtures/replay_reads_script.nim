import std/strutils
import isonim/ssr/markers
# Print the actual supported generator output, never a copied capture helper.
let html = generateHydrationScript()
stdout.write(html[8 ..< html.find("</script>")])
