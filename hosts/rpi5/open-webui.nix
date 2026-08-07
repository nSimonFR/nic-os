{ pkgs, lib, apertureUrl, tinyLlmGateUrl, ... }:
let
  # externalPort: Tailscale Serve + ROOT URL + socket-activate proxy.
  # backendPort: where open-webui actually binds (behind the proxy).
  externalPort = 8181;
  backendPort  = 8182;

  # Track open-webui via PyPI rather than nixpkgs.open-webui. The
  # release-25.11 / unstable open-webui derivations both force a fresh
  # Svelte/Vite frontend build on every nixpkgs bump, and vite peaks at
  # ~1.3 GiB on the RPi5 — earlyoom kills it. The PyPI wheel ships the
  # frontend pre-built, sidestepping the OOM entirely.
  #
  # Bump procedure: change `version`, commit, restart open-webui.service.
  # The ExecStartPre sees the version-stamp mismatch and rebuilds the venv.
  version = "0.9.5";
  python = pkgs.python313;
in
{
  systemd.services.open-webui = {
    description = "Open WebUI (PyPI venv)";
    after = [ "network-online.target" "tiny-llm-gate.service" ];
    wants = [ "network-online.target" "tiny-llm-gate.service" ];
    # No wantedBy — socket-activated via services.socketActivate.openwebui.

    environment = {
      # Chat completions via Aperture (observability) → tiny-llm-gate → providers.
      # Embeddings and STT stay direct — Aperture doesn't support /v1/embeddings.
      OPENAI_API_BASE_URL = "${apertureUrl}/v1";
      OPENAI_API_KEY = "ollama";
      ENABLE_OLLAMA_API = "false";

      ENABLE_RAG_WEB_SEARCH = "True";
      RAG_WEB_SEARCH_ENGINE = "tavily";
      RAG_WEB_SEARCH_RESULT_COUNT = "5";
      ENABLE_SEARCH_QUERY = "True";

      RAG_EMBEDDING_ENGINE = "openai";
      RAG_EMBEDDING_MODEL = "text-embedding-3-small";
      RAG_OPENAI_API_BASE_URL = "${tinyLlmGateUrl}/v1";
      RAG_OPENAI_API_KEY = "ollama";
      RAG_RERANKING_MODEL = "";

      AUDIO_STT_ENGINE = "openai";
      AUDIO_STT_OPENAI_API_BASE_URL = "${tinyLlmGateUrl}/v1";
      AUDIO_STT_OPENAI_API_KEY = "ollama";

      WEBUI_AUTH = "true";
      SCARF_NO_ANALYTICS = "True";
      DO_NOT_TRACK = "True";
      ANONYMIZED_TELEMETRY = "False";

      # StateDirectory is /var/lib/open-webui (DynamicUser exposes it there).
      # NLTK + open-webui both look at HOME for their data caches.
      HOME = "/var/lib/open-webui";
      DATA_DIR = "/var/lib/open-webui/data";
    };

    serviceConfig = {
      Type = "simple";
      DynamicUser = true;
      StateDirectory = "open-webui";
      PrivateUsers = lib.mkForce false; # RPi5: no user namespace support
      MemoryMax = "384M";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "10min"; # first-boot venv install can take a while

      ExecStartPre = "${pkgs.writeShellScript "open-webui-venv-setup" ''
        set -euo pipefail
        VENV=/var/lib/open-webui/venv
        STAMP="$VENV/.version"
        WANT="${version}"

        if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
          echo "open-webui venv already at $WANT"
          exit 0
        fi

        echo "open-webui venv: installing $WANT"
        rm -rf "$VENV"
        ${pkgs.uv}/bin/uv venv --python ${python}/bin/python3 "$VENV"
        # uv pip install runs faster than the venv's own pip and resolves
        # the open-webui closure (langchain, chromadb, sentence-transformers)
        # in seconds instead of minutes.
        ${pkgs.uv}/bin/uv pip install \
          --python "$VENV/bin/python3" \
          "open-webui==$WANT"
        echo "$WANT" > "$STAMP"
      ''}";

      ExecStart = "${pkgs.writeShellScript "open-webui-run" ''
        set -euo pipefail
        # Inject Tavily API key from dedicated agenix secret
        if [ -f /run/agenix/tavily-api-key ]; then
          export TAVILY_API_KEY="$(cat /run/agenix/tavily-api-key)"
        fi
        exec /var/lib/open-webui/venv/bin/open-webui serve \
          --host 127.0.0.1 \
          --port ${toString backendPort}
      ''}";
    };
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ────────
  # OWUI is Python/uvicorn; cold-start ~5-10s loading torch + the
  # FastAPI tree. readyProbe required (Type=simple, listen() lands
  # several seconds after fork). An open browser tab maintains a
  # WebSocket which the proxy treats as an active connection — so
  # OWUI stays awake while you're actively using it, and only idles
  # out once you close the tab and 600s pass with no requests.
  services.socketActivate.openwebui = {
    enable    = true;
    realUnit  = "open-webui.service";
    listen    = [ "127.0.0.1:${toString externalPort}" ];
    backend   = "127.0.0.1:${toString backendPort}";
    idleSec   = 600;
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/health";
      expectStatus = 200;
      timeoutSec   = 120;
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  # DISABLED 2026-06-15 (venv crash-loop, exit 126). This whole module is not
  # imported by configuration.nix; re-enable it there and this registration comes
  # back with it — including the dashboard tile, which used to be carried in
  # services-registry.nix as a commented-out block and is preserved here instead.
  # `order = 60` is the gap left for it between Papra (50) and Karakeep (70).
  nic.services.open-webui = {
    backup     = [ "none" ];
    backupNote = "chat history in /var/lib/private/open-webui was never backed up; re-verify before re-enabling";
    heavyUnits = [ "open-webui.service" ];

    public = {
      order   = 60;
      port    = externalPort;
      backend = "http://127.0.0.1:${toString externalPort}";
      tile = {
        name        = "Open WebUI";
        icon        = "open-webui.svg";
        category    = "Apps";
        description = "LLM chat interface";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/openwebui";
          refreshInterval = 3600000;
          mappings = [
            { field = "models"; label = "Models"; format = "number"; }
            { field = "chats"; label = "Chats"; format = "number"; }
            { field = "messages"; label = "Messages"; format = "number"; }
          ];
        };
      };
    };
  };
}
