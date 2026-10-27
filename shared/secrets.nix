let
  nsimon-age = "age1x99u04m887emqp9dp44r4ey8ky8m8gtuwx07z2fm89u8xu6jfa2sxjux9w";
  nsimon-ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ7wzLFXmWeZ52SWjvsfXSZr+LbvpZYt/EE/tzVZnFd";
  rpi5-host = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFeBo33hUAosqezYSzFOdVnzwnz0ShD0jnjysuU8LSCg"; # only for what the rpi5 decrypts (hosts/rpi5/secrets.nix)
in {
  "secrets.zsh.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "telegram-bot-token.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "mcp-secrets.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "wakatime.cfg.age".publicKeys       = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "terradex-convex-deploy-key.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  # linear-t3-relay instance environments (hosts/nbookpro/linear-t3-relay.nix).
  "linear-t3-relay-nsimon.env.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "linear-t3-relay-work.env.age".publicKeys   = [ nsimon-age nsimon-ed25519 ];
}
