{
  inputs,
  pkgs,
  username,
  ...
}:
{
  imports = [
    ./picoclaw/picoclaw.nix
  ];

  home.packages = with pkgs; [
    nodejs_22
    pnpm
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

}
