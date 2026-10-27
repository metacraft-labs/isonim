/** Emitted-script registration oracle only. A controlled VM host isolates
 * property lookups/listener registration; real owner Chromium tests remain
 * mandatory for the backend. No cursor/provider is mocked here. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import vm from "node:vm";

const selector = "__isonimInternalReadReplaySelected";
// Actual published2eeb368 default capture body, independently compiled in review.
// A hash freezes exact bytes without shipping a generated browser artifact or
// depending on historical git object availability in ordinary test checkouts.
const priorHash =
  "8f1b555e5393085a177db08c9844904b2b15b84bfac7647d3d7efe73f011a906";
const [ordinaryPath, recordablePath, internalPath, onlyInternal] =
  process.argv.slice(2);
const sources = [ordinaryPath, recordablePath, internalPath].map((p) =>
  readFileSync(p, "utf8"),
);

function execute(source, collision) {
  const counts = { lookups: 0, getter: 0, callback: 0, listeners: 0 };
  const types = [];
  const context = {
    document: {
      addEventListener(type, fn) {
        assert.equal(typeof fn, "function");
        counts.listeners++;
        types.push(type);
      },
    },
    Object: {
      getOwnPropertyDescriptor(target, key) {
        if (key === selector) counts.lookups++;
        return Object.getOwnPropertyDescriptor(target, key);
      },
    },
  };
  context.window = context;
  if (collision === "accessor") {
    Object.defineProperty(context, selector, {
      get() {
        counts.getter++;
        return () => {
          counts.callback++;
        };
      },
    });
  } else if (collision === "function") {
    context[selector] = () => {
      counts.callback++;
      return true;
    };
  } else if (collision === "selected" || collision === "away") {
    context[selector] = {
      internalReadReplay: true,
      selected() {
        counts.callback++;
        return collision === "selected";
      },
    };
  }
  let error;
  try {
    vm.runInNewContext(source, context);
  } catch (caught) {
    error = caught;
  }
  return { counts, types, error, hy: context._$HY };
}

// Positive controls run first even when the ordinary inverse must be rejected.
for (const collision of [
  "selected",
  "away",
  "function",
  "accessor",
  "absent",
]) {
  const result = execute(sources[2], collision);
  assert.equal(
    result.counts.lookups,
    1,
    "explicit internal script inspects its private guard",
  );
  assert.equal(
    result.counts.getter,
    0,
    "internal guard must not invoke a caller accessor",
  );
  if (collision === "selected") {
    assert.match(
      result.error?.message ?? "",
      /internal read Replay does not support prehydration capture/,
    );
    assert.equal(result.counts.listeners, 0);
    assert.equal(result.counts.callback, 1);
    assert.equal(
      result.hy,
      undefined,
      "internal refusal precedes HY initialization",
    );
  } else {
    assert.equal(result.error, undefined);
    assert.deepEqual(result.types, ["click", "input"]);
    assert.ok(Array.isArray(result.hy.events));
    assert.equal(result.counts.callback, collision === "away" ? 1 : 0);
  }
}
console.log("internal SSR refusal/switch-away/collision controls: PASS");

if (onlyInternal !== "--internal-only") {
  const variants =
    onlyInternal === "--ordinary-only"
      ? [[0, "ordinary"]]
      : onlyInternal === "--recordable-only"
        ? [[1, "recordable"]]
        : [
            [0, "ordinary"],
            [1, "recordable"],
          ];
  for (const [index, name] of variants) {
    const source = sources[index];
    for (const collision of [
      "absent",
      "function",
      "accessor",
      "selected",
      "away",
    ]) {
      const result = execute(source, collision);
      assert.equal(
        result.counts.lookups,
        0,
        name + " SSR must not inspect private selector",
      );
      assert.equal(
        result.counts.getter,
        0,
        name + " SSR must not invoke caller getter",
      );
      assert.equal(
        result.counts.callback,
        0,
        name + " SSR must not invoke caller callback",
      );
      assert.equal(result.error, undefined);
      assert.deepEqual(result.types, ["click", "input"]);
      assert.ok(Array.isArray(result.hy.events));
    }
    assert(
      !source.includes(selector),
      name + " SSR must omit private guard bytes",
    );
    assert.equal(
      createHash("sha256").update(source).digest("hex"),
      priorHash,
      name + " SSR must retain exact published capture bytes",
    );
    console.log(name + " SSR exact baseline bytes/no private lookups: PASS");
  }
}
