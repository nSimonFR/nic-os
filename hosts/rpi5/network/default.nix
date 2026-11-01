# How services are reached: Tailscale Serve, the 443 Funnel mux, DNS, the homepage, tailnet-wide MITM.
{
  imports = [
    ./tailscale-serve.nix
    ./blocky.nix
    ./front-proxy.nix
    ./tailnet-mitm.nix
    ./homepage.nix
    ./sidestore-reflector.nix
  ];
}
