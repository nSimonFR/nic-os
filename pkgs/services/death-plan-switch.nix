# Death Plan Switch — self-hosted dead man's switch (Romeo19361/deathplanswitch).
# Plain PHP, no build step; laid out under share/switch/ so nginx can serve the
# share/ root and the app sees SCRIPT_NAME=/switch/… (it derives its base URL and
# cookie path from that). Data lives outside the store via config.local.php.
#
# BUMPING: upstream has no tags yet — change `rev` AND `hash`. Renovate skips pkgs/.
{ lib, stdenvNoCC, fetchFromGitHub, dataDir ? "/var/lib/death-plan-switch" }:
stdenvNoCC.mkDerivation rec {
  pname = "death-plan-switch";
  version = "1.0.0-unstable-2026-10-20";

  src = fetchFromGitHub {
    owner = "Romeo19361";
    repo = "deathplanswitch";
    rev = "2007fa2714434f8850b5779b1cd0fbe36f75dbc3";
    # `name` carries the version so a rev bump with a stale hash refetches.
    name = "${pname}-${version}-src";
    hash = "sha256-5nf/hXXEYcWZqpQnvZrsFqIyztPUHzJ6g0NLypJJHEw=";
  };

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share
    cp -r . $out/share/switch
    rm -rf $out/share/switch/data
    cat > $out/share/switch/config.local.php <<'EOF'
    <?php
    define('DPS_DATA', '${dataDir}');
    EOF
    runHook postInstall
  '';

  meta = {
    description = "Self-hosted dead man's switch that emails your contacts";
    homepage = "https://github.com/Romeo19361/deathplanswitch";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
