// Merge compiler-only module fragments. The bundle hash is deliberately a
// post-build input: source metadata never needs to appear in executable JS.
import { readFileSync, readdirSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';

export function mergeManifest(fragments, bundle, buildId) {
  const iids = {};
  for (const name of readdirSync(fragments).filter(x => x.endsWith('.json')).sort()) {
    const data = JSON.parse(readFileSync(join(fragments, name), 'utf8'));
    for (const [iid, metadata] of Object.entries(data)) {
      if (Object.hasOwn(iids, iid)) throw new Error(`duplicate iid: ${iid}`);
      iids[iid] = metadata;
    }
  }
  if (!Object.keys(iids).length) throw new Error('manifest has no stamped elements');
  return {buildId, bundleSha256: createHash('sha256').update(readFileSync(bundle)).digest('hex'),
    iids, experiments: {}, routes: {}, seams: {version: 1}};
}
export function resolveIidMetadata(manifest, iid) {
  // Runtime ids add opaque structural caller hashes and escaped reconcile keys.
  // Metadata remains indexed by the stable template prefix; no protocol change.
  if (typeof iid !== 'string' || !/^[a-z2-7]{12}(?:@[a-z2-7]{12})*(?:#[^#]*)*$/.test(iid))
    throw new Error('invalid runtime iid: ' + iid);
  const metadata = manifest.iids[iid.slice(0, 12)];
  if (!metadata) throw new Error('unknown template iid: ' + iid.slice(0, 12));
  return metadata;
}
function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, sorted(value[k])]));
  return value;
}
if (process.argv[1]?.endsWith('isonim_manifest.mjs')) {
  const [fragments, bundle, output, buildId] = process.argv.slice(2);
  if (!buildId) throw new Error('usage: isonim_manifest.mjs FRAGMENTS BUNDLE OUTPUT BUILD_ID');
  mkdirSync(dirname(output), {recursive: true});
  writeFileSync(output, JSON.stringify(sorted(mergeManifest(fragments, bundle, buildId)), null, 2) + '\n');
}
