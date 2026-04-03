{ ... }:
{
  services.for-sure = {
    enable            = true;
    port              = 8340;
    apiKeyFile        = "/run/agenix/for-sure-api-key";
    swile.accountName = "Swile";
  };
}
