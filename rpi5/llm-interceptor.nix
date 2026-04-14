{ config, lib, pkgs, ... }:
let
  cfg = config.services.llm-interceptor;

  # Intercepts LLM API responses (Anthropic, OpenAI-compat) and forwards usage
  # traces to Langfuse Cloud for a unified token/cost/tool dashboard.
  #
  # Mode: forward proxy (clients set HTTPS_PROXY). No iptables needed.
  # mitmproxy buffers the full SSE response before calling response(), giving
  # us clean access to all SSE events including message_delta (output tokens).
  llmInterceptorAddon = pkgs.writeText "llm-interceptor.py" ''
    import base64, json, os, threading, uuid
    from datetime import datetime, timezone
    from urllib.request import Request, urlopen
    from urllib.error import URLError
    from mitmproxy import http

    LANGFUSE_HOST     = os.environ.get("LANGFUSE_HOST", "https://cloud.langfuse.com")
    LANGFUSE_PUB_KEY  = os.environ.get("LANGFUSE_PUBLIC_KEY", "")
    LANGFUSE_SEC_KEY  = os.environ.get("LANGFUSE_SECRET_KEY", "")
    BATCH_INTERVAL    = int(os.environ.get("LANGFUSE_BATCH_INTERVAL", "10"))
    BATCH_MAX_SIZE    = int(os.environ.get("LANGFUSE_BATCH_MAX_SIZE", "20"))
    TARGET_HOSTS      = set(os.environ.get("LLM_TARGET_HOSTS", "api.anthropic.com").split(","))
    # OpenAI-compatible hosts (Groq, Together, Ollama, etc.)
    OPENAI_COMPAT_HOSTS = set(os.environ.get("LLM_OPENAI_COMPAT_HOSTS", "").split(",")) - {""}

    _AUTH_HEADER = "Basic " + base64.b64encode(
        f"{LANGFUSE_PUB_KEY}:{LANGFUSE_SEC_KEY}".encode()
    ).decode()


    class LLMInterceptor:
        def __init__(self):
            self._batch       = []
            self._lock        = threading.Lock()
            self._total_ok    = 0
            self._total_err   = 0
            self._schedule_flush()

        # ── batch flush ──────────────────────────────────────────────────────

        def _schedule_flush(self):
            t = threading.Timer(BATCH_INTERVAL, self._flush_and_reschedule)
            t.daemon = True
            t.start()

        def _flush_and_reschedule(self):
            self._flush()
            self._schedule_flush()

        def _flush(self):
            with self._lock:
                if not self._batch:
                    return
                batch, self._batch = self._batch, []

            body = json.dumps({"batch": batch, "metadata": {}}).encode()
            req  = Request(
                f"{LANGFUSE_HOST}/api/public/ingestion",
                data=body,
                headers={
                    "Content-Type":  "application/json",
                    "Authorization": _AUTH_HEADER,
                },
                method="POST",
            )
            try:
                with urlopen(req, timeout=10) as resp:
                    self._total_ok += len(batch)
                    print(f"[llm-interceptor] flushed {len(batch)} events → {resp.status} "
                          f"(total ok={self._total_ok})")
            except (URLError, OSError) as e:
                self._total_err += 1
                print(f"[llm-interceptor] flush failed: {e} (err={self._total_err})")
                # Re-queue, but cap to avoid unbounded growth on persistent failure
                with self._lock:
                    self._batch = batch[:100] + self._batch

        # ── mitmproxy hook ────────────────────────────────────────────────────

        def response(self, flow: http.HTTPFlow):
            host = flow.request.pretty_host
            if host not in TARGET_HOSTS and host not in OPENAI_COMPAT_HOSTS:
                return
            if not flow.response or not flow.response.content:
                return
            try:
                events = self._build_events(flow, host)
                if events:
                    with self._lock:
                        self._batch.extend(events)
                        if len(self._batch) >= BATCH_MAX_SIZE:
                            threading.Thread(target=self._flush, daemon=True).start()
            except Exception as e:
                print(f"[llm-interceptor] parse error for {host}: {e}")

        # ── event building ────────────────────────────────────────────────────

        def _build_events(self, flow: http.HTTPFlow, host: str):
            now          = datetime.now(timezone.utc).isoformat()
            trace_id     = str(uuid.uuid4())
            generation_id = str(uuid.uuid4())
            path         = flow.request.path
            status       = flow.response.status_code
            content_type = flow.response.headers.get("content-type", "")

            # Skip non-LLM paths (auth, ping, etc.)
            if "/v1/messages" not in path and "/v1/chat/completions" not in path:
                return None

            req_body = {}
            try:
                req_body = json.loads(flow.request.get_text())
            except Exception:
                pass

            model = req_body.get("model", "unknown")

            start_ts = flow.request.timestamp_start
            end_ts   = flow.response.timestamp_end
            latency_ms = round((end_ts - start_ts) * 1000) if (end_ts and start_ts) else None

            def ts(epoch):
                if epoch is None:
                    return now
                return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat()

            # Parse response body
            if host in OPENAI_COMPAT_HOSTS or "/v1/chat/completions" in path:
                usage, tool_names, stop_reason = self._parse_openai(
                    flow.response.get_text(), "text/event-stream" in content_type
                )
            else:
                # Anthropic
                if "text/event-stream" in content_type:
                    usage, tool_names, stop_reason = self._parse_anthropic_sse(
                        flow.response.get_text()
                    )
                else:
                    usage, tool_names, stop_reason = self._parse_anthropic_json(
                        flow.response.get_text()
                    )

            trace_event = {
                "id":        str(uuid.uuid4()),
                "type":      "trace-create",
                "timestamp": now,
                "body": {
                    "id":   trace_id,
                    "name": f"{host}{path}",
                    "metadata": {
                        "host":        host,
                        "path":        path,
                        "http_status": status,
                    },
                },
            }

            gen_body = {
                "id":        generation_id,
                "traceId":   trace_id,
                "name":      model,
                "model":     model,
                "startTime": ts(start_ts),
                "endTime":   ts(end_ts),
                "metadata": {
                    "stop_reason": stop_reason,
                    "tool_names":  tool_names,
                    "latency_ms":  latency_ms,
                },
            }

            if usage:
                gen_body["usage"] = {
                    "input":  usage.get("input_tokens", 0),
                    "output": usage.get("output_tokens", 0),
                }
                gen_body["metadata"]["cache_creation_input_tokens"] = usage.get(
                    "cache_creation_input_tokens", 0
                )
                gen_body["metadata"]["cache_read_input_tokens"] = usage.get(
                    "cache_read_input_tokens", 0
                )

            gen_event = {
                "id":        str(uuid.uuid4()),
                "type":      "generation-create",
                "timestamp": now,
                "body":      gen_body,
            }

            return [trace_event, gen_event]

        # ── Anthropic SSE parser ──────────────────────────────────────────────
        #
        # SSE event flow:
        #   message_start   → message.usage.{input_tokens, cache_creation_input_tokens,
        #                                     cache_read_input_tokens}
        #   content_block_start (type=tool_use) → content_block.name
        #   message_delta   → usage.output_tokens, delta.stop_reason
        #   message_stop

        def _parse_anthropic_sse(self, text: str):
            usage        = {}
            tool_names   = []
            stop_reason  = None
            cur_event    = None
            cur_data     = []

            for line in text.split("\n"):
                if line.startswith("event: "):
                    cur_event = line[7:].strip()
                    cur_data  = []
                elif line.startswith("data: "):
                    cur_data.append(line[6:])
                elif line == "" and cur_event and cur_data:
                    try:
                        data = json.loads("".join(cur_data))
                    except json.JSONDecodeError:
                        cur_event = None
                        continue

                    if cur_event == "message_start":
                        u = data.get("message", {}).get("usage", {})
                        usage["input_tokens"]                 = u.get("input_tokens", 0)
                        usage["cache_creation_input_tokens"]  = u.get("cache_creation_input_tokens", 0)
                        usage["cache_read_input_tokens"]      = u.get("cache_read_input_tokens", 0)

                    elif cur_event == "content_block_start":
                        cb = data.get("content_block", {})
                        if cb.get("type") == "tool_use":
                            tool_names.append(cb.get("name", "unknown"))

                    elif cur_event == "message_delta":
                        usage["output_tokens"] = data.get("usage", {}).get("output_tokens", 0)
                        stop_reason = data.get("delta", {}).get("stop_reason")

                    cur_event = None
                    cur_data  = []

            return usage, tool_names, stop_reason

        def _parse_anthropic_json(self, text: str):
            try:
                body = json.loads(text)
            except Exception:
                return {}, [], None
            usage      = body.get("usage", {})
            stop_reason = body.get("stop_reason")
            tool_names  = [
                b.get("name", "unknown")
                for b in body.get("content", [])
                if b.get("type") == "tool_use"
            ]
            return usage, tool_names, stop_reason

        # ── OpenAI-compat parser (Groq, Together, Ollama, etc.) ───────────────
        #
        # Streaming: each chunk is "data: {...}\n\n"; last data chunk has usage.
        # Non-streaming: single JSON with usage at top level.

        def _parse_openai(self, text: str, streaming: bool):
            usage       = {}
            tool_names  = []
            stop_reason = None

            if streaming:
                for line in text.split("\n"):
                    if not line.startswith("data: "):
                        continue
                    raw = line[6:].strip()
                    if raw == "[DONE]":
                        continue
                    try:
                        data = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    # usage appears on the last chunk
                    if data.get("usage"):
                        u = data["usage"]
                        usage = {
                            "input_tokens":  u.get("prompt_tokens", 0),
                            "output_tokens": u.get("completion_tokens", 0),
                        }
                    for choice in data.get("choices", []):
                        if choice.get("finish_reason"):
                            stop_reason = choice["finish_reason"]
                        delta = choice.get("delta", {})
                        for tc in delta.get("tool_calls", []):
                            fn = tc.get("function", {}).get("name")
                            if fn:
                                tool_names.append(fn)
            else:
                try:
                    body = json.loads(text)
                    u = body.get("usage", {})
                    usage = {
                        "input_tokens":  u.get("prompt_tokens", 0),
                        "output_tokens": u.get("completion_tokens", 0),
                    }
                    for choice in body.get("choices", []):
                        if not stop_reason and choice.get("finish_reason"):
                            stop_reason = choice["finish_reason"]
                        for tc in choice.get("message", {}).get("tool_calls", []):
                            fn = tc.get("function", {}).get("name")
                            if fn:
                                tool_names.append(fn)
                except Exception:
                    pass

            return usage, tool_names, stop_reason


    addons = [LLMInterceptor()]
  '';
in
{
  options.services.llm-interceptor = {
    enable = lib.mkEnableOption "LLM traffic interceptor (mitmproxy forward proxy → Langfuse Cloud)";

    port = lib.mkOption {
      type        = lib.types.port;
      default     = 8890;
      description = "Port for the mitmproxy forward proxy (clients set HTTPS_PROXY=http://rpi5:<port>)";
    };

    langfuseHost = lib.mkOption {
      type        = lib.types.str;
      default     = "https://cloud.langfuse.com";
      description = "Langfuse API base URL";
    };

    langfuseKeysFile = lib.mkOption {
      type        = lib.types.str;
      default     = "/run/agenix/langfuse-keys";
      description = "Env file with LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY (sourced by systemd)";
    };

    targetHosts = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [ "api.anthropic.com" ];
      description = "Anthropic-protocol API hostnames to intercept";
    };

    openaiCompatHosts = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [];
      description = "OpenAI-compatible API hostnames to intercept (Groq, Together, Ollama, etc.)";
      example     = [ "api.groq.com" "api.together.xyz" ];
    };

    batchInterval = lib.mkOption {
      type        = lib.types.int;
      default     = 10;
      description = "Seconds between Langfuse batch flushes";
    };

    batchMaxSize = lib.mkOption {
      type        = lib.types.int;
      default     = 20;
      description = "Max traces per batch before a forced flush";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.llm-interceptor  = { isSystemUser = true; group = "llm-interceptor"; };
    users.groups.llm-interceptor = {};

    systemd.tmpfiles.rules = [
      "d /var/lib/llm-interceptor 0750 llm-interceptor llm-interceptor - -"
    ];

    systemd.services.llm-interceptor = {
      description = "LLM traffic interceptor (mitmproxy forward proxy → Langfuse Cloud)";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.mitmproxy}/bin/mitmdump"
          "--mode regular"
          "-p ${toString cfg.port}"
          "--set confdir=/var/lib/llm-interceptor/mitmproxy"
          "--set block_global=false"
          "-s ${llmInterceptorAddon}"
        ];
        User           = "llm-interceptor";
        Group          = "llm-interceptor";
        Restart        = "on-failure";
        RestartSec     = "5";
        ReadWritePaths = [ "/var/lib/llm-interceptor" ];
        LimitNOFILE    = 65536;
        EnvironmentFile = cfg.langfuseKeysFile;
      };

      environment = {
        LANGFUSE_HOST           = cfg.langfuseHost;
        LANGFUSE_BATCH_INTERVAL = toString cfg.batchInterval;
        LANGFUSE_BATCH_MAX_SIZE = toString cfg.batchMaxSize;
        LLM_TARGET_HOSTS        = lib.concatStringsSep "," cfg.targetHosts;
        LLM_OPENAI_COMPAT_HOSTS = lib.concatStringsSep "," cfg.openaiCompatHosts;
      };
    };

    # Allow tailnet clients to reach the forward proxy
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
  };
}
