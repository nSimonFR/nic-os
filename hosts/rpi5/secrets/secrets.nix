let
  nsimon-age = "age1x99u04m887emqp9dp44r4ey8ky8m8gtuwx07z2fm89u8xu6jfa2sxjux9w";
  nsimon-ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ7wzLFXmWeZ52SWjvsfXSZr+LbvpZYt/EE/tzVZnFd";
in {
  "agent-env.age".publicKeys          = [ nsimon-age nsimon-ed25519 ];
  "papra-webhook-secret.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "supervisor-token.age".publicKeys   = [ nsimon-age nsimon-ed25519 ];
  "linky-token.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "linky-prm.age".publicKeys          = [ nsimon-age nsimon-ed25519 ];
  "rclone-storj.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "aperture-s3-export.age".publicKeys  = [ nsimon-age nsimon-ed25519 ];
  "immich-api-key.age".publicKeys      = [ nsimon-age nsimon-ed25519 ];
  "sure-app-env.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "sure-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 ];
  "airtrail-env.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "airtrail-pg-password.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "ryot-env.age".publicKeys            = [ nsimon-age nsimon-ed25519 ];
  "ryot-import-env.age".publicKeys     = [ nsimon-age nsimon-ed25519 ];
  "ryot-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 ];
  "steam-connector-env.age".publicKeys   = [ nsimon-age nsimon-ed25519 ];
  "spotify-connector-env.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "vaultwarden-admin-token.age".publicKeys  = [ nsimon-age nsimon-ed25519 ];
  "restic-password.age".publicKeys         = [ nsimon-age nsimon-ed25519 ];
  "affine-mcp-cookie.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  "affine-gcal-oauth.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  "affine-mcp-http-token.age".publicKeys   = [ nsimon-age nsimon-ed25519 ];
  "tavily-api-key.age".publicKeys          = [ nsimon-age nsimon-ed25519 ];
  "for-sure-api-key.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "dawarich-geoapify.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  "papra-env.age".publicKeys                = [ nsimon-age nsimon-ed25519 ];
  "nextcloud-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 ];
  "protonmail-bridge-password.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "nextcloud-homepage-password.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "wakapi-password-salt.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "wakapi-smtp-env.age".publicKeys             = [ nsimon-age nsimon-ed25519 ];
  "wakapi-api-key.age".publicKeys              = [ nsimon-age nsimon-ed25519 ];
  "cyrus-linear-client-id.age".publicKeys      = [ nsimon-age nsimon-ed25519 ];
  "cyrus-linear-client-secret.age".publicKeys  = [ nsimon-age nsimon-ed25519 ];
  "cyrus-linear-webhook-secret.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "cyrus-github-webhook-secret.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "reactive-resume-encryption-secret.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "reactive-resume-auth-secret.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  "reactive-resume-db-password.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  "beaverhabits-env.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "gramps-web-secret.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  "epicgames-account-email.age".publicKeys = [ nsimon-age nsimon-ed25519 ];
  "scale-bridge-env.age".publicKeys        = [ nsimon-age nsimon-ed25519 ];
  "wealthfolio-env.age".publicKeys         = [ nsimon-age nsimon-ed25519 ];
  "wealthfolio-sync-env.age".publicKeys    = [ nsimon-age nsimon-ed25519 ];
  "wealthfolio-mcp-token.age".publicKeys   = [ nsimon-age nsimon-ed25519 ];
  "etherscan-api-key.age".publicKeys       = [ nsimon-age nsimon-ed25519 ];
  # Two encryptions of one password: the bare value for nic.pgRole's ALTER USER,
  # and the FREEREPS_DB_PASSWORD= assignment for freereps.service's
  # EnvironmentFile. Same split as airtrail-pg-password / airtrail-env.
  "freereps-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 ];
  "freereps-env.age".publicKeys            = [ nsimon-age nsimon-ed25519 ];
  "searxng-env.age".publicKeys             = [ nsimon-age nsimon-ed25519 ];
}
