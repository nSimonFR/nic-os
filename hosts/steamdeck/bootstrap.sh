#!/usr/bin/env bash
# Steam Deck (stock SteamOS) → tailnet + key-only SSH, so rpi5 and nBookPro can drive it.
# Run as `deck` in Desktop Mode → Konsole; safe to re-run (after a SteamOS update, say):
#   curl -fsSL https://raw.githubusercontent.com/nSimonFR/nic-os/main/hosts/steamdeck/bootstrap.sh | bash
set -euo pipefail

# nic-os ref for the Home Manager config (a branch, to try one before merging).
NIC_OS_REF=${NIC_OS_REF:-main}
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
[ -z "$(tail -c1 ~/.ssh/authorized_keys)" ] || echo >>~/.ssh/authorized_keys
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
printf '%s\n' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/10-nic-os.conf \
  /etc/systemd/system/nic-ac-keepawake.service /etc/udev/rules.d/90-nic-ac-keepawake.rules |
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

# tailscaled was just restarted: wait for it before reading its state.
for _ in $(seq 20); do sudo /opt/tailscale/tailscale set --operator=deck 2>/dev/null && break; sleep 1; done
if ! /opt/tailscale/tailscale status >/dev/null 2>&1; then
  echo "Log in with the QR code or the URL below:"
  sudo /opt/tailscale/tailscale up --qr --operator=deck --hostname=steamdeck
fi
/opt/tailscale/tailscale set --auto-update

# 4. No sleep while on AC, so SSH stays reachable (the power button included).
sudo tee /etc/systemd/system/nic-ac-keepawake.service >/dev/null <<'EOF'
[Unit]
Description=Block sleep while on AC power (keeps SSH reachable)
ConditionPathExists=/sys/class/power_supply/ACAD/online

[Service]
ExecCondition=/usr/bin/grep -qx 1 /sys/class/power_supply/ACAD/online
ExecStart=/usr/bin/systemd-inhibit --what=sleep --who=nic-os --why="On AC: keep SSH reachable" --mode=block /usr/bin/sleep infinity

[Install]
WantedBy=multi-user.target
EOF
sudo tee /etc/udev/rules.d/90-nic-ac-keepawake.rules >/dev/null <<'EOF'
SUBSYSTEM=="power_supply", KERNEL=="ACAD", ATTR{online}=="1", RUN+="/usr/bin/systemctl --no-block start nic-ac-keepawake.service"
SUBSYSTEM=="power_supply", KERNEL=="ACAD", ATTR{online}=="0", RUN+="/usr/bin/systemctl --no-block stop nic-ac-keepawake.service"
EOF
sudo systemctl daemon-reload
sudo udevadm control --reload
sudo systemctl enable --now nic-ac-keepawake.service

# 5. Nix (Determinate's installer keeps /nix in /home, so it survives SteamOS updates),
#    then Home Manager from nic-os.
# Upstream Nix: Determinate Nix writes /usr/local/bin, read-only on SteamOS.
if [ ! -e /nix/var/nix/profiles/default/bin/nix ]; then
  [ ! -e /nix/receipt.json ] || sudo /nix/nix-installer uninstall --no-confirm
  curl -sSfL https://install.determinate.systems/nix |
    sh -s -- install steam-deck --prefer-upstream-nix --no-confirm
fi
# shellcheck disable=SC1091
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
nix run github:nix-community/home-manager/release-26.05 -- switch -b hm-backup \
  --flake "github:nSimonFR/nic-os/$NIC_OS_REF#deck@steamdeck"
echo
echo "Done: $(/opt/tailscale/tailscale ip -4) — reach it as 'ssh steamdeck'."
