{
  inputs,
  pkgs,
  username,
  ...
}:
{
  imports = [
    ./picoclaw/picoclaw.nix
    ./pi-coding-agent/pi-coding-agent.nix
  ];

  home.packages = with pkgs; [
    nodejs_22
    pnpm
    (callPackage ./gogcli.nix { gogcli-src = inputs.gogcli-src; })
    (callPackage ./goplaces.nix { goplaces-src = inputs.goplaces-src; })
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

}
