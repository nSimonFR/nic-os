{ pkgs, inputs, ... }:
let
  unstablePkgs = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
{
  enable = true;
  # macOS 27 changed Dock internals used by the scripting addition (#2822).
  # 7.1.25 (the last release) predates it; upstream master carries the macOS 27
  # ("Golden Gate") fixes since 2026-11. The bassepeder fork pinned before is
  # gone (404). Back to the plain package once a release ships them.
  # https://github.com/asmvik/yabai/issues/2822
  package = unstablePkgs.yabai.overrideAttrs {
    src = unstablePkgs.fetchFromGitHub {
      owner = "asmvik";
      repo = "yabai";
      # renovate: datasource=git-refs depName=https://github.com/asmvik/yabai branch=master
      rev = "0b4818bdc4dfa641cad8cedcdfe26af3ddf334ac";
      hash = "sha256-RYX1WvvwSaBIiZTB6xmtftkor85a7nILqoQXWrvFmF8=";
    };
  };
  enableScriptingAddition = true;
  config = {
    layout = "stack";
    window_border = "on";
    window_border_width = 3;
    active_window_border_color = "0xff81a1c1";
    normal_window_border_color = "0xff3b4252";
    window_border_hidpi = "on";
    focus_follows_mouse = "autofocus";
    mouse_follows_focus = "on";
    #mouse_drop_action = "stack";
    #window_placement = "second_child";
    #window_opacity = "off";
    #window_topmost = "on";
    window_shadow = "float";
    #window_origin_display = "focused";
    #active_window_opacity = "1.0";
    #normal_window_opacity = "1.0";
    split_ratio = "0.50";
    #auto_balance = "on";
    mouse_modifier = "alt";
    mouse_action1 = "move";
    mouse_action2 = "resize";
    #top_padding = 10;
    #bottom_padding = 10;
    #left_padding = 10;
    #right_padding = 10;
    #window_gap = 10;
    #external_bar = "all:0:0";
  };
  extraConfig = builtins.readFile ../dotfiles/yabairc;
}
