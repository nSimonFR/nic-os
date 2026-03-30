{ pkgs, lib, ... }:
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
      packageLock = ./openai-oauth/package-lock.json;
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

  port            = 4040;
  openclawAuth    = "/home/nsimon/.openclaw/agents/main/agent/auth-profiles.json";
  codexAuth       = "/home/nsimon/.codex/auth.json";
  profileKey      = "openai-codex:default";

  # Seed ~/.codex/auth.json from openclaw's auth-profiles.json on first run.
  # openai-oauth then takes over token refresh for its own file.
  seedScript = pkgs.writeText "seed-codex-auth.py" ''
    import json, os, sys

    OPENCLAW = "${openclawAuth}"
    CODEX    = "${codexAuth}"
    KEY      = "${profileKey}"

    # Skip if already seeded
    try:
        with open(CODEX) as f:
            if json.load(f).get("tokens", {}).get("access_token"):
                sys.exit(0)
    except Exception:
        pass

    try:
        with open(OPENCLAW) as f:
            p = json.load(f)["profiles"][KEY]
    except Exception as e:
        print(f"cannot read openclaw auth: {e}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(CODEX), exist_ok=True)
    with open(CODEX, "w") as f:
        json.dump({"tokens": {
            "access_token":  p["access"],
            "refresh_token": p["refresh"],
            "account_id":    p.get("accountId", ""),
        }}, f, indent=2)
    os.chmod(CODEX, 0o600)
    print(f"seeded {CODEX} from openclaw auth")
  '';
in
{
  systemd.services.openai-codex-proxy = {
    description = "OpenAI-compatible proxy via openai-codex OAuth (openai-oauth)";
    after       = [ "network.target" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      Type         = "simple";
      User         = "nsimon"; # needs read access to ~/.openclaw/
      ExecStartPre = "${pkgs.python3}/bin/python3 ${seedScript}";
      ExecStart    = "${openai-oauth}/bin/openai-oauth --host 127.0.0.1 --port ${toString port} --oauth-file ${codexAuth}";
      Restart      = "on-failure";
      RestartSec   = "5s";
    };
  };
}
