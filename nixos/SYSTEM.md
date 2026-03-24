# NIC-OS Project Notes - BeAsT

## Hardware
- Mouse: Logitech G502 (ratbagctl device name: `thundering-gerbil`)
- Keyboard: Catex Tech 72M RGB
- Monitors: LG 38GN950 ultrawide (primary) + Acer GN246HL (vertical)
- VKB Gladiator EVO R joystick

## Piper / Libratbag
- **G502 key binding gotcha**: Never use `ratbagctl action set key KEY_X` for button mappings — the `key` action type preserves HID modifier bytes from the firmware, causing phantom Ctrl/Alt. Always use **macro** actions instead: `ratbagctl ... action set macro +KEY_X -KEY_X`
- G502 has 3 profiles (0, 1, 2). Custom keybindings are on profile 2.
- Autoprofile switcher: `nixos/piper-autoprofile.nix` (switches profiles based on Hyprland window class)

## Environment
- NixOS with Hyprland
- Hyprland kb_options: `ctrl:nocaps`
- See `nixos/dotfiles/hypr/hyprland.conf` for keybindings and window rules
