{ config, pkgs, lib, ... }:
# `claude-gated` — Aperture capture AND Remote Control in the same session.
#
# These are normally mutually exclusive: Remote Control refuses to run unless
# ANTHROPIC_BASE_URL is api.anthropic.com, while Aperture only records traffic
# that physically flows through it (no ingest API — /api/logs is a 501 stub).
#
# The shim resolves it below the URL layer: a local mitmproxy that Claude Code
# reaches via HTTPS_PROXY and trusts via NODE_EXTRA_CA_CERTS, which re-targets
# /v1/messages at Aperture and passes the control plane through to the real API.
# The guard sees api.anthropic.com; Aperture captures the inference.
#
# NODE_EXTRA_CA_CERTS scopes the proxy CA to Claude Code only — no /etc/hosts
# entry, no :443 bind, no root, no system trust store change. Every other client
# on the machine is unaffected.
#
# Opt-in: plain `claude` keeps the wrapper's ANTHROPIC_BASE_URL default (straight
# to Aperture, no Remote Control) and doesn't depend on the proxy being up.
let
  port = 8888;
  stateDir = "${config.home.homeDirectory}/.claude-aperture-shim";
  caCert = "${stateDir}/mitmproxy-ca-cert.pem";

  # mitmdump generates the CA into confdir on first run, so the service must
  # have started once before `claude-gated` can trust it.
  shimCmd = [
    "${pkgs.mitmproxy}/bin/mitmdump"
    "--set" "confdir=${stateDir}"
    "--listen-host" "127.0.0.1"
    "-p" (toString port)
    # Intercept api.anthropic.com ONLY; blind-tunnel every other host. Without
    # this, mitmproxy re-signs TLS for everything the session touches, and any
    # client that doesn't read NODE_EXTRA_CA_CERTS fails: `curl` in the Bash tool,
    # and Go/Python MCP servers (mtg-mcp → Scryfall) return 000 instead of 200.
    #
    # MUST be allow_hosts, not a negative-lookahead ignore_hosts: the pattern is
    # also tested against the resolved address form (`[2607:6bc0::10]:443`), which
    # `^(?!api\.anthropic\.com)` matches — so that spelling ignored EVERYTHING,
    # tunnelling inference straight to Anthropic and silently bypassing Aperture
    # while every functional check still passed.
    "--set" ''allow_hosts=api\.anthropic\.com''
    "-s" "${./claude-aperture-shim/aperture_shim.py}"
  ];

  claudeGated = pkgs.writeShellScriptBin "claude-gated" ''
    set -eu
    # This is the default path for interactive `claude` (see dotfiles/zsh/aliases.zsh),
    # so a dead shim must not take the CLI down with it. Pointing HTTPS_PROXY at a
    # port nothing is listening on makes Claude Code HANG rather than fail fast, so
    # degrade to the plain wrapper default (Aperture direct, no Remote Control)
    # instead — loud on stderr, still usable.
    if [ ! -f "${caCert}" ] || ! (timeout 1 bash -c ": < /dev/tcp/127.0.0.1/${toString port}") 2>/dev/null; then
      echo "claude-gated: shim unavailable on 127.0.0.1:${toString port} — falling back to" >&2
      echo "  Aperture direct, WITHOUT Remote Control. Restart it with:" >&2
      ${lib.optionalString pkgs.stdenv.isDarwin
        ''echo "  launchctl kickstart -k gui/$(id -u)/org.nix-community.home.claude-aperture-shim" >&2''}
      ${lib.optionalString pkgs.stdenv.isLinux
        ''echo "  systemctl --user restart claude-aperture-shim" >&2''}
      exec ${config.programs.claude-code.package}/bin/claude "$@"
    fi
    # api.anthropic.com satisfies the Remote Control guard; the proxy is what
    # actually puts the request through Aperture.
    export ANTHROPIC_BASE_URL="https://api.anthropic.com"
    export HTTPS_PROXY="http://127.0.0.1:${toString port}"
    export NODE_EXTRA_CA_CERTS="${caCert}"
    exec ${config.programs.claude-code.package}/bin/claude "$@"
  '';
in
{
  home.packages = [ claudeGated ];

  launchd.agents.claude-aperture-shim = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    config = {
      ProgramArguments = shimCmd;
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${stateDir}/shim.log";
      StandardErrorPath = "${stateDir}/shim.err";
    };
  };

  systemd.user.services.claude-aperture-shim = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Claude Code → Aperture inference shim (keeps Remote Control usable)";
    Service = {
      ExecStart = lib.escapeShellArgs shimCmd;
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
