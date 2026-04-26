{
  pkgs,
  telegramChatId,
  ...
}:
let
  pi-coding-agent = pkgs.callPackage ./package.nix { };
in
{
  home.packages = [ pi-coding-agent ];

  # All pi traffic goes through Aperture (https://ai.gate-mintaka.ts.net),
  # which forwards to tiny-llm-gate (:4001) → codex-proxy (:4040) for ChatGPT
  # subscription models, or beast Ollama for local ones. The custom
  # `aperture` provider is registered by extensions/aperture-provider/.
  #
  # Anthropic provider override is also Aperture-routed (anthropic-beta
  # header required for OAuth acceptance; see rpi5/tiny-llm-gate.nix).
  home.file.".pi/agent/models.json".text = builtins.toJSON {
    providers.anthropic = {
      baseUrl = "https://ai.gate-mintaka.ts.net";
      headers."anthropic-beta" = "oauth-2025-04-20";
    };
  };

  # tiny-llm-gate / codex-proxy ignore the inbound auth (codex-proxy uses its
  # own OAuth, ollama doesn't need a key) so these dummy values are fine.
  home.sessionVariables = {
    ANTHROPIC_API_KEY = "tlg-ignored";
    OPENAI_API_KEY = "tlg-ignored";
    PI_TELEGRAM_BOT_TOKEN_FILE = "/run/agenix/telegram-bot-token";
    PI_TELEGRAM_CHAT_ID = builtins.toString telegramChatId;
  };

  # Vendored Anthropic-authored skills. Pi reads them from
  # ~/.pi/agent/skills/<name>/SKILL.md (recursive, per docs/skills.md).
  # See rpi5/pi-coding-agent/skills/SOURCES.md for upstream pins.
  home.file.".pi/agent/skills".source = ./skills;

  # Telegram notify extension — port of the Claude Code Notification hook.
  home.file.".pi/agent/extensions/telegram-notify".source =
    ./extensions/telegram-notify;

  # Aperture-provider extension — registers the `aperture` provider so all
  # pi traffic flows through the observability gateway. Aliases (`pi`,
  # `pi-beast`, `pi-local`) target this provider.
  home.file.".pi/agent/extensions/aperture-provider".source =
    ./extensions/aperture-provider;

  # NOTE: ~/.pi/agent/auth.json is intentionally NOT managed by Nix. Pi writes
  # and refreshes it itself; a Nix-managed copy would be a read-only symlink
  # into the store and break OAuth rotation.
}
