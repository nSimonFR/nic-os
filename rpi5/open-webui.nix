{ pkgs, lib, apertureUrl, tinyLlmGateUrl, ... }:
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
      # Chat completions via Aperture (observability) → tiny-llm-gate → providers.
      # Embeddings and STT stay direct — Aperture doesn't support /v1/embeddings.
      OPENAI_API_BASE_URL = "${apertureUrl}/v1";
      OPENAI_API_KEY = "ollama";
      ENABLE_OLLAMA_API = "false";
      # Web search via Tavily (API key injected at runtime from agenix)
      ENABLE_RAG_WEB_SEARCH = "True";
      RAG_WEB_SEARCH_ENGINE = "tavily";
      RAG_WEB_SEARCH_RESULT_COUNT = "5";
      # LLM generates optimized search queries from conversation context
      ENABLE_SEARCH_QUERY = "True";
      # Offload embeddings to LiteLLM → beast (saves ~500 MiB RAM)
      RAG_EMBEDDING_ENGINE = "openai";
      RAG_EMBEDDING_MODEL = "text-embedding-3-small";
      RAG_OPENAI_API_BASE_URL = "${tinyLlmGateUrl}/v1";  # direct — Aperture doesn't proxy /v1/embeddings
      RAG_OPENAI_API_KEY = "ollama";
      RAG_RERANKING_MODEL = "";
      # Disable local Whisper STT (saves ~300 MiB RAM)
      AUDIO_STT_ENGINE = "openai";
      AUDIO_STT_OPENAI_API_BASE_URL = "${tinyLlmGateUrl}/v1";  # direct — Aperture doesn't proxy STT
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
       # NLTK needs a resolvable HOME for its download directory
       export HOME=/var/lib/open-webui
       # Inject Tavily API key from dedicated agenix secret
       if [ -f /run/agenix/tavily-api-key ]; then
         export TAVILY_API_KEY=$(cat /run/agenix/tavily-api-key)
       fi
       exec ${lib.getExe cfg.package} serve --host "${cfg.host}" --port ${toString cfg.port}
     ''}");

  # RPi5: no user namespace support
  systemd.services.open-webui.serviceConfig.PrivateUsers = lib.mkForce false;
  # Tight memory cap for 4 GiB RPi5
  systemd.services.open-webui.serviceConfig.MemoryMax = "384M";
  # Start after tiny-llm-gate (embeddings/STT still go direct)
  systemd.services.open-webui.after = [ "tiny-llm-gate.service" ];
  systemd.services.open-webui.wants = [ "tiny-llm-gate.service" ];
}
