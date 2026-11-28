# Beszel agent for the Deck, reporting to the rpi5 hub (hosts/rpi5/platform/monitoring.nix).
# WebSocket mode, like nBookPro: it dials the hub, so a sleeping Deck needs no inbound
# port. TOKEN matches the steamdeck system's fingerprint record. Runs as a user unit;
# linger (`loginctl enable-linger deck`) keeps it up without a session.
{
  config,
  pkgs,
  tailnetFqdn,
  ...
}:
let
  stateDir = "${config.xdg.stateHome}/beszel-agent";
  tokenFile = ../../shared/beszel-agent-steamdeck.env.age;

  run = pkgs.writeShellApplication {
    name = "beszel-agent-run";
    runtimeInputs = [ pkgs.age ];
    text = ''
      umask 077
      mkdir -p "${stateDir}"
      env=$(age -d -i "$HOME/.ssh/id_ed25519" ${tokenFile})
      set -a
      eval "$env"
      set +a
      export DATA_DIR="${stateDir}"
      export HUB_URL="https://${tailnetFqdn}:3000"
      # The hub's public key (GET /api/beszel/getkey): the agent only trusts its signature.
      export KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnrMibplBybzPfg/TmufH8HOXLDK36erbUh2XvSq6Ku"
      export FILESYSTEM=/dev/nvme0n1p8 # /home: games and /nix live here
      exec ${pkgs.beszel}/bin/beszel-agent
    '';
  };
in
{
  systemd.user.services.beszel-agent = {
    Unit.Description = "Beszel monitoring agent";
    Service = {
      ExecStart = "${run}/bin/beszel-agent-run";
      Restart = "always";
      RestartSec = 30; # retry pace while off the tailnet
    };
    Install.WantedBy = [ "default.target" ];
  };
}
