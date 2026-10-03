{ config, lib, pkgs, ... }:
let
  cfg = config.services.sumeria-mitm;

  # Every hostname the Sumeria app has been observed calling. Matching on the
  # apex covers all of them at once — the app moved api.lydia-app.com ->
  # lc.lydia-app.com on 2026-09-08 and a host-specific match silently stopped
  # intercepting (traffic passed through undecrypted, tokens froze for 6 days).
  apiDomain = "lydia-app.com";
  # Regex for mitmproxy --allow-hosts, which matches against "host:port".
  apiDomainRe = "lydia-app\\.com";

  # Intercepts requests to lydia-app.com and extracts the three static session
  # headers (auth_token / public_token / access-token) that Sumeria uses instead of OAuth.
  # Tokens are written atomically so the consumer picks them up without a restart.
  # NOTE: these headers are undocumented and were discovered by MITM. Update if auth changes.
  # Only some endpoints carry all three (e.g. /service/accounts/<id>/moneyalerts);
  # most requests have none, so a miss here is normal, not a failure.
  tokenExtractor = pkgs.writeText "sumeria-token-extractor.py" ''
    import json, os
    from mitmproxy import http

    TOKEN_FILE = os.environ["SUMERIA_TOKEN_FILE"]

    class SumeriaTokenExtractor:
        def request(self, flow: http.HTTPFlow):
            # In transparent mode flow.request.host is the IP; use pretty_host (SNI-based)
            host = flow.request.pretty_host
            if "${apiDomain}" not in host:
                return
            h = flow.request.headers
            print(f"[sumeria-mitm] intercepted {host}{flow.request.path} auth={bool(h.get('auth_token'))}")
            if h.get("auth_token") and h.get("public_token") and h.get("access-token"):
                tokens = {
                    "auth_token":   h["auth_token"],
                    "public_token": h["public_token"],
                    "access_token": h["access-token"],
                }
                # Only write if tokens actually changed — avoids spamming the
                # PathModified watcher (and downstream Sure sync) on every request
                try:
                    with open(TOKEN_FILE, "r") as f:
                        existing = json.load(f)
                    if existing == tokens:
                        print(f"[sumeria-mitm] tokens unchanged, skipping write")
                        return
                except (FileNotFoundError, json.JSONDecodeError):
                    pass  # first run or corrupt file — write anyway
                tmp = TOKEN_FILE + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(tokens, f, indent=2)
                os.rename(tmp, TOKEN_FILE)
                print(f"[sumeria-mitm] NEW tokens written to {TOKEN_FILE}")

    addons = [SumeriaTokenExtractor()]
  '';
in
{
  options.services.sumeria-mitm = {
    enable = lib.mkEnableOption "Sumeria token extractor (a tailnet-mitm target)";

    tokenFile = lib.mkOption {
      type        = lib.types.str;
      default     = "/var/lib/sumeria-mitm/tokens.json";
      description = "Path where captured Sumeria tokens are written";
    };

    tokenFileGroup = lib.mkOption {
      type        = lib.types.str;
      default     = "sumeria-mitm";
      description = "Group that gets read access to the token file (set to consumer's group)";
    };
  };

  # Prerequisite: the mitmproxy CA installed + trusted on the iPhone.
  config = lib.mkIf cfg.enable {
    services.tailnet-mitm.stateGroup = cfg.tokenFileGroup;
    services.tailnet-mitm.targets.sumeria = {
      # lc.lydia-app.com round-robins across several VIPs; all are advertised.
      hosts       = [ "lc.${apiDomain}" ];
      allowHosts  = apiDomainRe;
      addon       = "${tokenExtractor}";
      environment.SUMERIA_TOKEN_FILE = cfg.tokenFile;
    };
  };
}
