let
  nsimon-age = "age1x99u04m887emqp9dp44r4ey8ky8m8gtuwx07z2fm89u8xu6jfa2sxjux9w";
  nsimon-ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ7wzLFXmWeZ52SWjvsfXSZr+LbvpZYt/EE/tzVZnFd";
in {
  "secrets.zsh.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "telegram-bot-token.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "mcp-secrets.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
}
