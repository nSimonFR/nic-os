#!/usr/bin/env node
// Moves the fork's issue migrations to the end of upstream's list, in a t3code checkout.
//
//   migrations.mjs detach   drop the issue block from Migrations.ts, so upstream's
//                           new migrations merge in without both sides appending to
//                           the same lines
//   migrations.mjs attach   re-add it after upstream's highest id: rename the files,
//                           renumber imports and entries, FIRST_ISSUE_MIGRATION_ID
//                           and the tests that hard-code the block's start
//
// attach is a no-op when the block already sits after upstream's highest id.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const dir = "apps/server/src/persistence";
const file = path.join(dir, "Migrations.ts");
const migrationsDir = path.join(dir, "Migrations");
const PREVIEW_START = 63; // where the Issues preview recorded the block

const read = (p) => fs.readFileSync(p, "utf8");
const pad = (n) => String(n).padStart(3, "0");
const pad4 = (n) => String(n).padStart(4, "0");

const source = read(file);
const names = [...source.match(/ISSUE_MIGRATION_NAMES = \[([^\]]*)\]/)[1].matchAll(/"(\w+)"/g)].map(
  (m) => m[1],
);
const firstId = Number(source.match(/FIRST_ISSUE_MIGRATION_ID = (\d+);/)[1]);
const entryRe = /^\s*\[(\d+), "(\w+)", Migration(\d+)\],\n/gm;
const importRe = /^import Migration(\d+) from "\.\/Migrations\/\d+_(\w+)\.ts";\n/gm;

if (process.argv[2] === "detach") {
  const out = source
    .replace(entryRe, (line, _id, name) => (names.includes(name) ? "" : line))
    .replace(importRe, (line, _n, name) => (names.includes(name) ? "" : line));
  fs.writeFileSync(file, out);
} else if (process.argv[2] === "attach") {
  const present = [...source.matchAll(entryRe)].filter((m) => names.includes(m[2]));
  const upstreamIds = [...source.matchAll(entryRe)]
    .filter((m) => !names.includes(m[2]))
    .map((m) => Number(m[1]));
  const next = Math.max(...upstreamIds) + 1;
  if (present.length === names.length && next === firstId) {
    console.log(`issue migrations already at ${firstId}`);
    process.exit(0);
  }
  if (present.length > 0) throw new Error("attach expects the issue block to be detached first");

  const files = fs.readdirSync(migrationsDir);
  // Highest id first, so a rename never lands on a file that has not moved yet.
  const moves = names.map((name, i) => ({ name, id: next + i })).reverse();
  for (const { name, id } of moves) {
    for (const f of files.filter((f) => new RegExp(`^\\d+_${name}(\\.test)?\\.ts$`).test(f))) {
      const to = f.replace(/^\d+/, pad(id));
      if (to !== f) fs.renameSync(path.join(migrationsDir, f), path.join(migrationsDir, to));
    }
  }

  // Other files import a migration by path (the preview-upgrade test does).
  for (const [i, name] of names.entries()) {
    let found = "";
    try {
      found = execFileSync("git", ["grep", "-lE", `/[0-9]{3}_${name}\\.ts"`, "--", "apps"], {
        encoding: "utf8",
      });
    } catch {} // exit 1: no references
    const refs = found.split("\n").filter((f) => f && f !== file);
    for (const f of refs) {
      fs.writeFileSync(
        f,
        read(f).replace(new RegExp(`/[0-9]{3}_${name}\\.ts"`, "g"), `/${pad(next + i)}_${name}.ts"`),
      );
    }
  }

  // The block's own tests migrate "up to" one of its ids.
  const delta = next - firstId;
  for (const [i, name] of names.entries()) {
    const test = path.join(migrationsDir, `${pad(next + i)}_${name}.test.ts`);
    if (!fs.existsSync(test)) continue;
    fs.writeFileSync(
      test,
      read(test).replace(/toMigrationInclusive: (\d+)/g, (m, n) =>
        Number(n) >= firstId && Number(n) < firstId + names.length
          ? `toMigrationInclusive: ${Number(n) + delta}`
          : m,
      ),
    );
  }

  let out = source;
  const imports = names.map(
    (name, i) => `import Migration${pad4(next + i)} from "./Migrations/${pad(next + i)}_${name}.ts";\n`,
  );
  const lastImport = [...out.matchAll(importRe)].at(-1);
  const at = lastImport.index + lastImport[0].length;
  out = out.slice(0, at) + imports.join("") + out.slice(at);
  const entries = names
    .map((name, i) => `  [${next + i}, "${name}", Migration${pad4(next + i)}],\n`)
    .join("");
  out = out.replace(/\] as const;\n\nexport const migrationManifest/, `${entries}] as const;\n\nexport const migrationManifest`);
  out = out.replace(/FIRST_ISSUE_MIGRATION_ID = \d+;/, `FIRST_ISSUE_MIGRATION_ID = ${next};`);
  fs.writeFileSync(file, out);

  if (next === firstId) {
    console.log(`issue migrations stay at ${firstId}`);
    process.exit(0);
  }

  // Tests that name where the block starts.
  const reconcile = path.join(dir, "reconcileV2PreviewMigration.test.ts");
  let t = read(reconcile);
  const matrix = t.match(/\[((?:\d+, )*\d+)\]\.flatMap\(\(startId\)/);
  if (matrix && !matrix[1].split(", ").includes(String(firstId))) {
    t = t.replace(matrix[0], matrix[0].replace(matrix[1], `${matrix[1]}, ${firstId}`));
    fs.writeFileSync(reconcile, t);
  }
  const sqlite = path.join(dir, "Sqlite.test.ts");
  let s = read(sqlite);
  s = s.replace(/id >= \d+\)/, `id >= ${next})`).replace(/\$\{id - \d+\}/, `\${id - ${next - PREVIEW_START}}`);
  fs.writeFileSync(sqlite, s);
  console.log(`issue migrations ${firstId} -> ${next}`);
} else {
  console.error("usage: migrations.mjs detach|attach");
  process.exit(2);
}
