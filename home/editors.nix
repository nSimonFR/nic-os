{ pkgs, lib, ... }:
let
  wakatimeExt = pkgs.vscode-extensions.wakatime.vscode-wakatime;
  cursorPrefix =
    if pkgs.stdenv.isDarwin then "Library/Application Support" else ".config";
in
{
  # ── VS Code ─────────────────────────────────────────────────────────
  programs.vscode = {
    enable = true;
    profiles.default.extensions = [ wakatimeExt ];
  };

  # ── Vim ─────────────────────────────────────────────────────────────
  programs.vim = {
    enable = true;
    plugins = [ pkgs.vimPlugins.vim-wakatime ];
    extraConfig = builtins.readFile ./dotfiles/editor/vim;
  };

  # ── Zed ─────────────────────────────────────────────────────────────
  xdg.configFile."zed/settings.json".source = ./dotfiles/editor/zed-settings.json;

  # ── Cursor ──────────────────────────────────────────────────────────
  home.file."${cursorPrefix}/Cursor/User/settings.json".source =
    ./dotfiles/editor/cursor-settings.json;
  home.file."${cursorPrefix}/Cursor/User/keybindings.json".source =
    ./dotfiles/editor/cursor-keybindings.json;

  # Install the WakaTime extension on each HM switch. Cursor reuses the
  # VS Code extension API + Open VSX; the CLI is idempotent.
  home.activation.cursorWakatime = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if command -v cursor >/dev/null 2>&1; then
      run cursor --install-extension WakaTime.vscode-wakatime --force >/dev/null 2>&1 || true
    fi
  '';
}
