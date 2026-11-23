import assert from "node:assert/strict";
import { test } from "node:test";
import { runSandbox } from "./sandbox.mjs";
import { search } from "./server.mjs";

const echo = async (name, input) => ({ name, input });

test("returns the function's value and console output", async () => {
  const r = await runSandbox(`async () => { console.log("hi", { a: 1 }); return [1, 2]; }`, echo);
  assert.deepEqual(r, { result: [1, 2], logs: ['hi {"a":1}'] });
});

test("chains tool calls", async () => {
  const r = await runSandbox(
    `async () => {
      const a = await codemode.first({ x: 1 });
      const [b, c] = await Promise.all([codemode.second(a), codemode.third()]);
      return [b.name, b.input.input.x, c.input];
    }`,
    echo,
  );
  assert.deepEqual(r.result, ["second", 1, {}]);
});

test("tool errors are catchable in the sandbox", async () => {
  const r = await runSandbox(
    `async () => { try { await codemode.boom({}); } catch (e) { return e.message; } }`,
    async () => {
      throw new Error("upstream said no");
    },
  );
  assert.equal(r.result, "upstream said no");
});

test("reports uncaught errors", async () => {
  const r = await runSandbox(`async () => { throw new TypeError("bad"); }`, echo);
  assert.match(r.error, /TypeError: bad/);
});

test("has no host access", async () => {
  const r = await runSandbox(
    `async () => [typeof fetch, typeof process, typeof require, typeof setTimeout]`,
    echo,
  );
  assert.deepEqual(r.result, ["undefined", "undefined", "undefined", "undefined"]);
});

test("stops a busy loop", async () => {
  const r = await runSandbox(`async () => { while (true) {} }`, echo, { timeoutMs: 300 });
  assert.match(r.error, /interrupted/i);
});

test("stops a hung tool call", async () => {
  const r = await runSandbox(`async () => codemode.slow({})`, () => new Promise(() => {}), {
    timeoutMs: 300,
  });
  assert.match(r.error, /Timed out/);
});

test("search ranks by name and returns declarations", () => {
  const tools = new Map([
    ["sure_get_transactions", { name: "sure_get_transactions", description: "List transactions", inputSchema: { type: "object", properties: { from: { type: "string" } } } }],
    ["sure_get_accounts", { name: "sure_get_accounts", description: "List accounts", inputSchema: { type: "object" } }],
    ["mail_list_emails", { name: "mail_list_emails", description: "List emails", inputSchema: { type: "object" } }],
  ]);
  const out = search(tools, "sure transactions", 1);
  assert.match(out, /sure_get_transactions: \(input/);
  assert.doesNotMatch(out, /mail_list_emails/);
  assert.match(out, /1 more matches/);
  assert.match(search(tools, ""), /sure \(2\), mail \(1\)/);
});
