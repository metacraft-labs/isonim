// beacon.js: relays "busy" announcements of the web-worker fixture's
// compile module (preview_compile.nim) to the test, as a request for
// /busy-started that web-worker.spec.ts routes. It runs on its own thread,
// so the announcement leaves even while the announcing thread spins (a
// fetch from that thread would wait for it to yield).
const channel = new BroadcastChannel("isonim-busy");
channel.onmessage = () => {
  fetch("/busy-started").catch(() => {});
};
postMessage("ready");
