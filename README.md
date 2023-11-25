# NicOS - My nix configs w/ flake

## NixOS - Fresh install

### Start

```sh
sudo su
nix-shell -p nixFlakes git
```

### Mount disk

Either mount your disk as in [./nixos/hardward-configuration.nix](./nixos/hardware-configuration.nix)

Or, mount any of your disks as you wish ([Guide](https://nixos.org/manual/nixos/stable/#sec-installation-manual-partitioning)) and re-generate `hardware-configuration.nix`:

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
nixos-install --flake github:nSimonFR/nic-os#BeAsT # Or your own !
```

## MacOS - Install

### Install `nix`

```sh
sh <(curl -L https://nixos.org/nix/install) --darwin-use-unencrypted-nix-store-volume --daemon
```

### Home Manager install

```sh
nix-shell -p nixUnstable --command "nix build --experimental-features 'nix-command flakes' '.#homeConfigurations.nBook-Pro.activationPackage'" # Or replace host
./result/activate
```

## Apply updates

### Home Manager (All configurations)

```sh
home-manager switch --flake github:nSimonFR/nic-os#BeAsT # Or any configuration !
```

### NixOS

```sh
nixos-rebuild switch --flake github:nSimonFR/nic-os#BeAsT # Or your own !
```
