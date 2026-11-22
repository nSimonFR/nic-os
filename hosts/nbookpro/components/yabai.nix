{ pkgs, inputs, ... }:
let
  unstablePkgs = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
{
  enable = true;
  # macOS 27 changed Dock internals used by the scripting addition (#2822), and
  # upstream's payload still refuses macOS 27. AhsanFazal's fork (a small,
  # SA-focused diff; macOS 27.2 offsets and space moves) is the one cited as
  # working in that issue; the bassepeder fork pinned before is gone (404).
  # Back to the plain package once upstream's SA accepts macOS 27.
  # https://github.com/asmvik/yabai/issues/2822
  package = unstablePkgs.yabai.overrideAttrs {
    src = unstablePkgs.fetchFromGitHub {
      owner = "AhsanFazal";
      repo = "yabai";
      # renovate: datasource=git-refs depName=https://github.com/AhsanFazal/yabai branch=master
      rev = "ad8d5adfdc39c76399599ae79a264f2525f6ca5e";
      hash = "sha256-berfA3vYih1YuCCSBEvpocCn2EPj+ZpftPmsE65ILWo=";
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
