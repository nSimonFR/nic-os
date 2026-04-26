{
  pkgs,
  inputs,
  telegramChatId,
  ...
}:
let
  upstream = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;

  # Wrap pi so the tlg-ignored dummy keys are scoped to the pi binary,
  # not exported into every shell on every host (where they'd 401 any
  # other tool reading OPENAI_API_KEY / ANTHROPIC_API_KEY). --set-default
  # so a real key in the user's env wins.
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
in
{
  # pi-coding-agent, packaged via numtide's llm-agents.nix flake (auto-bumped
  # daily from npm). The wrapper above scopes the dummy proxy creds.
  home.packages = [ pi ];

  # All pi traffic flows through Aperture → tiny-llm-gate (:4001) →
  # codex-proxy (:4040) or beast Ollama. Custom `aperture` provider is
  # registered by extensions/aperture-provider/.
  #
  # Anthropic baseUrl override is Aperture-routed too; the
  # `anthropic-beta: oauth-2025-04-20` header is what tells Anthropic to
  # honour the OAuth Bearer that tiny-llm-gate injects (see
  # rpi5/tiny-llm-gate.nix:135-150 and known_issue_aperture_oauth_models.md).
  home.file.".pi/agent/models.json".text = builtins.toJSON {
    providers.anthropic = {
      baseUrl = "https://ai.gate-mintaka.ts.net";
      headers."anthropic-beta" = "oauth-2025-04-20";
    };
  };

  # Default provider/model for bare `pi` (no alias). Without these, pi
  # falls back to provider="google" and refuses to start with no API key.
  home.file.".pi/agent/settings.json".text = builtins.toJSON {
    defaultProvider = "aperture";
    defaultModel = "gpt-5.5";
  };

  # Pi reads chat id from env; the extension resolves the bot-token path
  # itself (HM-agenix path → system-agenix path → optional override env).
  home.sessionVariables.PI_TELEGRAM_CHAT_ID = builtins.toString telegramChatId;

  home.file.".pi/agent/extensions/telegram-notify".source =
    ./extensions/telegram-notify;
  home.file.".pi/agent/extensions/aperture-provider".source =
    ./extensions/aperture-provider;

  # NOTE: ~/.pi/agent/auth.json is intentionally NOT Nix-managed — pi
  # writes/refreshes it on OAuth rotation; a read-only store symlink
  # would break that.
}
