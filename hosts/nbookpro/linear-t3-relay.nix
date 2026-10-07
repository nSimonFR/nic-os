# linear-t3-relay on the Mac: one launchd agent per Linear workspace, each
# driving the desktop app's T3 Code server (127.0.0.1:3773).
#
# Each instance's whole environment (Linear app secrets, BASE_URL, project,
# allowlist…) is one agenix file; the relay mints and renews its own T3 bearer
# with `t3 auth pairing create`, so no T3 token is stored anywhere but its state.
#
# Public HTTPS is Tailscale Funnel, set once by hand (tailscaled persists it):
#   tailscale funnel --bg --https=443   http://127.0.0.1:8787   # nsimon
#   tailscale funnel --bg --https=10000 http://127.0.0.1:8788   # work
# Logs: ~/Library/Logs/linear-t3-relay-<name>.log. State (Linear install, T3
# bearer): ~/.local/state/linear-t3-relay/<name>/state.json — keep it.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  relay = pkgs.callPackage ../../pkgs/agents/linear-t3-relay.nix {
    linear-t3-relay-src = inputs.linear-t3-relay-src;
  };

  instances = {
    nsimon.port = 8787;
    work.port = 8788;
  };

  stateDir = name: "${config.home.homeDirectory}/.local/state/linear-t3-relay/${name}";

  start =
    name: port:
    pkgs.writeShellApplication {
      name = "linear-t3-relay-${name}";
      runtimeInputs = [ pkgs.git ];
      text = ''
        ENV_FILE="${config.age.secrets."linear-t3-relay-${name}".path}"
        export ENV_FILE
        export HOST=127.0.0.1 PORT=${toString port}
        export STATE_PATH="${stateDir name}/state.json"
        export T3CODE_URL=http://127.0.0.1:3773
        export T3CODE_RENEW_COMMAND="${lib.getExe pkgs.t3code} auth pairing create --json --ttl 5m --label linear-t3-relay-${name} --scope orchestration:read --scope orchestration:operate"
        exec ${lib.getExe relay}
      '';
    };
in
{
  age.secrets = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "linear-t3-relay-${name}" {
      file = ../../shared/linear-t3-relay-${name}.env.age;
    }
  ) instances;

  # launchd opens the log before exec and creates no directory.
  home.activation.linearT3RelayState = lib.hm.dag.entryBefore [ "setupLaunchAgents" ] (
    lib.concatMapStrings (name: ''
      run install -d -m 700 "${stateDir name}"
    '') (lib.attrNames instances)
  );

  launchd.agents = lib.mapAttrs' (
    name: instance:
    lib.nameValuePair "linear-t3-relay-${name}" {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe (start name instance.port)) ];
        RunAtLoad = true;
        KeepAlive = true;
        # The agenix file appears only after its own agent decrypts it; retry until then.
        ThrottleInterval = 30;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/linear-t3-relay-${name}.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/linear-t3-relay-${name}.log";
      };
    }
  ) instances;
}
