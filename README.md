# NixOS config w/ flake

## Fresh NixOS install
```sh
# TODO Mount disks on /mnt

nix-shell -p nixFlakes git
git clone git@github.com:nSimonFR/nic-os.git
cd nic-os
sudo nixos-install --flake .#desktop
```

## Apply update from NixOS
```sh
# TODO Get the repo and be in it !

sudo nixos-rebuild switch --flake .#desktop
home-manager switch --flake .#desktop
```

## Install on MacOS
```sh
# TODO Get the repo and be in it !

# Install nix if not installed
sh <(curl -L https://nixos.org/nix/install) --darwin-use-unencrypted-nix-store-volume --daemon

nix-shell -p nixUnstable --command "nix build --experimental-features 'nix-command flakes' '.#homeConfigurations.macbookpro.activationPackage'"
./result/activate
home-manager build --flake .#macbookpro
```
