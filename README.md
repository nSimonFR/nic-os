# NicOS - My nix configs w/ flake

## NixOS - Fresh install

### Start
```sh
sudo su
nix-shell -p nixFlakes git
```

### Clone
```sh
git clone git@github.com:nSimonFR/nic-os.git
cd nic-os
```

### Mount disk
Either mount your disk as in [./nixos/hardward-configuration.nix](./nixos/hardware-configuration.nix) 

Or, mount any of your disks as you wish ([Guide](https://nixos.org/manual/nixos/stable/#sec-installation-manual-partitioning)) and re-generate `hardware-configuration.nix`:
```sh
nixos-generate-config --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix nixos/
```

### Rename variables
```
vim flake.nix
# locate and update ouputs => "let"
```

### Install
```sh
sudo nixos-install --flake .#BeAsT # Or your own !
```

## MacOS - Install
### Install nix (If not present)
```sh
sh <(curl -L https://nixos.org/nix/install) --darwin-use-unencrypted-nix-store-volume --daemon
```

### Initial install 
```sh
nix-shell -p nixUnstable --command "nix build --experimental-features 'nix-command flakes' '.#homeConfigurations.macbookpro.activationPackage'"
./result/activate
```

## Apply updates

### Home Manager (All configurations)
```sh
home-manager switch --flake .#BeAsT # Or any configuration !
```

### NixOS
```sh
sudo nixos-rebuild switch --flake .#BeAsT # Or your own !
```
