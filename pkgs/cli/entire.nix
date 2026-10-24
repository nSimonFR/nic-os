{
  lib,
  buildGo127Module,
  fetchFromGitHub,
  installShellFiles,
}:

# nixpkgs ships 0.6.2; go.mod needs Go 1.27.3, above the default go.
buildGo127Module (finalAttrs: {
  pname = "entire";
  version = "0.12.0";

  src = fetchFromGitHub {
    name = "${finalAttrs.pname}-${finalAttrs.version}-source";
    owner = "entireio";
    repo = "cli";
    tag = "v${finalAttrs.version}";
    hash = "sha256-iwRPqF4lc/9EPjhV8FoSleMoyc+k0fsSPJBdBDPX+NY=";
  };

  vendorHash = "sha256-RU0ZSkwGk8bL4mkhnMDveNIW7JGwYwudT+ywmncuT2k=";

  subPackages = [ "cmd/entire" ];

  ldflags = [
    "-s"
    "-X=github.com/entireio/cli/cmd/entire/cli/versioninfo.Version=${finalAttrs.version}"
    "-X=github.com/entireio/cli/cmd/entire/cli/versioninfo.Commit=${finalAttrs.src.tag}"
  ];

  # The suite drives real git repos and agent CLIs; upstream runs it in CI.
  doCheck = false;

  nativeBuildInputs = [ installShellFiles ];

  postInstall = ''
    installShellCompletion --cmd entire \
      --bash <($out/bin/entire completion bash) \
      --zsh <($out/bin/entire completion zsh)
  '';

  meta = {
    description = "Capture AI agent sessions alongside git commits";
    homepage = "https://github.com/entireio/cli";
    license = lib.licenses.mit;
    mainProgram = "entire";
  };
})
