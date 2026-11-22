{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pam,
}:
# PAM module that verifies a webauthn-sk signature from the SSH agent — the
# ShellWatch path for sudo. Built from source: it runs inside sudo as root.
rustPlatform.buildRustPackage rec {
  pname = "pam-ssh-agent-webauthn";
  # renovate: datasource=github-releases depName=rado0x54/pam-ssh-agent-webauthn extractVersion=^v(?<version>.+)$
  version = "1.0.1";

  src = fetchFromGitHub {
    name = "${pname}-${version}-source";
    owner = "rado0x54";
    repo = "pam-ssh-agent-webauthn";
    rev = "v${version}";
    hash = "sha256-4678UWJ2r+MFbdxyK1vCi4KzDExjywyAkvZBOxdHQi8=";
  };

  # shellwatch-agent advertises passkeys as sk-ecdsa-…; upstream only matched
  # agent blobs typed webauthn-sk-ecdsa-…, so it saw no key.
  patches = [ ./pam-ssh-agent-webauthn-sk-agent-blob.patch ];

  cargoHash = "sha256-CPljzVaJTWreFok6nlIb9WKxGzPJZjsbyy6RnMEZ3YI=";

  buildInputs = [ pam ];

  # buildRustPackage installs the cdylib as $out/lib/lib<name>.so.
  postInstall = ''
    mkdir -p $out/lib/security
    mv $out/lib/libpam_ssh_agent_webauthn.so $out/lib/security/pam_ssh_agent_webauthn.so
  '';

  meta = {
    description = "PAM module: sudo on a WebAuthn passkey signature through the SSH agent";
    homepage = "https://github.com/rado0x54/pam-ssh-agent-webauthn";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
