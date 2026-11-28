# steamdeck

Stock SteamOS: Valve ships the OS and its updates. nic-os puts it on the tailnet,
lets rpi5 and nBookPro in over key-only SSH, and manages the `deck` user's Home Manager.

Set up, once, on the Deck (Desktop Mode → Konsole):

```sh
curl -fsSL https://raw.githubusercontent.com/nSimonFR/nic-os/main/hosts/steamdeck/bootstrap.sh | bash
```

It asks for a `deck` password if none is set (sudo needs it), shows a Tailscale login
QR code, blocks sleep while plugged in, installs Nix and applies `home.nix`.
Then, in the Tailscale console, disable key expiry on `steamdeck`.

Re-run the same command if a SteamOS update drops Tailscale, sshd or Nix.

Later `home.nix` changes, from rpi5 or the Mac:

```sh
ssh steamdeck home-manager switch --flake github:nSimonFR/nic-os#deck@steamdeck
```

## Secrets

`beszel-agent.nix` decrypts `shared/beszel-agent-steamdeck.env.age` with the deck
user's `~/.ssh/id_ed25519`, the `steamdeck-deck` recipient in `shared/secrets.nix`.
bootstrap.sh creates that key if missing; on a new or reinstalled Deck, put its
`~/.ssh/id_ed25519.pub` in `steamdeck-deck` and re-encrypt (`agenix -r`), or the
agent fails to start.
