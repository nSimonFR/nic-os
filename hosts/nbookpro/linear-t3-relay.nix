# linear-t3-relay on the Mac: one agent per Linear workspace, driving the
# desktop app's T3 Code server (127.0.0.1:3773).
#
# Each instance's environment (Linear app secrets, BASE_URL, project,
# allowlist…) is one agenix file. The relay mints and renews its own T3 bearer
# with `t3 auth pairing create`, so no T3 token is stored outside its state.
#
# Public HTTPS is rpi5's 443 path-mux (hosts/rpi5/network/front-proxy.nix):
#   https://rpi5.gate-mintaka.ts.net/linear-t3/<name>/ → <this Mac>:<port>/
# which reaches these ports over the personal tailnet. BASE_URL in each env
# file carries that prefix.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  ports = {
    nsimon = 8787;
    work = 8788;
  };
  relayWithSonnetDefault = pkgs.writeShellApplication {
    name = "linear-t3-relay";
    text = ''
      # process.loadEnvFile preserves inherited environment values.
      export T3CODE_MODEL="claudeAgent/claude-sonnet-5-5"
      exec ${lib.getExe inputs.linear-t3-relay.packages.${pkgs.system}.default} "$@"
    '';
  };
in
{
  imports = [ inputs.linear-t3-relay.homeManagerModules.default ];

  age.secrets = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "linear-t3-relay-${name}" {
      file = ../../shared/linear-t3-relay-${name}.env.age;
    }
  ) ports;

  services.linear-t3-relay = {
    enable = true;
    package = relayWithSonnetDefault;
    instances = lib.mapAttrs (name: port: {
      inherit port;
      environmentFile = config.age.secrets."linear-t3-relay-${name}".path;
      renewCommand = "${lib.getExe pkgs.t3code} auth pairing create --json --ttl 5m --label linear-t3-relay-${name} --scope orchestration:read --scope orchestration:operate";
    }) ports;
  };
}
