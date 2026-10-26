# Entire CLI with its Brain and Graph plugins, from the prebuilt releases.
# Plugins need no registration: `entire <name>` runs `entire-<name>` from PATH.
# Brain needs CLI ≥ 0.11.6; nixpkgs-unstable is at 0.11.5.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
let
  platform =
    {
      aarch64-linux = "linux_arm64";
      aarch64-darwin = "darwin_arm64";
    }
    .${stdenv.hostPlatform.system};

  release =
    repo: version: file: hashes:
    fetchurl {
      url = "https://github.com/entireio/${repo}/releases/download/v${version}/${file}_${platform}.tar.gz";
      hash = hashes.${platform};
    };

  version = "0.12.2";
  cli = release "cli" version "entire" {
    linux_arm64 = "sha256-8IobjGNS0/eAdiaNxnsLJz1/YturlLFa7AKOe0JXrQw=";
    darwin_arm64 = "sha256-7I+KMl4PjwsMF3gZBic7XiG8ElsLts+8DGHK2N/Muk8=";
  };
  brain = release "entire-brain" "0.3.0" "entire-brain_0.3.0" {
    linux_arm64 = "sha256-5w9LxUAQo/HUhC6emTpD81KcBbe/ceQ/eBRvtCJ5qVQ=";
    darwin_arm64 = "sha256-8PjkUNoRZ8Z33xInRvc4voovpAYEnniMx2jaiiJy2SY=";
  };
  graph = release "entire-graph" "0.6.0" "entire-graph_0.6.0" {
    linux_arm64 = "sha256-8R848rhiX4P5EaF352Z2SOAaN+cXS0/Bw2w5JGnBPJc=";
    darwin_arm64 = "sha256-maBHqtqYEcDLntIJJQedhcpB6KnRcmtzz4V1Yi0N4Q8=";
  };
in
stdenv.mkDerivation {
  pname = "entire";
  inherit version;

  srcs = [
    cli
    brain
    graph
  ];
  sourceRoot = ".";

  # entire-graph links libstdc++; the rest are static.
  nativeBuildInputs = lib.optional stdenv.hostPlatform.isLinux autoPatchelfHook;
  buildInputs = lib.optional stdenv.hostPlatform.isLinux stdenv.cc.cc.lib;

  installPhase = ''
    runHook preInstall
    install -Dm755 -t $out/bin entire git-remote-entire entire-brain entire-graph
    runHook postInstall
  '';

  meta = {
    description = "Entire CLI (agent-session checkpoints) with the Brain and Graph plugins";
    homepage = "https://github.com/entireio/cli";
    license = lib.licenses.mit;
    mainProgram = "entire";
    platforms = [
      "aarch64-linux"
      "aarch64-darwin"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
