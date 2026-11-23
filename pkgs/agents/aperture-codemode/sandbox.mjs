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
  rt.setInterruptHandler(() => Date.now() > deadline);
  const vm = rt.newContext();
  const deferreds = new Set();
  const pump = () => {
    if (rt.alive) rt.executePendingJobs();
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
        });
      return d.handle;
    });
    vm.setProp(vm.global, "__call", callFn);
    callFn.dispose();
    const logFn = vm.newFunction("__log", (h) => {
      logs.push(vm.getString(h));
    });
    vm.setProp(vm.global, "__log", logFn);
    logFn.dispose();

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
    try {
      vm.dispose();
      rt.dispose();
    } catch {
      // A run cut short can leave handles QuickJS refuses to free; the next run gets a new runtime.
    }
  }
}

function formatError(e) {
  if (e && typeof e === "object") return e.stack ? `${e.name}: ${e.message}\n${e.stack}` : `${e.name ?? "Error"}: ${e.message ?? JSON.stringify(e)}`;
  return String(e);
}
