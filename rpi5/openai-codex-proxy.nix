{ pkgs, lib, username, ... }:
let
  version = "1.0.2";

  # openai-oauth: OpenAI-compatible proxy using ChatGPT/Codex OAuth tokens.
  # https://github.com/EvanZhouDev/openai-oauth
  #
  # The dist bundles the entire 'ai' SDK into chunk-2AENSHRT.js; only yargs
  # is needed at runtime, so the lock file tracks yargs deps only.
  openai-oauth = pkgs.buildNpmPackage {
    pname = "openai-oauth";
    inherit version;

    src = pkgs.runCommand "openai-oauth-${version}-src" {
      tarball = pkgs.fetchurl {
        url = "https://registry.npmjs.org/openai-oauth/-/openai-oauth-${version}.tgz";
        hash = "sha512-5wSwwR76Mc+1ePjwEIzM34qk2Kaw8Ng2zgBCo5eLscOLfciC0N8Z1jCgTCcqeHtyRvywB1kcb0BsHxFHIVJ2Vg==";
      };
      packageLock = ./npm-locks/openai-oauth-package-lock.json;
    } ''
      mkdir -p $out
      tar xzf $tarball --strip-components=1 -C $out
      cp $packageLock $out/package-lock.json
      # Strip workspace:* devDeps only (ai and yargs are real runtime externals)
      ${pkgs.python3}/bin/python3 -c "
import json
with open('$out/package.json') as f: d = json.load(f)
d['devDependencies'] = {}
with open('$out/package.json', 'w') as f: json.dump(d, f, indent=2)
"
    '';

    npmDepsHash = "sha256-NAvnKyuOmhpHoaJzjkJmBaaXxHMACcmdayDyWIAuBBQ=";
    dontNpmBuild = true;

    meta.mainProgram = "openai-oauth";
  };

  port      = 4040;
  codexAuth = "/home/${username}/.codex/auth.json";
in
{
  # openai-oauth manages token refresh in-place. On a fresh system, log in once
  # with `openai-oauth login` (or the ChatGPT CLI) to populate ~/.codex/auth.json;
  # after that this service keeps the proxy running.
  systemd.services.openai-codex-proxy = {
    description = "OpenAI-compatible proxy via openai-codex OAuth (openai-oauth)";
    after       = [ "network.target" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      Type         = "simple";
      User         = username;
      ExecStart    = "${openai-oauth}/bin/openai-oauth --host 127.0.0.1 --port ${toString port} --oauth-file ${codexAuth}";
      Restart      = "on-failure";
      RestartSec   = "5s";
    };
    environment.CODEX_OPENAI_SERVER_LOG_REQUESTS = "1";
  };
}
