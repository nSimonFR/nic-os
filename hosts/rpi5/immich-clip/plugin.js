// nic-clip — a CLIP content filter step for Immich Workflows.
//
// Immich 3.1's core plugin can filter on filename, EXIF, type, date and
// location, but not on what is actually IN the picture. This adds that step, so
// a workflow can read:
//
//   AssetMetadataExtraction -> assetTypeFilter(IMAGE)
//                           -> nic-clip#clipFilter(profile=food)
//                           -> assetAddToAlbums(Food)
//
// It does NOT do the inference itself, and cannot: the `httpRequest` host
// function returns `body: await res.text()` (see
// services/workflow-execution.service.js), so no image bytes can come in and no
// multipart can go out. All this does is hand the asset id to the sidecar
// (nicos_scripts.immich.clip_filter) and act on its verdict.
//
// ⚠️ WHY THIS STEP ALSO DOES THE ALBUM ADD, instead of being a pure filter with
// `immich-plugin-core#assetAddToAlbums` chained after it:
//
//   Immich 3.1's `WorkflowRepository.getForWorkflowRun` selects workflow_step
//   WITHOUT `ORDER BY "order"`. Postgres is then free to return the steps in any
//   order, and it does — the same query returned
//   [typeFilter, addToAlbums, clipFilter] on one call and the declared order on
//   the next. When the add lands first, EVERY asset is filed regardless of the
//   verdict; observed, not theorised. So a filter step cannot reliably gate a
//   later action step on this version, and the only safe workflow is one step.
//
//   Hence: this step checks the asset type itself, asks for the verdict, and
//   files the asset via the `addAssetsToAlbums` host function. It still returns
//   workflow.continue, so chaining works again once upstream orders the query.
//
// Fail-closed on purpose: sidecar down, ML server down, embedding not ready, bad
// JSON — every one of those means "not food", so the asset simply stays out of
// the album. The alternative (fail-open) would file the whole camera roll.
// Anything that isn't a clean verdict gets logged; extism wires console.log to
// the Immich logger, so it surfaces as `Plugin:nic-clip@<version>`.

const { httpRequest, addAssetsToAlbums } = Host.getFunctions();

const DEFAULTS = {
  profile: "food",
  threshold: 0.28,
  waitSec: 60,
  sidecar: "http://127.0.0.1:8351/classify",
  assetTypes: ["IMAGE"],
};

function halt(reason) {
  console.log("no match: " + reason);
  Host.outputString(JSON.stringify({ workflow: { continue: false } }));
}

function clipFilter() {
  let payload;
  try {
    payload = JSON.parse(Host.inputString());
  } catch (e) {
    return halt("unparseable step payload: " + e);
  }

  const config = payload.config || {};
  const asset = (payload.data || {}).asset || {};
  if (!asset.id) {
    return halt("step payload carried no asset id");
  }

  // Done here rather than by chaining assetTypeFilter, for the ordering reason
  // above — and because a video has no CLIP embedding, so letting one through
  // would burn the full waitSec before concluding nothing.
  const types = config.assetTypes || DEFAULTS.assetTypes;
  if (asset.type && types.indexOf(asset.type) === -1) {
    return halt("asset type " + asset.type + " is not in " + JSON.stringify(types));
  }

  const body = JSON.stringify({
    assetId: asset.id,
    profile: config.profile || DEFAULTS.profile,
    threshold: config.threshold != null ? config.threshold : DEFAULTS.threshold,
    waitSec: config.waitSec != null ? config.waitSec : DEFAULTS.waitSec,
  });

  // The host wrapper expects {authToken, args} and applies `fetch(...args)`,
  // checking args[0]'s hostname against the manifest's allowedHosts first.
  const request = JSON.stringify({
    authToken: (payload.workflow || {}).authToken,
    args: [
      config.sidecar || DEFAULTS.sidecar,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: body,
      },
    ],
  });

  let result;
  try {
    const offset = httpRequest(Memory.fromString(request).offset);
    result = JSON.parse(Memory.find(offset).readString());
  } catch (e) {
    return halt("sidecar call threw: " + e);
  }

  if (!result.success) {
    return halt("host refused the call: " + (result.message || "unknown"));
  }
  const response = result.response || {};
  if (!response.ok) {
    return halt("sidecar returned HTTP " + response.status);
  }

  let verdict;
  try {
    verdict = JSON.parse(response.body);
  } catch (e) {
    return halt("sidecar body was not JSON: " + e);
  }

  if (verdict.match !== true) {
    return halt(verdict.reason || "distance " + verdict.distance + " over threshold");
  }

  const albumIds = config.albumIds || [];
  if (albumIds.length > 0) {
    const call = JSON.stringify({
      authToken: (payload.workflow || {}).authToken,
      args: [{ albumIds: albumIds, assetIds: [asset.id] }],
    });
    try {
      const off = addAssetsToAlbums(Memory.fromString(call).offset);
      const added = JSON.parse(Memory.find(off).readString());
      if (!added.success) {
        // Not fatal: DUPLICATE simply means it was already filed.
        console.log("album add returned " + (added.message || JSON.stringify(added.response)));
      }
    } catch (e) {
      console.log("album add threw: " + e);
    }
  }

  console.log("match: " + asset.id + " at distance " + verdict.distance);
  Host.outputString(JSON.stringify({ workflow: { continue: true } }));
}

module.exports = { clipFilter };
