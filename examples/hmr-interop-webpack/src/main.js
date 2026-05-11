// Webpack picks the .nim import up via the rule in
// webpack.config.js. The loader compiles the file and emits a
// self-accept marker; the bundle's top-level code runs and
// publishes mountCounter on globalThis.
import "./counter.nim";

globalThis.__isonim_webpack_demo_mountCounter();
