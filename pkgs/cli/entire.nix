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

  # renovate: datasource=github-releases depName=entireio/cli extractVersion=^v(?<version>.+)$
  version = "0.12.2";
  # renovate: datasource=github-releases depName=entireio/entire-brain extractVersion=^v(?<version>.+)$
  brainVersion = "0.3.0";
  # renovate: datasource=github-releases depName=entireio/entire-graph extractVersion=^v(?<version>.+)$
  graphVersion = "0.6.0";

  # One fetchurl per release, hashes inline: scripts/nix-fix-hashes.py reads this shape.
  cli = fetchurl {
    name = "entire-${version}-${platform}.tar.gz";
    url = "https://github.com/entireio/cli/releases/download/v${version}/entire_${platform}.tar.gz";
    hash =
      {
        linux_arm64 = "sha256-8IobjGNS0/eAdiaNxnsLJz1/YturlLFa7AKOe0JXrQw=";
        darwin_arm64 = "sha256-7I+KMl4PjwsMF3gZBic7XiG8ElsLts+8DGHK2N/Muk8=";
      }
      .${platform};
  };
  brain = fetchurl {
    name = "entire-brain-${brainVersion}-${platform}.tar.gz";
    url = "https://github.com/entireio/entire-brain/releases/download/v${brainVersion}/entire-brain_${brainVersion}_${platform}.tar.gz";
    hash =
      {
        linux_arm64 = "sha256-5w9LxUAQo/HUhC6emTpD81KcBbe/ceQ/eBRvtCJ5qVQ=";
        darwin_arm64 = "sha256-8PjkUNoRZ8Z33xInRvc4voovpAYEnniMx2jaiiJy2SY=";
      }
      .${platform};
  };
  graph = fetchurl {
    name = "entire-graph-${graphVersion}-${platform}.tar.gz";
    url = "https://github.com/entireio/entire-graph/releases/download/v${graphVersion}/entire-graph_${graphVersion}_${platform}.tar.gz";
    hash =
      {
        linux_arm64 = "sha256-8R848rhiX4P5EaF352Z2SOAaN+cXS0/Bw2w5JGnBPJc=";
        darwin_arm64 = "sha256-maBHqtqYEcDLntIJJQedhcpB6KnRcmtzz4V1Yi0N4Q8=";
      }
      .${platform};
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
