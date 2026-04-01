## Web Components support for IsoNim.
## Register custom elements backed by IsoNim's reactive system.
## Mirrors SolidJS solid-element API patterns.

when not defined(js):
  {.error: "isonim/web/custom_element requires the JS backend".}

import std/[jsffi]
import dom_api

type
  CustomElementContext* = ref object
    ## Context passed to the template function during rendering.
    element*: Element        ## The custom element instance
    renderRoot*: Element     ## Shadow root (or element if no Shadow DOM)

  PropDef* = object
    ## Definition of a single observed property.
    name*: cstring
    default*: cstring

  CustomElementDef* = object
    ## Full custom element definition.
    tagName*: cstring
    props*: seq[PropDef]
    useShadow*: bool
    render*: proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring)

proc registerCustomElement*(
    tagName: cstring;
    props: openArray[PropDef];
    renderFn: proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring);
    useShadow: bool = true) =
  ## Registers a custom HTML element with the browser.
  ##
  ## tagName: hyphenated custom element name (e.g., "my-counter")
  ## props: observed attributes with defaults
  ## renderFn: called on connectedCallback to render the component
  ## useShadow: whether to use Shadow DOM (default: true)
  ##
  ## Example:
  ##   registerCustomElement("my-counter",
  ##     [PropDef(name: "count", default: "0")],
  ##     proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
  ##       var count = createSignal(parseInt($getProp("count")))
  ##       let el = document.createElement("div")
  ##       createRenderEffect proc() =
  ##         el.textContent = cstring($count.val)
  ##       ctx.renderRoot.appendChild(el)
  ##   )

  # Build a plain JS object for defaults and a JS array for attr names
  var defaultObj = newJsObject()
  var attrArr = newJsObject()
  {.emit: [attrArr, " = [];"].}
  for p in props:
    defaultObj[p.name] = p.default
    {.emit: [attrArr, ".push(", p.name, ");"].}

  # Store renderFn and config in closures accessible from JS
  var storedRenderFn = renderFn
  var storedUseShadow = useShadow

  # Register via JS emit
  {.emit: ["""
    (function() {
      var nimRenderFn = """, storedRenderFn, """;
      var nimUseShadow = """, storedUseShadow, """;
      var nimDefaults = """, defaultObj, """;
      var nimAttrNames = """, attrArr, """;

      class NimCustomElement extends HTMLElement {
        static get observedAttributes() {
          var result = [];
          for (var i = 0; i < nimAttrNames.length; i++) {
            result.push(nimAttrNames[i]);
          }
          return result;
        }

        constructor() {
          super();
          this._props = {};
          this._propSignals = {};
          this._disposed = false;
          this._disposeFn = null;
          this._connected = false;

          // Initialize defaults
          for (var i = 0; i < nimAttrNames.length; i++) {
            var name = nimAttrNames[i];
            this._props[name] = nimDefaults[name] || '';
          }
        }

        connectedCallback() {
          if (this._connected) return;
          this._connected = true;

          var self = this;
          var renderRoot;
          if (nimUseShadow) {
            renderRoot = this.attachShadow({mode: 'open'});
          } else {
            renderRoot = this;
          }

          // Read initial attribute values
          for (var i = 0; i < nimAttrNames.length; i++) {
            var name = nimAttrNames[i];
            var attrVal = this.getAttribute(name);
            if (attrVal !== null) {
              this._props[name] = attrVal;
            }
          }

          // Create a getProp function that reads from _props
          var getProp = function(name) {
            return self._props[name] || '';
          };

          // Build context
          var ctx = {element: self, renderRoot: renderRoot};

          // Call Nim render function
          nimRenderFn(ctx, getProp);
        }

        attributeChangedCallback(name, oldValue, newValue) {
          this._props[name] = newValue || '';
          // If there are signal update callbacks, call them
          if (this._propSignals[name]) {
            this._propSignals[name](newValue || '');
          }
        }

        disconnectedCallback() {
          this._connected = false;
          if (this._disposeFn) {
            this._disposeFn();
            this._disposeFn = null;
          }
          this._disposed = true;
        }
      }

      customElements.define(""", tagName, """, NimCustomElement);
    })();
  """].}

proc propDef*(name: cstring, default: cstring = ""): PropDef =
  ## Convenience constructor for PropDef.
  PropDef(name: name, default: default)
