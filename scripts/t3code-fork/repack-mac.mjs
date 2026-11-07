// Swaps the fork's server build into upstream's macOS app and re-signs it ad hoc.
//
//   repack-mac.mjs <dir holding "T3 Code (Nightly).app"> <server dist dir> <out zip>
//
// The app's asar integrity hash covers the archive header, so it is recomputed;
// the unpacked native modules stay unpacked. server-compile-cache goes: it is
// keyed to the original bundle.
import asar from "@electron/asar";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const [work, dist, outZip] = process.argv.slice(2);
const app = path.join(work, "T3 Code (Nightly).app");
const res = path.join(app, "Contents/Resources");
const archive = path.join(res, "app.asar");
const unpacked = path.join(res, "app.asar.unpacked");

// unpackDir = the package roots under node_modules in app.asar.unpacked
const nm = path.join(unpacked, "node_modules");
const roots = [];
for (const name of fs.readdirSync(nm)) {
  if (name.startsWith("@")) for (const sub of fs.readdirSync(path.join(nm, name))) roots.push(`${name}/${sub}`);
  else roots.push(name);
}
const unpackDir = `{${roots.map((r) => `node_modules/${r}`).join(",")}}`;
console.log("unpackDir", unpackDir);

const tmp = path.join(work, "asar-src");
fs.rmSync(tmp, { recursive: true, force: true });
asar.extractAll(archive, tmp);
const target = path.join(tmp, "apps/server/dist");
if (!fs.existsSync(target)) throw new Error("apps/server/dist missing in asar");
fs.rmSync(target, { recursive: true });
fs.cpSync(dist, target, { recursive: true, filter: (src) => !src.endsWith(".map") });

fs.rmSync(archive);
fs.rmSync(unpacked, { recursive: true });
await asar.createPackageWithOptions(tmp, archive, { unpackDir });
fs.rmSync(tmp, { recursive: true });

const header = asar.getRawHeader(archive).headerString;
const hash = crypto.createHash("sha256").update(header).digest("hex");
const plist = path.join(app, "Contents/Info.plist");
execFileSync("plutil", ["-replace", "ElectronAsarIntegrity", "-json", JSON.stringify({ "Resources/app.asar": { algorithm: "SHA256", hash } }), plist]);
fs.rmSync(path.join(res, "app-update.yml"), { force: true });
fs.rmSync(path.join(res, "server-compile-cache"), { recursive: true, force: true });
execFileSync("codesign", ["--force", "--deep", "-s", "-", app], { stdio: "inherit" });
fs.rmSync(outZip, { force: true });
execFileSync("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app, outZip], { stdio: "inherit" });
console.log("done", outZip, hash);
