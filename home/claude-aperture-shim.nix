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
    "-s" "${./claude-aperture-shim/aperture_shim.py}"
  ];

  claudeGated = pkgs.writeShellScriptBin "claude-gated" ''
    set -eu
    if [ ! -f "${caCert}" ]; then
      echo "claude-gated: proxy CA missing at ${caCert}" >&2
      echo "The claude-aperture-shim service generates it on first start." >&2
      ${lib.optionalString pkgs.stdenv.isDarwin
        ''echo "Try: launchctl kickstart -k gui/$(id -u)/org.nix-community.home.claude-aperture-shim" >&2''}
      ${lib.optionalString pkgs.stdenv.isLinux
        ''echo "Try: systemctl --user restart claude-aperture-shim" >&2''}
      exit 1
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
