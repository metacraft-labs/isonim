#!/usr/bin/env bash
# Build one authored task component for both backends, then bind both manifests
# to the same delivered JS bundle. Separate fragment roots prevent stale data.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
out="$root/build/stable-ids"
rm -rf "$out"
mkdir -p "$out/c" "$out/js"
fixture=tests/fixtures/stable_ids/task_app.nim
common=(--hints:off -d:release --stackTrace:off --lineTrace:off --path:src --path:../nim-everywhere/src -d:isonimStableIds "-d:iidProjectRoot=$root")
nim c "${common[@]}" -d:isServer "-d:iidManifestDir=$out/c" --out:"$out/task-app" "$fixture"
nim js "${common[@]}" "-d:iidManifestDir=$out/js" --out:"$out/task-app.js" "$fixture"
"$out/task-app" > "$out/markup.html"
build_id="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain)" ]; then build_id="${build_id}-dirty"; fi
node tools/isonim_manifest.mjs "$out/c" "$out/task-app.js" "$out/c.json" "$build_id"
node tools/isonim_manifest.mjs "$out/js" "$out/task-app.js" "$out/js.json" "$build_id"
diff -u "$out/c.json" "$out/js.json"
cp "$out/js.json" build/isonim-manifest.json
node --input-type=module - "$out" <<'JS'
import {readFileSync, writeFileSync} from 'node:fs';
const out = process.argv[2];
const manifest = JSON.parse(readFileSync(out + '/js.json', 'utf8'));
if (Object.keys(manifest.iids).length !== 44) throw new Error('expected exactly 44 stamped task controls');
const bundle = readFileSync(out + '/task-app.js', 'utf8');
if (bundle.includes('tests/fixtures/stable_ids') || bundle.includes(process.cwd())) throw new Error('source paths leaked into JS');
const markup = readFileSync(out + '/markup.html', 'utf8');
writeFileSync(out + '/index.html', '<!doctype html><div id="root">' + markup + '</div><script>globalThis.ssrIids=[...document.querySelectorAll("[data-iid]")].map(el=>({el,iid:el.getAttribute("data-iid")}));</script><script src="task-app.js"></script>');
JS
# The negative-control build uses the same authored component without the flag.
nim c --hints:off --path:src --path:../nim-everywhere/src -d:isServer --out:"$out/off" "$fixture"
nim js --hints:off --path:src --path:../nim-everywhere/src --out:"$out/off.js" "$fixture"
{ printf '<!doctype html><div id="root">'; "$out/off"; printf '</div><script src="off.js"></script>'; } > "$out/off.html"
nim js --hints:off -d:release --stackTrace:off --lineTrace:off --path:src --path:../nim-everywhere/src -d:isonimStableIds --out:"$out/keyed.js" tests/fixtures/stable_ids/keyed_client.nim
printf '<!doctype html><div id="root"></div><script src="keyed.js"></script>' > "$out/keyed.html"
# Reusable component fixture: both compilers publish the same template metadata;
# actual runtime identities also carry their structural caller scopes.
mkdir -p "$out/instances/c" "$out/instances/js"
instance_fixture=tests/fixtures/stable_ids/instances.nim
nim c "${common[@]}" -d:isServer "-d:iidManifestDir=$out/instances/c" --out:"$out/instances/app" "$instance_fixture"
nim js "${common[@]}" "-d:iidManifestDir=$out/instances/js" --out:"$out/instances.js" "$instance_fixture"
"$out/instances/app" > "$out/instances/markup.html"
node tools/isonim_manifest.mjs "$out/instances/c" "$out/instances.js" "$out/instances/c.json" "$build_id"
node tools/isonim_manifest.mjs "$out/instances/js" "$out/instances.js" "$out/instances/js.json" "$build_id"
diff -u "$out/instances/c.json" "$out/instances/js.json"
node --input-type=module - "$out" <<'JS'
import {readFileSync, writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {resolveIidMetadata} from './tools/isonim_manifest.mjs';
const out=process.argv[2], manifest=JSON.parse(readFileSync(out+'/instances/js.json','utf8'));
assert.equal(Object.keys(manifest.iids).length,1);
const markup=readFileSync(out+'/instances/markup.html','utf8');
const ids=[...markup.matchAll(/data-iid="([^"]+)"/g)].map(x=>x[1]);
assert.equal(ids.length,5); assert.equal(new Set(ids).size,5);
for (const iid of ids) {
  const metadata=resolveIidMetadata(manifest,iid);
  assert.equal(metadata.tag,'button');
  assert.equal(metadata.file,'tests/fixtures/stable_ids/instances.nim');
  assert(metadata.component.includes('.leaf/'));
}
assert.throws(()=>resolveIidMetadata(manifest,'not-an-iid'),/invalid runtime/);
assert.throws(()=>resolveIidMetadata(manifest,'aaaaaaaaaaaa@bbbbbbbbbbbb'),/unknown template/);
const bundle=readFileSync(out+'/instances.js','utf8');
assert(!bundle.includes(process.cwd()) && !bundle.includes('tests/fixtures/stable_ids'));
writeFileSync(out+'/instances.html','<!doctype html><div id="root">'+markup+'</div><script>globalThis.instanceSsr=[...document.querySelectorAll("[data-iid]")].map(el=>({el,iid:el.getAttribute("data-iid")}));</script><script src="instances.js"></script>');
JS
mkdir -p "$out/instances-keyed-meta"
nim js "${common[@]}" "-d:iidManifestDir=$out/instances-keyed-meta" --out:"$out/instances-keyed.js" tests/fixtures/stable_ids/instances_keyed.nim
printf '<!doctype html><div id="root"></div><script src="instances-keyed.js"></script>' > "$out/instances-keyed.html"

node tools/isonim_manifest.mjs "$out/instances-keyed-meta" "$out/instances-keyed.js" "$out/instances-keyed.json" "$build_id"
