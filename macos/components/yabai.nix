{ pkgs, ... }:
{
  enable = true;
  package = (pkgs.yabai.overrideAttrs (o: rec {
    version = "7.1.2";
    src = builtins.fetchTarball {
      url = "https://github.com/koekeishiya/yabai/releases/download/v${version}/yabai-v${version}.tar.gz";
      sha256 = "sha256:01csjp2nd57ai92v5qrwp910nsyzxwr42c7ikjcj9rxvn94smjhr";
    };
  }));
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
  extraConfig = ''
    yabai -m config --space 3 layout bsp
    yabai -m config --space 0 layout float

    yabai -m rule --add app='System Preferences' manage=off
    yabai -m rule --add label="Finder" app="^Finder$" title="(Co(py|nnect)|Move|Info|Pref)" manage=off
    yabai -m rule --add label="Firefox" app="^Firefox" title="^Opening" manage=off
    yabai -m rule --add label="Safari" app="^Safari$" title="^(General|(Tab|Password|Website|Extension)s|AutoFill|Se(arch|curity)|Privacy|Advance)$" manage=off
    yabai -m rule --add label="System Preferences" app="^System Preferences$" manage=off
    yabai -m rule --add label="Activity Monitor" app="^Activity Monitor$" manage=off
    yabai -m rule --add label="Calculator" app="^Calculator$" manage=off
    yabai -m rule --add label="Dictionary" app="^Dictionary$" manage=off
    yabai -m rule --add label="The Unarchiver" app="^The Unarchiver$" manage=off
    yabai -m rule --add label="Archive Utility" app="^Archive Utility$" manage=off
    yabai -m rule --add label="VirtualBox" app="^VirtualBox$" manage=off
    yabai -m rule --add label="Unclutter" app="^Unclutter$" manage=off
    yabai -m rule --add label="iStat" app=".*iStat.*" manage=off
    yabai -m rule --add label="Gramps" app="^Gramps$" manage=off
    yabai -m rule --add label="Arc" app="^Arc$" title="^$" mouse_follows_focus=off
    # yabai -m rule --add label="IINA" app="^IINA$" manage=off
  '';
}
