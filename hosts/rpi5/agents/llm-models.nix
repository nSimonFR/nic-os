# The models offered in pickers: T3 Code's Codex harness (via the gate's
# /codex/models) and Hermes' Telegram /model. Ids are tiny-llm-gate models;
# order is picker order. Services that pin their own model don't need to be here.
{
  picker = [
    # ChatGPT plan (codex)
    "gpt-6-luna"
    "gpt-6.1-sol"
    "gpt-6.1-terra"
    "gpt-6"
    # Asale, paid in USDT
    "asale-gpt-6-luna"
    "asale-gpt-6.1-sol"
    "asale-gpt-6-astra"
    # Local: beast Ollama, then the Mac's oMLX
    "gemma4:26b"
    "qwen3.8:27b"
    "Qwen3.6-27B-4bit"
    "Qwen3.6-35B-A3B-4bit-DWQ"
  ];
}
