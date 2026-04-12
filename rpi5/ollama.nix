{ config, lib, pkgs, unstablePkgs, ... }:

{
  services.ollama = {
    enable = true;
    package = unstablePkgs.ollama;
    # CPU-only on RPi5 (no GPU)
    acceleration = false;
    # Limit memory: Gemma 4 E2B Q4_K_M needs ~2.3 GB
    environmentVariables = {
      OLLAMA_MAX_LOADED_MODELS = "1";
      OLLAMA_NUM_PARALLEL = "1";
      GOMAXPROCS = "2";
    };
  };
}
