# Death Plan Switch — self-hosted dead man's switch (Romeo19361/deathplanswitch).
# Plain PHP, no build step; laid out under share/switch/ so nginx can serve the
# share/ root and the app sees SCRIPT_NAME=/switch/… (it derives its base URL and
# cookie path from that). Data lives outside the store via config.local.php.
#
# BUMPING: upstream has no tags yet — change `rev` AND `hash`. Renovate skips pkgs/.
#
# vault-access.patch adds a {vault_access} placeholder, filled at send time by
# `vaultHook access <contact-id>` (dps-ea-bridge); without a hook it says the
# details follow separately.
{ lib, stdenvNoCC, fetchFromGitHub, dataDir ? "/var/lib/death-plan-switch", vaultHook ? null }:
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

  patches = [ ./death-plan-switch-vault-access.patch ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share
    cp -r . $out/share/switch
    rm -rf $out/share/switch/data
    cat > $out/share/switch/config.local.php <<'EOF'
    <?php
    define('DPS_DATA', '${dataDir}');
    ${lib.optionalString (vaultHook != null) "define('DPS_VAULT_HOOK', '${vaultHook}');"}
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
