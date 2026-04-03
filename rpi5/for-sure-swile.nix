{ ... }:
{
  services.for-sure-swile = {
    enable      = true;
    port        = 8340;
    apiKeyFile  = "/run/agenix/for-sure-swile-api-key";
    accountName = "Swile";
  };
}
