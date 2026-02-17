{ ... }:
{
  services.cloudflare-dyndns = {
    enable = true;
    apiTokenFile = "/etc/secrets/cloudflare-dyndns-token";
    domains = [ "rpi5.nsimon.fr" ];
    proxied = false;
    ipv4 = true;
    ipv6 = false;
    frequency = "*:0/5";
    deleteMissing = false;
  };
}
