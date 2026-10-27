let
  nsimon-age = "age1x99u04m887emqp9dp44r4ey8ky8m8gtuwx07z2fm89u8xu6jfa2sxjux9w";
  nsimon-ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ7wzLFXmWeZ52SWjvsfXSZr+LbvpZYt/EE/tzVZnFd";
  # rpi5's SSH host key (`/etc/ssh/ssh_host_ed25519_key`, root-only): what it decrypts with.
  rpi5-host = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFeBo33hUAosqezYSzFOdVnzwnz0ShD0jnjysuU8LSCg";
in {
  "agent-env.age".publicKeys          = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "agent-brokered-env.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "supervisor-token.age".publicKeys   = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "linky-token.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "linky-prm.age".publicKeys          = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "rclone-storj.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "aperture-s3-export.age".publicKeys  = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "immich-api-key.age".publicKeys      = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "sure-app-env.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "sure-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "airtrail-env.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "airtrail-pg-password.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "airtrail-mcp-token.age".publicKeys   = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "ryot-env.age".publicKeys            = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "ryot-import-env.age".publicKeys     = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "ryot-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "steam-connector-env.age".publicKeys   = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "spotify-connector-env.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "vaultwarden-admin-token.age".publicKeys  = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "github-ai-token.age".publicKeys          = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "forgejo-github-mirror-token.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "vaultwarden-agent-password.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "restic-password.age".publicKeys         = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "affine-mcp-cookie.age".publicKeys       = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "affine-gcal-oauth.age".publicKeys       = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "affine-mcp-http-token.age".publicKeys   = [ nsimon-age nsimon-ed25519 rpi5-host ];
"asale-api-key.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "cachix-agent-token.age".publicKeys   = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "cachix-activate-token.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "tavily-api-key.age".publicKeys          = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "for-sure-api-key.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "dawarich-geoapify.age".publicKeys       = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "papra-env.age".publicKeys                = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "nextcloud-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "protonmail-bridge-password.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "nextcloud-homepage-password.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  # {"<slug>": "<ics url>"} for ics-mirror. Encrypted because a Google
  # `private-<token>/basic.ics` URL is unexpiring read access to the whole
  # calendar — it must never be committed in clear to this PUBLIC repo.
  "calino-ics-feeds.age".publicKeys            = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "wakapi-password-salt.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "wakapi-smtp-env.age".publicKeys             = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "wakapi-api-key.age".publicKeys              = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "cyrus-linear-client-id.age".publicKeys      = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "cyrus-linear-client-secret.age".publicKeys  = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "cyrus-linear-webhook-secret.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "cyrus-github-webhook-secret.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "reactive-resume-encryption-secret.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "reactive-resume-auth-secret.age".publicKeys       = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "reactive-resume-db-password.age".publicKeys       = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "beaverhabits-env.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "gramps-web-secret.age".publicKeys       = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "epicgames-account-email.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "scale-bridge-env.age".publicKeys        = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "wealthfolio-env.age".publicKeys         = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "wealthfolio-sync-env.age".publicKeys    = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "wealthfolio-mcp-token.age".publicKeys   = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "etherscan-api-key.age".publicKeys       = [ nsimon-age nsimon-ed25519 rpi5-host ];
  # Two encryptions of one password: the bare value for nic.pgRole's ALTER USER,
  # and the FREEREPS_DB_PASSWORD= assignment for freereps.service's
  # EnvironmentFile. Same split as airtrail-pg-password / airtrail-env.
  "freereps-pg-password.age".publicKeys    = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "freereps-env.age".publicKeys            = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "searxng-env.age".publicKeys             = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "agent-vault-env.age".publicKeys         = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "agent-vault-admin-password.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
  "rpi5-healthcheck.age".publicKeys = [ nsimon-age nsimon-ed25519 rpi5-host ];
}
