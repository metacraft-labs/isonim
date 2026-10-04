/** Capture-side scheduling boundary. Only actual RAF callback arguments count
 * as observations. Equal observations keep waiting; invalid/backward observations
 * reject. This self-contained function runs unchanged inside page.evaluate.
 */
export function waitForAdvancingFrames(timeoutMs, scheduler = globalThis) {
  return new Promise((resolve, reject) => {
    let frame = null, timer = null, first = null, settled = false;
    const deadline = scheduler.performance.now() + timeoutMs;
    const finish = (error, times) => {
      if (settled) return;
      settled = true;
      if (frame !== null) scheduler.cancelAnimationFrame(frame);
      if (timer !== null) scheduler.clearTimeout(timer);
      frame = timer = null;
      if (error) reject(error); else resolve(times);
    };
    const expired = () => finish(new Error('capture readiness deadline exceeded before advancing frames'));
    const observe = time => {
      frame = null;
      if (settled) return;
      try {
        if (scheduler.performance.now() >= deadline) return expired();
        if (typeof time !== 'number' || !Number.isFinite(time) || time < 0)
          throw new Error('invalid animation frame observation');
        if (first === null) first = time;
        else if (time < first) throw new Error('backward animation frame observation');
        else if (time > first) return finish(null, [first, time]);
        frame = scheduler.requestAnimationFrame(observe);
      } catch (error) { finish(error); }
    };
    try {
      if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return expired();
      timer = scheduler.setTimeout(expired, timeoutMs);
      frame = scheduler.requestAnimationFrame(observe);
    } catch (error) { finish(error); }
  });
}
