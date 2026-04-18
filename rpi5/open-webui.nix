{ pkgs, lib, ... }:
let
  # Torch 2.9.1 on aarch64 has a corrupt torchgen/__init__.py (all null bytes),
  # causing "source code string cannot contain null bytes" on import.
  # Fix: create a writable overlay with the corrected file, prepend to PYTHONPATH.
  torchgenFix = pkgs.runCommand "torchgen-fix" { } ''
    mkdir -p $out/torchgen
    echo "# patched: original was null bytes" > $out/torchgen/__init__.py
  '';
in
{
  services.open-webui = {
    enable = true;
    port = 8181;
    host = "127.0.0.1";
    environment = {
      # All models via LiteLLM (beast + codex proxy routed through one gateway)
      OPENAI_API_BASE_URL = "http://127.0.0.1:4001/v1";
      OPENAI_API_KEY = "ollama";
      ENABLE_OLLAMA_API = "false";
      # Reset DB config on next start (remove after first boot)
      RESET_CONFIG_ON_START = "true";
      # Offload embeddings to LiteLLM → beast (saves ~500 MiB RAM)
      RAG_EMBEDDING_ENGINE = "openai";
      RAG_EMBEDDING_MODEL = "text-embedding-3-small";
      RAG_OPENAI_API_BASE_URL = "http://127.0.0.1:4001/v1";
      RAG_OPENAI_API_KEY = "ollama";
      RAG_RERANKING_MODEL = "";
      # Disable local Whisper STT (saves ~300 MiB RAM)
      AUDIO_STT_ENGINE = "openai";
      AUDIO_STT_OPENAI_API_BASE_URL = "http://127.0.0.1:4001/v1";
      AUDIO_STT_OPENAI_API_KEY = "ollama";
      # Auth & telemetry
      WEBUI_AUTH = "true";
      SCARF_NO_ANALYTICS = "True";
      DO_NOT_TRACK = "True";
      ANONYMIZED_TELEMETRY = "False";
    };
  };

  # Fix corrupt torchgen/__init__.py on aarch64: prepend patched module to PYTHONPATH
  # Must use lib.mkBefore so it runs before the NixOS module's ExecStart sets PYTHONPATH
  systemd.services.open-webui.serviceConfig.ExecStart = lib.mkForce
    (let cfg = { port = 8181; host = "127.0.0.1"; package = pkgs.open-webui; }; in
     "${pkgs.writeShellScript "open-webui-wrapper" ''
       export PYTHONPATH="${torchgenFix}:''${PYTHONPATH:-}"
       exec ${lib.getExe cfg.package} serve --host "${cfg.host}" --port ${toString cfg.port}
     ''}");

  # RPi5: no user namespace support
  systemd.services.open-webui.serviceConfig.PrivateUsers = lib.mkForce false;
  # Tight memory cap for 4 GiB RPi5
  systemd.services.open-webui.serviceConfig.MemoryMax = "384M";
  # Start after LiteLLM
  systemd.services.open-webui.after = [ "litellm-gateway.service" ];
  systemd.services.open-webui.wants = [ "litellm-gateway.service" ];
}
