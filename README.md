# NixOS config w/ flake

## Import
Clone / download repository !

## Fresh install
```sh
nixos-install --flake .#BeAsT
```

## Apply update
```sh
sudo nixos-rebuild switch --flake .#BeAsT
home-manager switch --flake .#nsimon@BeAsT
```
