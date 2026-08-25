{ config, pkgs, lib, ... }:
# Aperture inference shim — lets one session have Aperture capture AND Remote
# Control, which are otherwise mutually exclusive: Remote Control refuses to run
# unless ANTHROPIC_BASE_URL is api.anthropic.com, while Aperture only records
# traffic that physically flows through it (no ingest API — /api/logs is a 501
# stub).
#
# Resolved below the URL layer: a local mitmproxy that Claude Code reaches via
# HTTPS_PROXY and trusts via NODE_EXTRA_CA_CERTS, which re-targets /v1/messages
# at Aperture and passes the control plane through to the real API. The guard
# sees api.anthropic.com; Aperture captures the inference.
#
# NODE_EXTRA_CA_CERTS scopes the proxy CA to Claude Code only — no /etc/hosts
# entry, no :443 bind, no root, no system trust store change. Every other client
# on the machine is unaffected.
#
# This module only runs the proxy. The client side (the three env vars, plus the
# port probe that degrades to plain Aperture when the proxy is down) lives in the
# `claude`/`cc`/`cr` shell functions in home/dotfiles/zsh/aliases.zsh — so only
# interactive sessions depend on it, and the rpi5's headless services, the desktop
# app and cron keep the wrapper's plain Aperture default.
let
  # 18888, deliberately NOT 8888: that port is a busy default (Jupyter, and the
  # Trusk bastion tunnels in home/dotfiles/zsh/trusk.zsh forward to it), and a
  # permanently-held 8888 made `ssh -L8888` fail with "Address already in use"
  # while silently swallowing every other tool's proxied traffic — the shim
  # allow-lists api.anthropic.com, so anything else got a TLS handshake timeout.
  # Keep it on a port nothing else wants.
  port = 18888;
  stateDir = "${config.home.homeDirectory}/.claude-aperture-shim";

  # mitmdump generates the CA into confdir on first run; the shell functions probe
  # for it (~/.claude-aperture-shim/mitmproxy-ca-cert.pem) before using the proxy.
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

in
{
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
