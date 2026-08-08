# nic-clip — an external Immich plugin adding a CLIP content filter to Workflows.
#
# Immich 3.1 loads external plugins from IMMICH_PLUGINS_INSTALL_FOLDER: it reads
# each SUBDIRECTORY of that folder expecting `manifest.json` plus the wasm named
# by `wasmPath`. So $out is the install folder and $out/nic-clip is the plugin.
#
# ⚠️ Two upstream quirks conspire here, and the fix is not the obvious one.
#
# 1. The import is keyed on the SHA-256 of manifest.json's *contents*
#    (workflow-execution.service.js -> pluginRepository.getByHash short-circuits
#    when it matches). A rebuilt wasm under an unchanged manifest is silently
#    ignored and the old bytes keep running. So the manifest MUST change whenever
#    the sources do.
#
# 2. The obvious way to do that — bump `version` — does not work. The `plugin`
#    table carries BOTH `plugin_name_version_uq UNIQUE (name, version)` and
#    `plugin_name_uq UNIQUE (name)`, while the upsert only declares
#    `onConflict(['name','version'])`. A new version is therefore an INSERT that
#    trips the name-only constraint: `Key (name)=(nic-clip) already exists`, the
#    import fails, and the OLD plugin stays loaded. Observed, not theorised.
#
# So `version` stays fixed and the source hash rides in `description` instead:
# the manifest hash changes, the upsert matches on (name, version), and
# wasmBytes is updated in place. It also means the loaded build is legible in the
# Immich UI, which is worth the slightly noisy description.
{
  lib,
  stdenvNoCC,
  writeText,
  extism-js,
  binaryen,
  src,
  # Where the plugin should reach the verdict sidecar. Threaded in from the module
  # so the port lives in one place (hosts/rpi5/immich-clip.nix) rather than being
  # duplicated between the systemd unit and this default.
  sidecarUrl ? "http://127.0.0.1:8351/classify",
}:

let
  # Both sources, because the .d.ts is what declares the host-function import —
  # editing it alone changes the compiled wasm just as much as editing the JS.
  sourceHash = builtins.substring 0 8 (
    builtins.hashString "sha256" (
      builtins.readFile "${src}/plugin.js" + builtins.readFile "${src}/plugin.d.ts"
    )
  );

  # What goes IN the manifest — fixed, for the upsert reason above.
  manifestVersion = "0.1.0";

  # Nested schema properties REQUIRE title and description — in
  # dtos/json-schema.dto.js only the top level makes them optional, so omitting
  # them on a property fails zod validation and the plugin is skipped with a
  # `Invalid plugin manifest` warning rather than an error.
  manifest = writeText "manifest.json" (builtins.toJSON {
    name = "nic-clip";
    version = manifestVersion;
    title = "CLIP content filter";
    # The `build` suffix is what makes the manifest hash track the sources — see
    # the header. Do not remove it thinking it is cosmetic.
    description = "Filter workflow assets by what is in the picture, using the CLIP embeddings Immich already computes. (build ${sourceHash})";
    author = "nSimonFR-ai";
    wasmPath = "nic_clip.wasm";

    methods = [
      {
        name = "clipFilter";
        title = "Filter by content (CLIP)";
        description = "Add the asset to an album when its CLIP embedding is within the given cosine distance of a named profile, and halt the workflow otherwise.";
        types = [ "AssetV1" ];
        # Needed for httpRequest; without it the host hands the plugin a stub
        # that throws, and the method also loads into the worker pool instead.
        hostFunctions = true;
        allowedHosts = [ "127.0.0.1" ];
        uiHints = [ "Filter" ];
        schema = {
          type = "object";
          required = [ "profile" "threshold" ];
          properties = {
            profile = {
              type = "string";
              title = "Profile";
              description = "Name of a profile built with immich-clip-profile, e.g. food.";
              default = "food";
            };
            threshold = {
              type = "number";
              title = "Maximum cosine distance";
              description = "Lower is stricter. Calibrate with `immich-clip-backfill` before trusting a value.";
              default = 0.28;
              minimum = 0;
              maximum = 2;
              precision = 0.01;
            };
            waitSec = {
              type = "integer";
              title = "Seconds to wait for the embedding";
              description = "A freshly uploaded asset is not embedded yet. Past this, the asset is treated as no-match and needs immich-clip-backfill to catch up.";
              default = 60;
              minimum = 0;
              maximum = 120;
            };
            sidecar = {
              type = "string";
              title = "Sidecar URL";
              description = "Where immich-clip-filter listens. Its hostname must match allowedHosts in the plugin manifest.";
              default = sidecarUrl;
            };
            albumIds = {
              type = "string";
              array = true;
              title = "Albums to file matches into";
              description = "Done by this step rather than by chaining assetAddToAlbums, because Immich 3.1 runs workflow steps in an unordered query — a later action step is not reliably later. Leave empty to use this purely as a filter.";
            };
            assetTypes = {
              type = "string";
              array = true;
              title = "Asset types to consider";
              description = "Checked here for the same ordering reason. Videos carry no CLIP embedding, so letting one through would only burn the full wait before concluding nothing.";
              default = [ "IMAGE" ];
            };
          };
        };
      }
    ];
  });

in
stdenvNoCC.mkDerivation {
  pname = "immich-clip-plugin";
  # The store path keeps the build hash even though the manifest does not, so
  # `systemctl show immich-server -p Environment` says which build is deployed.
  version = "${manifestVersion}-${sourceHash}";
  inherit src;

  nativeBuildInputs = [
    extism-js
    binaryen # extism-js shells out to wasm-merge and wasm-opt
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    extism-js plugin.js -i plugin.d.ts -o nic_clip.wasm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm444 nic_clip.wasm  "$out/nic-clip/nic_clip.wasm"
    install -Dm444 ${manifest}    "$out/nic-clip/manifest.json"
    runHook postInstall
  '';

  meta = {
    description = "CLIP content-filter step for Immich Workflows";
    platforms = extism-js.meta.platforms;
    license = lib.licenses.mit;
  };
}
