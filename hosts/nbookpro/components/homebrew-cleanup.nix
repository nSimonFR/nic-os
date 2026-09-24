{ config, lib, pkgs, ... }:
let
  cfg = config.homebrew;
  # Same content as nix-darwin's Brewfile, so the same store path.
  brewfile = pkgs.writeText "Brewfile" cfg.brewfile;
in
{
  # Replaces onActivation.cleanup = "zap" until nix-darwin 25.11 stops passing the
  # `brew bundle --cleanup` flag Homebrew 7 removed.
  system.activationScripts.homebrew.text = lib.mkAfter ''
    if [ -f "${cfg.brewPrefix}/brew" ]; then
      PATH="${cfg.brewPrefix}:$PATH" \
      sudo --preserve-env=PATH --user=${lib.escapeShellArg cfg.user} --set-home \
        env HOMEBREW_NO_AUTO_UPDATE=1 \
        brew bundle cleanup --file='${brewfile}' --force --zap
    fi
  '';
}
