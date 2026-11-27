#!/usr/bin/env bash
# Steam Deck (stock SteamOS) → tailnet + key-only SSH, so rpi5 and nBookPro can drive it.
# Run as `deck` in Desktop Mode → Konsole; safe to re-run (after a SteamOS update, say):
#   curl -fsSL https://raw.githubusercontent.com/nSimonFR/nic-os/main/hosts/steamdeck/bootstrap.sh | bash
set -euo pipefail

# tailscale-dev/deck-tailscale, pinned: it runs as root.
DECK_TAILSCALE_REV=4691bb20d492ae9b2f5121c3eaf6e2dc1950e73f
KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ7wzLFXmWeZ52SWjvsfXSZr+LbvpZYt/EE/tzVZnFd nsimon"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIoO5ICofBCfox+M2Uz91qBRF794BwHhQJBL/9dSZahr nsimon@rpi5-agent"
)

[ "$(id -un)" = deck ] || {
  echo "run as the deck user" >&2
  exit 1
}

# 1. sudo needs a password; a new Deck has none.
if [ "$(passwd -S deck | awk '{print $2}')" != P ]; then
  echo "Choose a password for 'deck' (used by sudo):"
  passwd </dev/tty
fi

# 2. Key-only SSH.
install -d -m 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
for k in "${KEYS[@]}"; do
  grep -qF "${k% *}" ~/.ssh/authorized_keys || echo "$k" >>~/.ssh/authorized_keys
done

sudo install -d /etc/ssh/sshd_config.d /etc/atomic-update.conf.d
sudo tee /etc/ssh/sshd_config.d/10-nic-os.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config ||
  sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
# Keep these /etc files across SteamOS updates.
printf '%s\n' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/10-nic-os.conf |
  sudo tee /etc/atomic-update.conf.d/nic-os.conf >/dev/null
# A new Deck has no host keys until sshd first starts; `sshd -t` needs them.
sudo ssh-keygen -A
sudo sshd -t
sudo systemctl enable --now sshd
sudo systemctl reload sshd

# 3. Tailscale (binaries in /opt/tailscale, unit on boot, works in Game Mode).
src=$(mktemp -d)
git clone -q https://github.com/tailscale-dev/deck-tailscale.git "$src"
git -C "$src" checkout -q "$DECK_TAILSCALE_REV"
(cd "$src" && sudo bash tailscale.sh)
rm -rf "$src"

if ! /opt/tailscale/tailscale status >/dev/null 2>&1; then
  echo "Log in with the QR code or the URL below:"
  sudo /opt/tailscale/tailscale up --qr --operator=deck --hostname=steamdeck
fi
/opt/tailscale/tailscale set --auto-update
echo
echo "Done: $(/opt/tailscale/tailscale ip -4) — reach it as 'ssh steamdeck'."
