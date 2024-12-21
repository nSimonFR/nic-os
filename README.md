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
sh <(curl -L https://nixos.org/nix/install) --darwin-use-unencrypted-nix-store-volume --daemon
```

### Home Manager install

```sh
nix-shell -p nixUnstable --command "nix build --experimental-features 'nix-command flakes' '.#homeConfigurations.nBook-Pro.activationPackage'" # Or replace host
./result/activate
```

## Apply updates (local)

### NixOS / BeAsT

```sh
nixos-rebuild switch --flake .#BeAsT
```

### Home Manager - NixOS

```sh
home-manager switch --flake .#BeAsT
```

### Home Manager - MacOS

```sh
home-manager switch --flake .#nBook-Pro
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
