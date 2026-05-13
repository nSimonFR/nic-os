{ pkgs, lib, config, ... }:
let
  wakatimeExt = pkgs.vscode-extensions.wakatime.vscode-wakatime;
in
{
  home.packages = [ pkgs.wakatime-cli ];

  # ~/.wakatime.cfg — written from agenix-managed encrypted INI.
  home.activation.wakatimeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -f "${config.age.secrets.wakatime-cfg.path}" ]; then
      run install -m 600 "${config.age.secrets.wakatime-cfg.path}" "$HOME/.wakatime.cfg"
    fi
  '';

  # ── VS Code: install + WakaTime extension ────────────────────────────
  programs.vscode = {
    enable = true;
    profiles.default.extensions = [ wakatimeExt ];
  };

  # ── Vim: migrate raw vimrc into programs.vim + WakaTime plugin ────────
  programs.vim = {
    enable = true;
    plugins = [ pkgs.vimPlugins.vim-wakatime ];
    extraConfig = builtins.readFile ./dotfiles/editor/vim;
  };

  # ── Cursor: install WakaTime extension on each HM switch ──────────────
  # Cursor reuses the VS Code extension API + Open VSX; the CLI is
  # idempotent ("already installed" exits 0).
  home.activation.cursorWakatime = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if command -v cursor >/dev/null 2>&1; then
      run cursor --install-extension WakaTime.vscode-wakatime --force >/dev/null 2>&1 || true
    fi
  '';
}
