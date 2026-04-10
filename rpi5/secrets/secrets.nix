let
  nsimon-age = "age1x99u04m887emqp9dp44r4ey8ky8m8gtuwx07z2fm89u8xu6jfa2sxjux9w";
  nsimon-rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCfTlFbZh0ufzEysBxzaEhLU7A4J/n+c3ObaBr+nJPoovoBh9q4hB9KYwkr7y1wkkZgA6/aZqJu4HH2SCARGabyPJW2h2QY+IXs/pI7TV0eFaCP8SZjHWtz5rBm92pVSzXd/6/YoO+Ugn9EsuPYgnuGYlFaQ1BQrqCpJ7d+c9ZNU4mEKPNM5Ly/yo2V5Ox5nBfQg7jq9YIP0UFFwRe28Pi5OGCn0Wl+1aTOtd9sB06pXB4/CxCGRKZJLGe6QVMTFZJLObitjYpEX3zZ4Cj2MEiHVf6eubH0kTo6RSxYBZJBB2mmgBoDr9uae95LTXUBYoMPFb0dNYxzwe6HDZnqkBvlfsO6CHHAJYxqkRhxHgCy2gItJXpZ4HAPGezcnvBinTfuyf18Crb9wxiH5VaCaNaLhp66881KdLoMzNUTWU9L0ZRMzmabj0XgjpRLEqnTdvqq6H+NwYF1Avew07zwb8iZtbCIb2dxu653RxM8DwxmUnfmAAuxvxOoFpgYjDsDkahDEOynTkYWASbOoha66H5tU0mrAdeyooieHlFqAz/vjo5X/eIerWVrKEy0MdLx4Yu15ObTlWscU3qQyUmVlnH0SDg7ulH+4uNsXFE7jGHwg03MpYYAExTbPMpKlhJdaQI2Jzp3CcSqIG+1ODuPK8VcshTAtP0IrZ+ykFflB4EIcw==";
in {
  "openclaw.env.age".publicKeys       = [ nsimon-age nsimon-rsa ];
  "supervisor-token.age".publicKeys   = [ nsimon-age nsimon-rsa ];
  "linky-token.age".publicKeys        = [ nsimon-age nsimon-rsa ];
  "linky-prm.age".publicKeys          = [ nsimon-age nsimon-rsa ];
  "openclaw-codex-auth.age".publicKeys = [ nsimon-age nsimon-rsa ];
  "rclone-storj.age".publicKeys        = [ nsimon-age nsimon-rsa ];
  "immich-api-key.age".publicKeys      = [ nsimon-age nsimon-rsa ];
  "sure-app-env.age".publicKeys        = [ nsimon-age nsimon-rsa ];
  "sure-pg-password.age".publicKeys    = [ nsimon-age nsimon-rsa ];
  "for-sure-swile-api-key.age".publicKeys   = [ nsimon-age nsimon-rsa ];
  "vaultwarden-admin-token.age".publicKeys  = [ nsimon-age nsimon-rsa ];
  "siyuan-auth-code.age".publicKeys        = [ nsimon-age nsimon-rsa ];
}
