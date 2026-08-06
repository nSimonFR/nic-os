# claabs/epicgames-freegames-node — auto-claims the Epic Games Store weekly
# free games. `node dist/src/index.js` performs exactly ONE redeem pass and
# exits; the upstream Docker entrypoint's internal cron is deliberately unused.
#
# Service module (timer, state dir, config.json, captcha portal, Telegram):
# rpi5/epicgames-freegames.nix.
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  nodejs_22,
}:

# Pinned to master HEAD (2026-06-21): the tagged v5.1.0 release is from 2024;
# master carries ~2 years of Epic-API fixes since. Bump rev + both hashes to update.
buildNpmPackage {
  pname = "epicgames-freegames-node";
  version = "5.1.0-unstable-2026-06-21";
  src = fetchFromGitHub {
    owner = "claabs";
    repo = "epicgames-freegames-node";
    rev = "53fde0c27477338296ef3657658f5c63f1e5c380";
    hash = "sha256-G/S0bLVm1WUDdRbfcUVsfDQ/bCy1OkYW4Q8eV7ET6yY=";
  };
  npmDepsHash = "sha256-Y3ORxC+STTK3YNlPRIDH/CP4LVQimVaS59MPYepZv6w=";

  # Puppeteer must NOT download its bundled Chromium during `npm ci`; we point
  # it at the system chromium via PUPPETEER_EXECUTABLE_PATH at runtime instead.
  PUPPETEER_SKIP_DOWNLOAD = "true";
  PUPPETEER_SKIP_CHROMIUM_DOWNLOAD = "true";

  # `npm run build` = rimraf dist && tsc → dist/src/index.js (ESM).
  # Skip the default global-install phase; we install manually like ha-linky.
  dontNpmInstall = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/{bin,lib/epicgames-freegames}
    # node_modules must sit next to dist/ for ESM relative-path resolution.
    cp -r dist node_modules package.json $out/lib/epicgames-freegames/
    makeWrapper ${lib.getExe nodejs_22} $out/bin/epicgames-freegames \
      --add-flags "--enable-source-maps" \
      --add-flags "$out/lib/epicgames-freegames/dist/src/index.js"
    runHook postInstall
  '';

  meta = {
    description = "Auto-redeem Epic Games Store weekly free games";
    homepage = "https://github.com/claabs/epicgames-freegames-node";
    license = lib.licenses.mit;
    mainProgram = "epicgames-freegames";
  };
}
