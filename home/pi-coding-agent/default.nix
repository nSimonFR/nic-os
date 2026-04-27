{
  config,
  pkgs,
  inputs,
  telegramChatId,
  ...
}:
let
  upstream = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;

  # Wrap pi so the tlg-ignored dummy keys are scoped to the pi binary,
  # not exported into every shell. --set-default so a real key wins.
  pi = pkgs.symlinkJoin {
    name = "pi-coding-agent-wrapped";
    paths = [ upstream ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/pi \
        --set-default OPENAI_API_KEY "tlg-ignored" \
        --set-default ANTHROPIC_API_KEY "tlg-ignored"
    '';
  };

  notifyScript = (import ../lib/telegram-notify.nix { inherit pkgs telegramChatId; }) {
    name = "pi";
    header = "🤖 *Pi Coding Agent*";
    stateDir = "/tmp/pi-notify-state";
    tokenPath = config.age.secrets.telegram-bot-token.path;
  };
in
{
  home.packages = [ pi ];

  # Anthropic baseUrl override is Aperture-routed; the
  # `anthropic-beta: oauth-2025-04-20` header tells Anthropic to honour the
  # OAuth Bearer that tiny-llm-gate injects.
  home.file.".pi/agent/models.json".text = builtins.toJSON {
    providers.anthropic = {
      baseUrl = "https://ai.gate-mintaka.ts.net";
      headers."anthropic-beta" = "oauth-2025-04-20";
    };
  };

  # Without these, pi falls back to provider="google" and refuses to start.
  home.file.".pi/agent/settings.json".text = builtins.toJSON {
    defaultProvider = "aperture";
    defaultModel = "gpt-5.5";
  };

  home.sessionVariables = {
    PI_TELEGRAM_CHAT_ID = builtins.toString telegramChatId;
    PI_TELEGRAM_NOTIFY_SCRIPT = "${notifyScript}";
  };

  home.file.".pi/agent/extensions/telegram-notify".source =
    ./extensions/telegram-notify;
  home.file.".pi/agent/extensions/aperture-provider".source =
    ./extensions/aperture-provider;

  # NOTE: ~/.pi/agent/auth.json is intentionally NOT Nix-managed — pi
  # writes/refreshes it on OAuth rotation; a read-only store symlink
  # would break that.
}
