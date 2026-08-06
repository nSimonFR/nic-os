{ pkgs, lib, config, host, ... }:
let
  wakatimeExt = pkgs.vscode-extensions.wakatime.vscode-wakatime;
  cursorPrefix =
    if pkgs.stdenv.isDarwin then "Library/Application Support" else ".config";
in
{
  # ── Vim ─────────────────────────────────────────────────────────────
  # Ungated: the only editor that makes sense over SSH, and the one the Pi
  # actually uses.
  programs.vim = {
    enable = true;
    plugins = [ pkgs.vimPlugins.vim-wakatime ];
    extraConfig = builtins.readFile ./dotfiles/editor/vim;
  };

  # ── VS Code ─────────────────────────────────────────────────────────
  # GUI editors are gated on `isGraphical`. The rpi5 is a headless 3.9 GB
  # server: it has no display to run any of these on, and VS Code alone is a
  # ~400 MB closure it has to build/fetch on every switch.
  programs.vscode = lib.mkIf host.isGraphical {
    enable = true;
    profiles.default.extensions = [ wakatimeExt ];
  };

  # ── Zed ─────────────────────────────────────────────────────────────
  xdg.configFile = lib.optionalAttrs host.isGraphical {
    "zed/settings.json".source = ./dotfiles/editor/zed-settings.json;
  };

  # ── Cursor ──────────────────────────────────────────────────────────
  # Cursor writes back to settings.json (UI prompts, telemetry opt-outs, etc.),
  # so symlink to the repo via mkOutOfStoreSymlink instead of a read-only store
  # path. Just `git commit` after Cursor updates them.
  home.file = lib.optionalAttrs host.isGraphical {
    "${cursorPrefix}/Cursor/User/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/editor/cursor-settings.json";
    "${cursorPrefix}/Cursor/User/keybindings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/editor/cursor-keybindings.json";
  };

  # Install the WakaTime extension on each HM switch. Cursor reuses the
  # VS Code extension API + Open VSX; the CLI is idempotent. The `command -v`
  # guard already made this a no-op on the Pi — the gate makes that intent
  # declarative instead of accidental.
  home.activation = lib.mkIf host.isGraphical {
    cursorWakatime = lib.hm.dag.entryAfter [ "installPackages" ] ''
      if command -v cursor >/dev/null 2>&1; then
        run cursor --install-extension WakaTime.vscode-wakatime --force >/dev/null 2>&1 || true
      fi
    '';
  };
}
