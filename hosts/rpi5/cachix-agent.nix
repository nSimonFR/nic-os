# Cachix Deploy agent — activates the system that .github/workflows/deploy-rpi5.yml
# built and pushed to nsimon-nicos. The Pi never evaluates the config itself:
# that eval peaks at ~2.1 GiB RSS and earlyoom SIGTERMs it (2026-10-01).
{ ... }:
{
  services.cachix-agent = {
    enable = true;
    credentialsFile = "/run/agenix/cachix-agent-token";
  };
}
