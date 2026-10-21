# Stable element identities

Compile with `-d:isonimStableIds` to stamp handler targets and form controls
with `data-iid`. Both `ui(renderer)` and string/streaming SSR use the same
structural identity. Share component source (for example with `isomorphicUi`)
between server and client; independently authored trees have independent IDs.

`data-iid` is reserved on every DSL element when stable IDs are enabled,
including ASCII case variants of the HTML attribute name.
Authoring it explicitly is a compile-time error, including on elements without
handlers, so authored attributes cannot overwrite or alias generated identities.
Without `-d:isonimStableIds`, it remains an ordinary attribute.

An identity includes the module path relative to the project root, the enclosing
component name, its DSL-block ordinal, and the element's tag/ordinal path. A
literal `key = "name"` replaces the element's ordinal, preserving its identity
when siblings are inserted before it. Source line and column are metadata only.
Set `-d:iidProjectRoot=/absolute/project/root` consistently for both compilers.

A reusable component evaluated in a DSL child expression gets a structural
caller scope automatically, for example:

```nim
proc pair(r: auto): auto =
  isomorphicUi(r):
    tdiv:
      raw child(r)
      raw child(r)
```

The two children have distinct IDs even when they share one template. Nested
component calls append scopes derived from caller paths, never from source
lines or mutable invocation counters. `raw` accepts a client node or SSR markup;
ordinary node-returning helper calls also receive caller scopes. A keyed ancestor
anchors its descendant call slots against insertion of unrelated siblings.

The runtime shape is `templateIid@callerScope[@callerScope…]#key[#key…]`.
`forEachKeyed` appends the item's `$` representation to the static ID. Nested
lists append successive key segments; `%` and `#` in a key are escaped. For a
corresponding server-side loop, import `isonim/dsl/stable_ids` and render its
component inside `withStableKey($item):`. Render callbacks restore the previous
key scope even if they raise. Reactive lists retain their caller scope when
creating rows on later updates. Use stable textual item identities.

A raw/helper expression is one structural caller slot. If its implementation
internally creates several copies of the same template, give those copies
separate `withStableKey` scopes. Arbitrary Nim helper internals are not rewritten.
Calls made outside DSL expressions do not acquire automatic caller slots. Use
distinct `withStableKey` scopes for repeated instances in such code. Hydratable
SSR render boundaries reject duplicate generated IDs; opaque prebuilt HTML
concatenated outside a render boundary needs explicit instance keys before
mounting.

The browser renderer's typed `noteElement(el, iid)` overload indexes these IDs.
`resolveIid(iid)` validates the claim and returns its node, or nil after it is
collected. Two simultaneously connected targets with the same ID raise an
error. Detached nodes are provisional, so reconciliation may construct a
successor before removing its predecessor; validation runs after the DOM batch
and synchronously on resolution. Reclaiming the same hydration node is allowed.
The weak index does not retain disposed trees, and finalizing an old node cannot
remove its successor's claim. Browser builds need `WeakRef`,
`FinalizationRegistry`, `MutationObserver` and `queueMicrotask` support.

`just manifest-check` compiles the shared task fixture for native SSR and JS,
merges per-module compiler fragments, and compares the resulting manifests.
The fixture's delivered JS bundle supplies `bundleSha256` to both manifests.
The resulting `build/isonim-manifest.json` contains source locations; the bundle
contains IDs only. Production bundles disable compiler stack/line tracing to
exclude the compiler's own debug source paths as well.

For an application build, create a fresh directory and pass it with
`-d:iidManifestDir=/absolute/fragments`; generated `static` blocks write module
fragments there. Merge them after bundling:

```sh
node tools/isonim_manifest.mjs FRAGMENTS BUNDLE OUTPUT BUILD_ID
```

The manifest keeps one source metadata entry per twelve-character template ID.
The exported `resolveIidMetadata(manifest, runtimeIid)` helper validates caller
and key suffixes, then looks up that leading template ID. It maps both nested
instances and newly created keyed rows to the exact template file/tag/line;
there is no recorder wire-format change.

The merger sorts object keys and rejects duplicate IDs. Keep compiler fragment
directories separate for concurrent compilers and clear them before a new build.
`just test-stable-ids` checks compiler stability, keyed reconciliation and real
Chromium hydration/lifecycle. `just test-stable-id-mutants` verifies that source
position hashing, collisions, authored identity attributes and backend-dependent
hashing are rejected; a sixth mutation proves removing caller scopes breaks
reusable-target identity. Default builds erase scope arguments and match the
unwrapped code byte for byte.
