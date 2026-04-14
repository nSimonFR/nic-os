{ config, lib, pkgs, ... }:
let
  cfg = config.services.llm-interceptor;

  llmInterceptorPkg = pkgs.python3Packages.buildPythonApplication rec {
    pname   = "llm-interceptor";
    version = "2.8.0";

    src = pkgs.fetchPypi {
      inherit pname version;
      sha256 = "sha256-Y3+q7028RvfRnmiZ74mJm3bF1biyhwLLfeYoXkikdAQ=";
    };

    pyproject = true;

    nativeBuildInputs = with pkgs.python3Packages; [
      setuptools
    ];

    propagatedBuildInputs = with pkgs.python3Packages; [
      mitmproxy
      click
      rich
      pydantic
      pyyaml
      fastapi
      uvicorn
      python-multipart
      watchdog
    ];

    # No test suite in the PyPI sdist; skip checks to avoid network access
    doCheck = false;
  };

  lliToml = pkgs.writeText "lli.toml" ''
    [proxy]
    host = "0.0.0.0"
    port = ${toString cfg.port}

    [filter]
    # Anthropic, OpenAI-compat providers included by default

    [storage]
    output_dir = "${cfg.dataDir}/sessions"

    [web]
    host = "127.0.0.1"
    port = ${toString cfg.webUiPort}
  '';
in
{
  options.services.llm-interceptor = {
    enable = lib.mkEnableOption "llm-interceptor forward HTTPS proxy (lli)";

    port = lib.mkOption {
      type        = lib.types.port;
      default     = 9090;
      description = "Proxy port (clients set HTTPS_PROXY=http://rpi5:<port>)";
    };

    webUiPort = lib.mkOption {
      type        = lib.types.port;
      default     = 8000;
      description = "Local port for the llm-interceptor built-in web UI";
    };

    dataDir = lib.mkOption {
      type        = lib.types.str;
      default     = "/var/lib/llm-interceptor";
      description = "Directory for captured sessions and config";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.llm-interceptor  = { isSystemUser = true; group = "llm-interceptor"; };
    users.groups.llm-interceptor = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir}          0750 llm-interceptor llm-interceptor - -"
      "d ${cfg.dataDir}/sessions 0750 llm-interceptor llm-interceptor - -"
    ];

    systemd.services.llm-interceptor = {
      description = "llm-interceptor forward HTTPS proxy + web UI (lli)";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];

      # Place lli.toml in the data dir so lli picks it up from its WorkingDirectory
      preStart = ''
        install -m 0640 ${lliToml} ${cfg.dataDir}/lli.toml
      '';

      serviceConfig = {
        # lli watch starts both the proxy daemon and the web UI.
        # StandardInput=null prevents it from blocking on missing TTY.
        ExecStart      = "${llmInterceptorPkg}/bin/lli watch";
        WorkingDirectory = cfg.dataDir;
        User           = "llm-interceptor";
        Group          = "llm-interceptor";
        Restart        = "on-failure";
        RestartSec     = "5";
        ReadWritePaths = [ cfg.dataDir ];
        StandardInput  = "null";
        LimitNOFILE    = 65536;
      };
    };

    # Open proxy port on tailscale0 so LAN/Tailnet clients can set HTTPS_PROXY
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
  };
}
