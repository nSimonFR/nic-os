let
  nsimon-age = "age1x99u04m887emqp9dp44r4ey8ky8m8gtuwx07z2fm89u8xu6jfa2sxjux9w";
  nsimon-ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ7wzLFXmWeZ52SWjvsfXSZr+LbvpZYt/EE/tzVZnFd";
in {
  "picoclaw-env.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  "supervisor-token.age".publicKeys   = [ nsimon-age nsimon-ed25519 ];
  "linky-token.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "linky-prm.age".publicKeys          = [ nsimon-age nsimon-ed25519 ];
  "rclone-storj.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "immich-api-key.age".publicKeys      = [ nsimon-age nsimon-ed25519 ];
  "sure-app-env.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "sure-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 ];
  "vaultwarden-admin-token.age".publicKeys  = [ nsimon-age nsimon-ed25519 ];
  "restic-password.age".publicKeys         = [ nsimon-age nsimon-ed25519 ];
  "affine-token.age".publicKeys            = [ nsimon-age nsimon-ed25519 ];
  "affine-gcal-oauth.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  "tavily-api-key.age".publicKeys          = [ nsimon-age nsimon-ed25519 ];
  "for-sure-api-key.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "dawarich-geoapify.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  "paperless-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 ];
  "paperless-admin-password.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "paperless-env.age".publicKeys            = [ nsimon-age nsimon-ed25519 ];
  "paperless-api-token.age".publicKeys      = [ nsimon-age nsimon-ed25519 ];
}
