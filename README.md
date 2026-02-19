# Nic-OS - My nix configs w/ flake

This repository replaces my configuration / dotfiles repository.

This allows centralized and reproductable management of:

- My linux computer management with NixOS
- Dotfiles and custom configurations for programs
- **TODO:** management of MacOS settings too (With [nix-darwin](https://github.com/LnL7/nix-darwin))

All that, via a declarative and functional approach _("os-management-as-code")_ thanks to;

- [Nix package manager & NixOS](https://nixos.org/)
- [home-manager](https://github.com/nix-community/home-manager) _(Centralized management of programs for both Linux & MacOS)_

> **Why nic-os ?**
>
> Profesionally, I'm known as "NicoS", and this manages my NixOS ! 😛

## NixOS - Base install

### Start

```sh
sudo su
nix-shell -p nixFlakes git
```

### Configuration

Apply disk configuration from [hardward-configuration.nix](./nixos/hardware-configuration.nix) - or switch to [custom installation](#nixos---custom-install).

### Install

```
nixos-install --flake github:nSimonFR/nic-os#BeAsT
```

## NixOS - Custom install

Make sure you're [started correctly](#start) !

### Clone repo

```
git clone git@github.com:nSimonFR/nic-os.git
cd nic-os
```

### Mount disk / hardware configuration

Mount your disks as you wish ([Guide](https://nixos.org/manual/nixos/stable/#sec-installation-manual-partitioning))

Then, re-generate and move `hardware-configuration.nix`:

```sh
nixos-generate-config --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix nixos/
```

### Rename variables _(Optional)_

```
vim flake.nix
# locate and update ouputs => "let"
```

### Install

```sh
nixos-install --flake .#YourConfigName
```

## MacOS - Install

Pre-requesite: [clone](#clone-repo).

### Install `nix`

```sh
sh <(curl -L https://nixos.org/nix/install) --daemon
```

### Install darwin-rebuild

```sh
nix run nix-darwin/nix-darwin-24.11#darwin-rebuild -- switch --flake .#nBookPro --show-trace
```

## Raspberry Pi 5 - Install

Uses [nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi) for vendor kernel, firmware, and bootloader.

### Build installer image

Requires `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` on BeAsT.

```sh
nix build 'github:nvmd/nixos-raspberrypi#installerImages.rpi5' --accept-flake-config
```

### Flash to SD card

```sh
zstdcat result/sd-image/*.img.zst > /tmp/nixos-rpi5-installer.img
sudo dd if=/tmp/nixos-rpi5-installer.img of=/dev/sdX bs=4M status=progress conv=fsync
```

### Boot & switch to final config

Boot the Pi from the SD card, connect via SSH, then:

```sh
sudo nixos-rebuild switch --flake 'path:.#rpi5'
```

## Apply updates

Home Manager is integrated as a NixOS/Darwin module on all machines, so each command below deploys both system and user config in one step.

> **Note:** Use the `path:` prefix (e.g. `path:.#BeAsT`) for local builds so Nix reads files directly from disk, bypassing the git index. This means you don't need to `git add` new files before building.

### NixOS / BeAsT

```sh
sudo nixos-rebuild switch --flake path:.#BeAsT
```

### MacOS / nBookPro

```sh
darwin-rebuild switch --flake path:.#nBookPro
```

### Raspberry Pi 5

Builds on the Pi itself to avoid cross-compilation, then activates remotely:

```sh
nixos-rebuild switch --flake path:.#rpi5 --build-host nsimon@rpi5.local --target-host nsimon@rpi5.local --use-remote-sudo
```

## Update packages

```sh
nix flake update
nix-channel --update
nix-env -u
```

Then, re-apply local updates depending of your implementation !

After all that, you can cleanup your install with;

```sh
nix-collect-garbage -d
```
