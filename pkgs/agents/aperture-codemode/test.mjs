import assert from "node:assert/strict";
import { test } from "node:test";
import { runSandbox } from "./sandbox.mjs";
import { search, Upstream } from "./server.mjs";

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

test("deep recursion is a sandbox error, not a host crash", async () => {
  const r = await runSandbox(`async () => { const f = (n) => f(n + 1) + 1; return f(0); }`, echo);
  assert.match(r.error, /stack overflow/);
  assert.equal((await runSandbox(`async () => 1`, echo)).result, 1);
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

test("a busy loop in a pending job is cut, and the next run still works", async () => {
  const r = await runSandbox(`async () => { await codemode.x({}); while (true) {} }`, echo, {
    timeoutMs: 300,
  });
  assert.match(r.error, /interrupted/i);
  assert.equal((await runSandbox(`async () => 1`, echo)).result, 1);
});

test("console output is capped", async () => {
  const r = await runSandbox(`async () => { for (let i = 0; i < 100; i++) console.log("x".repeat(1000)); }`, echo);
  assert.ok(r.logs.join("").length < 25_000);
});

test("empty console lines are capped too", async () => {
  const r = await runSandbox(`async () => { for (let i = 0; i < 100000; i++) console.log(); return "done"; }`, echo);
  assert.equal(r.result, "done");
  assert.ok(r.logs.length >= 19_000 && r.logs.length <= 20_001, `${r.logs.length} entries`);
});

test("excluded tools are hidden and refused", async () => {
  const up = new Upstream("http://unused", ["mail_send_email"]);
  let listings = 0;
  up.client = async () => ({
    listTools: async () => {
      listings++;
      return {
        tools: [
          { name: "mail_send_email", description: "Send an email", inputSchema: { type: "object" } },
          { name: "mail_list_emails", description: "List emails", inputSchema: { type: "object" } },
        ],
      };
    },
    callTool: async ({ name }) => ({ content: [{ type: "text", text: JSON.stringify({ name }) }] }),
  });
  await Promise.all([up.tools(), up.tools()]);
  assert.equal(listings, 1);
  await assert.rejects(up.call("mail_send_email", {}), /Unknown tool/);
  assert.doesNotMatch(search(await up.tools(), "send email"), /mail_send_email/);
  assert.deepEqual(await up.call("mail_list_emails", {}), { name: "mail_list_emails" });
});
