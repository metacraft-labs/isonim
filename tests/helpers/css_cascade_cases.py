"""Generates the writer-vs-Chromium cascade cases for
`tests/test_editor_css_cascade_chromium.mjs`. Deterministic (seeded).

Adopted from the edit-target review's probe generator, with the hand cases of
the round-2 fixes added. A case tagged `unanswerable` holds a condition the
preview cannot answer (`@container`, a rule nested in a style rule); a
refusal there is expected. argv[1]: the output file.
"""
import json, random, sys
KNOWN = ["@media (max-width: 1080px)", "@media (min-width: 900px)",
         "@media screen and (max-width: 600px)",
         "@media (min-width: 400px) and (max-width: 1100px)",
         "@media print", "@media screen", "@media only screen and (min-width: 1200px)"]
UNKNOWN = ["@media (max-width: 50em)", "@media (width <= 900px)",
           "@media (400px <= width <= 1100px)", "@media (prefers-color-scheme: dark)",
           "@media (prefers-color-scheme: light)", "@supports (display: grid)",
           "@media not all and (max-width: 600px)",
           "@media (min-width: 30em) and (max-width: 1100px)"]
LIST = ["@media (max-width: 600px), (min-width: 1200px)"]
LAYERS = ["@layer a", "@layer b", "@layer a.c", "@layer", "@layer c"]
PREFIXES = [
  ["@charset \"utf-8\";"],
  ["@layer b, a;"], ["@layer c, a.c, b;"], ["@layer a.c, a;"],
  ["@import url(\"data:text/css,.q{}\") layer(b);"],
  ["@import url(\"data:text/css,.player{}\") layer(b);"],
  ["@namespace svg url(http://www.w3.org/2000/svg);"],
  ["@charset \"utf-8\";", "@layer b, a;", "@import url(\"data:text/css,.q{}\") layer(c);",
   "@namespace svg url(http://www.w3.org/2000/svg);"],
]
WIDTHS = [390, 850, 1024, 1440]

def build(rules, prefix):
  out = list(prefix)
  for r in rules:
    body = ".x { %s: %s%s; }" % (r["prop"], r["value"], " !important" if r["important"] else "")
    for w in reversed(r["wrap"]):
      body = "%s { %s }" % (w, body)
    out.append(body)
  return "\n".join(out) + "\n"

def classify(wraps):
  kinds = set()
  for w in wraps:
    if w in UNKNOWN: kinds.add("unknown")
    elif w in LIST: kinds.add("list")
    elif w.startswith("@layer"): kinds.add("layer")
    else: kinds.add("media")
  return kinds

cases = []
rng = random.Random(20261115)
def add(name, css, width, tags):
  cases.append({"id": len(cases), "name": name, "css": css, "selector": ".x",
                "property": "padding-left", "width": width, "value": "777px", "tags": sorted(tags)})

# Hand cases.
hand = [
 ("issue example", ".x { padding-left: 1px !important; }\n@media (max-width: 1080px) { .x { padding-left: 2px; } }\n"),
 ("media list OR", ".x { padding-left: 1px; }\n@media (max-width: 600px), (min-width: 1200px) { .x { padding-left: 2px; } }\n"),
 ("import layer url contains 'layer'", "@import url(\"data:text/css,.player{}\") layer(theme);\n@layer base { .x { padding-left: 1px; } }\n@layer theme { .x { padding-left: 2px; } }\n"),
 ("import layer plain", "@import url(\"data:text/css,.q{}\") layer(theme);\n@layer base { .x { padding-left: 1px; } }\n@layer theme { .x { padding-left: 2px; } }\n"),
 ("import anonymous layer then named", "@import url(\"data:text/css,.q{}\") layer;\n@layer base { .x { padding-left: 1px; } }\n"),
 ("layer statement in non-matching media", "@media print { @layer theme; }\n@layer base { .x { padding-left: 1px; } }\n@layer theme { .x { padding-left: 2px; } }\n"),
 ("layer block in non-matching media", "@media print { @layer theme { .y { color: red; } } }\n@layer base { .x { padding-left: 1px; } }\n@layer theme { .x { padding-left: 2px; } }\n"),
 ("layer statement in supports", "@supports (display: grid) { @layer theme, base; }\n@layer base { .x { padding-left: 1px; } }\n@layer theme { .x { padding-left: 2px; } }\n"),
 ("revert-layer winner", "@layer a { .x { padding-left: 1px; } }\n@layer b { .x { padding-left: revert-layer; } }\n"),
 ("revert-layer unlayered", "@layer a { .x { padding-left: 1px; } }\n.x { padding-left: revert-layer; }\n"),
 ("important across layers + unlayered", "@layer a, b;\n@layer b { .x { padding-left: 2px !important; } }\n@layer a { .x { padding-left: 1px !important; } }\n.x { padding-left: 3px !important; }\n"),
 ("nested own vs sub important", "@layer o { .x { padding-left: 1px !important; } @layer i { .x { padding-left: 2px !important; } } }\n"),
 ("nested own vs sub normal", "@layer o { .x { padding-left: 1px; } @layer i { .x { padding-left: 2px; } } }\n"),
 ("anonymous then named", "@layer { .x { padding-left: 1px; } }\n@layer a { .x { padding-left: 2px; } }\n"),
 ("dotted declared later", "@layer a.y { .x { padding-left: 1px; } }\n@layer b { .x { padding-left: 2px; } }\n@layer a.z { .x { padding-left: 3px; } }\n"),
 ("after charset/import/namespace", "@charset \"utf-8\";\n@import url(\"data:text/css,.q{}\");\n@namespace svg url(http://www.w3.org/2000/svg);\n.x { padding-left: 1px; }\n@media (max-width: 1080px) { .x { padding-left: 2px; } }\n"),
 ("em media only", ".x { padding-left: 1px; }\n@media (max-width: 50em) { .x { padding-left: 2px; } }\n"),
 ("range media", ".x { padding-left: 1px; }\n@media (width <= 900px) { .x { padding-left: 2px; } }\n"),
 ("dark mode color-scheme", ".x { padding-left: 1px; }\n@media (prefers-color-scheme: dark) { .x { padding-left: 2px; } }\n"),
 ("uppercase IMPORTANT", ".x { padding-left: 1px ! IMPORTANT; }\n@media (max-width: 1080px) { .x { padding-left: 2px; } }\n"),
 ("important in comment", ".x { padding-left: 1px /* !important */; }\n@media (max-width: 1080px) { .x { padding-left: 2px; } }\n"),
 ("shorthand important vs longhand later", ".x { padding: 1px !important; }\n@media (max-width: 1080px) { .x { padding-left: 2px; } }\n"),
 ("longhand important in rule with later normal shorthand", ".x { padding-left: 1px !important; padding: 5px; }\n@media (max-width: 1080px) { .x { padding-left: 2px; } }\n"),
 ("layer named media-ish", "@layer reset, layout;\n@layer layout { .x { padding-left: 1px; } }\n@layer reset { .x { padding-left: 2px; } }\n"),
 ("LAYER uppercase at-rule", "@LAYER b, a;\n@layer a { .x { padding-left: 1px; } }\n@layer b { .x { padding-left: 2px; } }\n"),
 ("nested after a declaration", ".x { padding-left: 1px; }\n.y { color: red; .x { padding-left: 2px; } }\n"),
 ("container", ".x { padding-left: 1px; }\n@container (min-width: 10px) { .x { padding-left: 2px; } }\n"),
 ("media list holds in its second query", ".x { padding-left: 1px; }\n@media print, (max-width: 5000px) { .x { padding-left: 2px; } }\n"),
 ("em width", ".x { padding-left: 1px; }\n@media (min-width: 40em) { .x { padding-left: 2px; } }\n"),
 ("light scheme", ".x { padding-left: 1px; }\n@media (prefers-color-scheme: light) { .x { padding-left: 2px; } }\n@media (prefers-color-scheme: dark) { .x { padding-left: 3px; } }\n"),
 ("important shorthand decides an absent longhand", ".x { padding: 1px !important; }\n"),
 ("later normal shorthand decides an earlier longhand", ".x { padding-left: 1px; padding: 2px; }\n"),
 ("import with supports and layer", "@import url(\"data:text/css,.q{}\") layer(z) supports(display: grid);\n@layer y { .x { padding-left: 1px; } }\n@layer z { .x { padding-left: 2px; } }\n"),
]
UNANSWERABLE = {"nested after a declaration", "container"}
for name, css in hand:
  for w in WIDTHS:
    add(name, css, w, ["hand"] + (["unanswerable"] if name in UNANSWERABLE else []))

# Random cases.
for n in range(400):
  k = rng.randint(1, 5)
  rules = []
  for i in range(k):
    wrap = []
    r = rng.random()
    if r < 0.35: wrap = [rng.choice(LAYERS)]
    elif r < 0.6: wrap = [rng.choice(KNOWN)]
    elif r < 0.7: wrap = [rng.choice(UNKNOWN)]
    elif r < 0.75: wrap = [rng.choice(LIST)]
    elif r < 0.85: wrap = [rng.choice(LAYERS), rng.choice(KNOWN)]
    elif r < 0.9: wrap = [rng.choice(KNOWN), rng.choice(LAYERS)]
    elif r < 0.93: wrap = ["@layer a", "@layer d"]
    rules.append({"wrap": wrap, "prop": rng.choice(["padding-left", "padding-left", "padding"]),
                  "value": ("revert-layer" if rng.random() < 0.05 else "%dpx" % (i + 1)),
                  "important": rng.random() < 0.25})
  if rng.random() < 0.6:
    rules.insert(0, {"wrap": [], "prop": "padding-left", "value": "50px", "important": rng.random() < 0.15})
  prefix = rng.choice(PREFIXES) if rng.random() < 0.4 else []
  css = build(rules, prefix)
  tags = set()
  for r in rules: tags |= classify(r["wrap"])
  for p in prefix:
    if "import" in p: tags.add("import")
    if p.startswith("@layer"): tags.add("layerstatement")
  add("random-%d" % n, css, rng.choice(WIDTHS), tags)
json.dump(cases, open(sys.argv[1], "w"), indent=1)
print(len(cases))
