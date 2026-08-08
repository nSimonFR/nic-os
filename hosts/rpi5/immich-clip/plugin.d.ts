// Interface file for `extism-js plugin.js -i plugin.d.ts -o nic_clip.wasm`.
//
// "main" declares what the wasm EXPORTS — the name must match the method name in
// manifest.json, because Immich calls `plugin.call(methodName, ...)`.
//
// "extism:host".user declares what it IMPORTS. Immich registers its host
// functions under the `extism:host/user` namespace (plugin.repository.js), and
// only hands the real implementations to plugins whose method sets
// `hostFunctions: true` — everything else gets a stub that throws.
declare module "main" {
  export function clipFilter(): I32;
}

declare module "extism:host" {
  interface user {
    httpRequest(ptr: I64): I64;
    // Used instead of chaining immich-plugin-core#assetAddToAlbums: 3.1 runs
    // workflow steps in an unordered query, so a later action step is not
    // reliably later. See the comment in plugin.js.
    addAssetsToAlbums(ptr: I64): I64;
  }
}
