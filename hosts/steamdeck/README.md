# steamdeck

Stock SteamOS, not managed by Nix: Valve ships the OS and its updates. nic-os only
puts it on the tailnet and lets rpi5 and nBookPro in over key-only SSH.

Set up, once, on the Deck (Desktop Mode → Konsole):

```sh
curl -fsSL https://raw.githubusercontent.com/nSimonFR/nic-os/main/hosts/steamdeck/bootstrap.sh | bash
```

It asks for a `deck` password if none is set (sudo needs it), then shows a Tailscale
login QR code. Afterwards: `ssh steamdeck`. Re-run it if a SteamOS update drops
Tailscale or sshd.

Then, in the Tailscale console, disable key expiry on `steamdeck`.
