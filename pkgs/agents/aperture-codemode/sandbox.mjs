// Runs model-written code in QuickJS (WebAssembly): no fs, network, process or require.
// The only way out is `codemode.<tool>(input)`, which calls `call(name, input)` on the host.
import releaseSync from "@jitl/quickjs-wasmfile-release-sync";
import { newQuickJSWASMModuleFromVariant } from "quickjs-emscripten-core";

const PRELUDE = `
const codemode = new Proxy({}, {
  get: (_, name) => async (input) =>
    JSON.parse(await __call(String(name), JSON.stringify(input === undefined ? {} : input))),
});
const __fmt = (a) => a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ");
const console = {
  log: (...a) => __log(__fmt(a)),
  info: (...a) => __log(__fmt(a)),
  warn: (...a) => __log("[warn] " + __fmt(a)),
  error: (...a) => __log("[error] " + __fmt(a)),
};
`;

const QJS = await newQuickJSWASMModuleFromVariant(releaseSync);
// QuickJS runs on Node's main thread: cap each synchronous slice so a busy loop
// can't stall other calls for the whole deadline.
const SLICE_MS = 5_000;
const MAX_LOG_CHARS = 20_000;

/**
 * @param {string} fn  an async arrow function's source (normalizeCode output)
 * @param {(name: string, input: unknown) => Promise<unknown>} call
 * @returns {Promise<{ result?: unknown, error?: string, logs: string[] }>}
 */
export async function runSandbox(fn, call, { timeoutMs = 120_000, memoryBytes = 64 << 20 } = {}) {
  const logs = [];
  const deadline = Date.now() + timeoutMs;
  const rt = QJS.newRuntime();
  rt.setMemoryLimit(memoryBytes);
  rt.setMaxStackSize(1 << 20);
  let sliceEnd = Infinity;
  rt.setInterruptHandler(() => Date.now() > Math.min(deadline, sliceEnd));
  const vm = rt.newContext();
  const deferreds = new Set();
  const pump = () => {
    if (!rt.alive) return;
    sliceEnd = Date.now() + SLICE_MS;
    const r = rt.executePendingJobs();
    if (r.error) r.error.dispose();
  };
  let timer;

  try {
    const callFn = vm.newFunction("__call", (nameH, inputH) => {
      const name = vm.getString(nameH);
      const input = JSON.parse(vm.getString(inputH));
      const d = vm.newPromise();
      deferreds.add(d);
      Promise.resolve()
        .then(() => call(name, input))
        .then(
          (r) => {
            if (!d.alive) return;
            const h = vm.newString(JSON.stringify(r === undefined ? null : r));
            d.resolve(h);
            h.dispose();
          },
          (e) => {
            if (!d.alive) return;
            const h = vm.newError(String(e?.message ?? e));
            d.reject(h);
            h.dispose();
          },
        )
        .finally(() => {
          deferreds.delete(d);
          if (d.alive) d.dispose();
          pump();
        })
        .catch((e) => console.error("aperture-codemode: host call failed:", e));
      return d.handle;
    });
    vm.setProp(vm.global, "__call", callFn);
    callFn.dispose();
    let logChars = 0;
    const logFn = vm.newFunction("__log", (h) => {
      if (logChars > MAX_LOG_CHARS) return;
      const line = vm.getString(h);
      logChars += line.length;
      logs.push(logChars > MAX_LOG_CHARS ? `${line.slice(0, 1000)}… (console output cut)` : line);
    });
    vm.setProp(vm.global, "__log", logFn);
    logFn.dispose();

    sliceEnd = Date.now() + SLICE_MS;
    const evaluated = vm.evalCode(
      `${PRELUDE}\n(${fn})().then((v) => JSON.stringify(v === undefined ? null : v));`,
      "code.js",
    );
    if (evaluated.error) {
      const error = vm.dump(evaluated.error);
      evaluated.error.dispose();
      return { error: formatError(error), logs };
    }
    const settled = vm.resolvePromise(evaluated.value);
    evaluated.value.dispose();
    pump();

    const timeout = new Promise((resolve) => {
      timer = setTimeout(() => resolve("timeout"), Math.max(0, deadline - Date.now()));
    });
    const outcome = await Promise.race([settled, timeout]);
    if (outcome === "timeout") return { error: `Timed out after ${timeoutMs / 1000} s`, logs };
    if (outcome.error) {
      const error = vm.dump(outcome.error);
      outcome.error.dispose();
      return { error: formatError(error), logs };
    }
    const json = vm.getString(outcome.value);
    outcome.value.dispose();
    return { result: JSON.parse(json), logs };
  } finally {
    clearTimeout(timer);
    for (const d of deferreds) if (d.alive) d.dispose();
    // A run cut short can leave handles QuickJS refuses to free; the next run gets a new runtime.
    try {
      vm.dispose();
    } catch {}
    try {
      rt.dispose();
    } catch {}
  }
}

function formatError(e) {
  if (e && typeof e === "object") return e.stack ? `${e.name}: ${e.message}\n${e.stack}` : `${e.name ?? "Error"}: ${e.message ?? JSON.stringify(e)}`;
  return String(e);
}
