{ config, pkgs, tailnetFqdn, ... }:
let
  secretsPath = config.age.secrets.mcp-secrets.path;

  # Wrapper scripts: read secrets from agenix at runtime, then exec the MCP server
  githubMcp = pkgs.writeShellScript "github-mcp" ''
    [ -f "${secretsPath}" ] && . "${secretsPath}"
    export GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_PAT"
    exec docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server
  '';

  miroMcp = pkgs.writeShellScript "miro-mcp" ''
    [ -f "${secretsPath}" ] && . "${secretsPath}"
    export MIRO_ACCESS_TOKEN="$MIRO_TOKEN"
    exec npx -y @k-jarzyna/mcp-miro
  '';

  # Trusk mutualised PG ("monodb") MCPs — crystaldba/postgres-mcp in docker.
  # Staging = CloudSQL trusk-common-325eac79 @ 10.106.0.3, main DB `trusk_staging`;
  # prod = CloudSQL trusk-production @ 10.206.0.21, main DB `trusk`. Both hold one
  # schema per service and are reachable directly over the corp VPN. Users:
  # mcp_readonly (pg_read_all_data + pg_monitor; staging one pre-existed for
  # ToolHive's dbhub) and mcp_readwrite (adds pg_write_all_data; created
  # 2026-09-03 via `gcloud sql users create`, self-granted the predefined roles —
  # CloudSQL API users are cloudsqlsuperuser members so no postgres pwd needed).
  # ro pairs the readonly role with --access-mode=restricted (read-only SQL,
  # statement timeouts); rw is unrestricted. Passwords live in mcp-secrets.age.
  postgresMcp = name: user: pwVar: hostDb: mode: pkgs.writeShellScript "postgres-mcp-${name}" ''
    [ -f "${secretsPath}" ] && . "${secretsPath}"
    export DATABASE_URI="postgresql://${user}:''${${pwVar}}@${hostDb}?sslmode=require"
    exec docker run -i --rm -e DATABASE_URI crystaldba/postgres-mcp --access-mode=${mode}
  '';
  postgresStagingRo = postgresMcp "staging-ro" "mcp_readonly"  "PG_MCP_STAGING_RO_PW" "10.106.0.3:5432/trusk_staging" "restricted";
  postgresStagingRw = postgresMcp "staging-rw" "mcp_readwrite" "PG_MCP_STAGING_RW_PW" "10.106.0.3:5432/trusk_staging" "unrestricted";
  postgresProdRo    = postgresMcp "prod-ro"    "mcp_readonly"  "PG_MCP_PROD_RO_PW"    "10.206.0.21:5432/trusk"        "restricted";
  postgresProdRw    = postgresMcp "prod-rw"    "mcp_readwrite" "PG_MCP_PROD_RW_PW"    "10.206.0.21:5432/trusk"        "unrestricted";

  # AFFiNE MCP — write-capable. tiny-llm-gate exposes an SSE bridge at
  # tailnet :7020 that proxies to affine-mcp.service (DAWNCR0W) on the rpi5.
  # See hosts/rpi5/affine-mcp.nix and hosts/rpi5/tiny-llm-gate.nix.
  #
  # `tailnetFqdn` is the rpi5's MagicDNS name and is passed to all three
  # home-manager configs (it was previously passed and never read here, with the
  # name spelled out as a literal instead). Note this stays the *public* tailnet
  # URL even on the rpi5 itself, where it means the box reaches its own MCP by
  # going out to its own name and back: the :7020 listener is a `tailscale serve`
  # mapping (nic.services.affine-mcp.public), so it is bound on the tailnet address
  # only and has no loopback equivalent at that port. Short-circuiting it means
  # pointing at tiny-llm-gate's backend route directly — a behaviour change worth
  # its own commit, not a side effect of this one.
  affineMcpUrl = "https://${tailnetFqdn}:7020/sse";

  # Shared MCP server definitions (no plaintext secrets)
  mcpServers = {
    # Public — no secrets
    Linear              = { type = "sse"; url = "https://mcp.linear.app/sse"; };
    # Metabase built-in MCP server. Streamable-HTTP at /api/mcp (the v0.61 docs'
    # /api/metabase-mcp path 404s on v0.61.2.10; /api/mcp is the live route and
    # returns a 401 OAuth challenge — `www-authenticate: Bearer realm="mcp"`).
    # Auth via Metabase's embedded OAuth server (browser handshake on first call,
    # token scoped to the connecting user's permissions) — no secret in config.
    # Replaces the cookie-based `metabase` skill. Enabled instance-side
    # (agent-api-enabled? / mcp-enabled? both true on metabase.trusk.com).
    metabase            = { type = "http"; url = "https://metabase.trusk.com/api/mcp"; };
    # ToolHive — unified MCP proxy (Tristan's 2026-07-17 announcement). Fronts
    # ~140 underlying tools behind just 2 meta-tools (find_tool / call_tool).
    # We cut over to it and DROPPED the individual tailnet gateways it fronts:
    # grafana, datadog, argocd, k8s, github (gitnexus), context7, firecrawl are
    # now all reached via ToolHive. Reachable over the work Tailscale tunnel
    # (resolves over utun, valid TLS via `tailscale serve`); OAuth route also
    # exists at staging-toolhive-tech.trusk.com/mcp.
    "toolhive-tech"     = { type = "http"; url = "https://ai-toolhive-tech.tail271d7a.ts.net/mcp"; };
    # Steampipe — query GCP as live SQL (only the turbot/gcp plugin is
    # installed): `SELECT … FROM gcp_compute_instance / gcp_kubernetes_cluster
    # / gcp_service_account …`, read-only, hits the real GCP API per query.
    # NOT fronted by ToolHive (no GCP; dbhub is real-DB only), so kept direct.
    "trusk-steampipe"   = { type = "sse";  url = "https://ai-steampipe-mcp.tail271d7a.ts.net/sse"; };

    # Private — secrets loaded at runtime via wrapper scripts
    GitHub  = { command = "${githubMcp}"; };
    Miro    = { command = "${miroMcp}"; };
    affine  = { type = "sse"; url = affineMcpUrl; };
    postgres_staging_ro = { command = "${postgresStagingRo}"; };
    postgres_staging_rw = { command = "${postgresStagingRw}"; };
    postgres_prod_ro    = { command = "${postgresProdRo}"; };
    postgres_prod_rw    = { command = "${postgresProdRw}"; };
  };

  # Pre-built JSON for Cursor (Nix-generated, no secrets in the file)
  cursorMcpBase = pkgs.writeText "cursor-mcp-base.json"
    (builtins.toJSON { inherit mcpServers; });
in
{
  # Claude Code: declarative MCP via home-manager plugin mechanism
  programs.claude-code.mcpServers = mcpServers;

  # Cursor: write ~/.cursor/mcp.json as a real file (Cursor can't follow symlinks)
  # Also sync the affine command entry into ~/.claude.json (user-level Claude Code config)
  home.activation.cursor-mcp = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.cursor"
    cat ${cursorMcpBase} > "$HOME/.cursor/mcp.json"

    # Keep ~/.claude.json affine entry pointing to shared SSE gateway
    CLAUDE_USER="$HOME/.claude.json"
    if [ -f "$CLAUDE_USER" ]; then
      ${pkgs.jq}/bin/jq \
        --arg url "${affineMcpUrl}" \
        'del(.mcpServers["affine_workspace_35d244cd-e6d5-4b3d-b1c2-fa50cab50621"])
         | .mcpServers.affine = {type:"sse", url:$url}' \
        "$CLAUDE_USER" > "$CLAUDE_USER.tmp" && mv "$CLAUDE_USER.tmp" "$CLAUDE_USER"
    fi
  '';
}
