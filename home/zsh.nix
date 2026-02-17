{ pkgs, ... }:
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autocd = true;
    autosuggestion.enable = true;

    history = {
      ignoreDups = true;
      save = 1000000;
      size = 1000000;
    };
      
    zplug = {
      enable = true;
      plugins = [
        { name = "zsh-users/zsh-syntax-highlighting"; }
        { name = "spaceship-prompt/spaceship-prompt"; }
      ];
    };

    plugins = [
      # Will load the whole folder and source nsimon.plugin.zsh:
      { name = "nsimon"; src = ./dotfiles/zsh; }
    ];

    # Ensure home-manager packages are in PATH (needed when integrated with nix-darwin)
    initExtra = ''
      export PATH="$HOME/.local/state/nix/profiles/home-manager/home-path/bin:$PATH"
      
      # Tailscale exit node quick toggles
      alias vpn-on='tailscale up --exit-node=rpi5 && echo "✅ Exit node enabled (via RPi5)"'
      alias vpn-off='tailscale up --exit-node= && echo "❌ Exit node disabled (direct internet)"'
      alias vpn-status='tailscale status | grep -E "(rpi5|exit node)" || echo "Exit node: disabled"'
    '';
  };
}
