# inkeep/open-knowledge — markdown knowledge base: web editor + MCP over a plain .md folder.
#
# The npm tarball ships no lockfile, so package.json/package-lock.json here are a one-dep
# wrapper (regenerate with `npm install --package-lock-only --ignore-scripts` after a bump).
# Service module: hosts/rpi5/notes.nix.
{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs_24,
  git,
  perl,
}:

buildNpmPackage {
  pname = "open-knowledge";
  # renovate: datasource=npm depName=@inkeep/open-knowledge
  version = "0.82.1";
  src = ./.;
  nodejs = nodejs_24;
  npmDepsHash = "sha256-cTn+JlMLnPyE/1hyWy4oQHPx8ML8mwgu+4iyCEqQBak=";
  # @parcel/watcher's install script compiles from source; its prebuilt platform package
  # is already in the lock, and chokidar covers the rest.
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  dontNpmInstall = true;
  nativeBuildInputs = [
    makeWrapper
    perl
  ];

  # Its git calls pass `.env({GIT_DIR: …})`, which replaces the whole environment: no PATH,
  # so `spawn git ENOENT` and edit history is silently disabled. Give them PATH and HOME.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/open-knowledge $out/bin
    cp -r node_modules $out/lib/open-knowledge/
    dist=$out/lib/open-knowledge/node_modules/@inkeep/open-knowledge/dist
    perl -pi -e 's/(?<!process\.env,)\{GIT_DIR:/{PATH:process.env.PATH,HOME:process.env.HOME,GIT_DIR:/g' $dist/*.mjs
    if grep -qP '(?<!process\.env,)\{GIT_DIR:' $dist/*.mjs; then
      echo "git env patch did not apply" >&2; exit 1
    fi
    grep -q 'PATH:process.env.PATH,HOME:process.env.HOME,GIT_DIR' $dist/*.mjs
    makeWrapper ${lib.getExe nodejs_24} $out/bin/open-knowledge \
      --add-flags "$dist/cli.mjs" \
      --prefix PATH : ${lib.makeBinPath [ git ]}
    runHook postInstall
  '';

  meta = {
    description = "Markdown knowledge base with a web editor and MCP server";
    homepage = "https://github.com/inkeep/open-knowledge";
    license = lib.licenses.gpl3Only;
    mainProgram = "open-knowledge";
  };
}
