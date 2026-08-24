# The wrapped `dsh` binary, shared by the two surfaces that need it: the
# home-manager module beside this file (interactive `dsh --profile headless`)
# and hosts/rpi5/dsh.nix's `dsh web` unit. One derivation, so the service and
# the CLI can never drift apart, and the unit's ExecStart stays a store path
# that nixos-rebuild actually tracks.
{ pkgs, lib, inputs }:
let
  upstream = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.dsh;

  # Tools the agent's own bash/fs tools reach for. `--suffix`, not `--prefix`:
  # interactively the user's PATH must still win (a `git` from a dev shell,
  # say), but under the systemd unit the process PATH is nearly empty and the
  # agent would otherwise have no shell utilities at all.
  agentTools = [
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.curl
    pkgs.findutils
    pkgs.gawk
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.ripgrep
  ];
in
pkgs.symlinkJoin {
  name = "dsh-wrapped";
  paths = [ upstream ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/dsh \
      --set-default APERTURE_API_KEY "tlg-ignored" \
      --set DSH_TELEMETRY_DISABLED "1" \
      --suffix PATH : "${lib.makeBinPath agentTools}"
  '';

  # symlinkJoin drops passthru, and hosts/rpi5/dsh.nix wants `lib.getExe`.
  meta.mainProgram = "dsh";
}
