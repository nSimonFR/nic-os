# NixOS module: nixpkgs overlays for the RPi5 system.
{ inputs, ... }:
let
  # prefetch-npm-deps leaves a zero-filled cache entry for
  # stylehacks-6.1.1 on aarch64-linux (bug in prefetch-npm-deps).
  # Reconstruct the valid index entry from the known integrity hash
  # and the content that IS correctly stored in the FOD.
  npmStylehacksFix = pkgs: pkgs.writeText "fix-npm-stylehacks.py" ''
    import hashlib, json, os
    url = "https://registry.npmjs.org/stylehacks/-/stylehacks-6.1.1.tgz"
    integrity = "sha512-gSTTEQ670cJNoaeIp9KX6lZmm8LJ3jPB5yJmX8Zq/wQxOsAFXV3qjWzHas3YYk1qesuVIyYWWUpZ0vSE/dTSGg=="
    size = 9516
    key = "make-fetch-happen:request-cache:" + url
    body = json.dumps({"key": key, "integrity": integrity, "time": 0, "size": size, "metadata": {"url": url, "options": {"compress": True}}}, separators=(",", ":"))
    sha1 = hashlib.sha1(body.encode()).hexdigest()
    entry = sha1 + "\t" + body
    tmp = os.environ["tmpCache"]
    path = os.path.join(tmp, "_cacache/index-v5/47/46/dcd39de6f4df2818ec596aba6950bada076ac5938d40ccfa4ad3922b0981")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(entry)
    print("Reconstructed stylehacks-6.1.1 npm cache index entry")
  '';
in
{
  nixpkgs.overlays = [
    # uv 0.9.26 from release-25.11 fails to build on aarch64-linux; use nixpkgs-unstable
    (
      final: prev:
      rec {
        unstablePkgs = import inputs.nixpkgs-unstable {
          system = prev.stdenv.hostPlatform.system;
          config.allowUnfree = true;
        };
        uv = unstablePkgs.uv;
        # Keep Ghostfolio current to pick up Yahoo upstream fixes.
        # Temporary pin to 2.247.0 until nixpkgs ships this version.
        ghostfolio = unstablePkgs.ghostfolio.overrideAttrs (old: rec {
          version = "2.247.0";
          src = prev.fetchFromGitHub {
            owner = "ghostfolio";
            repo = "ghostfolio";
            tag = version;
            hash = "sha256-pUFrbPNyHis18Ta/p8DNfM0dz7R7ucGd981gleCFQyw=";
            leaveDotGit = true;
            postFetch = ''
              date -u -d "@$(git -C $out log -1 --pretty=%ct)" +%s%3N > $out/SOURCE_DATE_EPOCH
              find "$out" -name .git -print0 | xargs -0 rm -rf
            '';
          };
          npmDepsHash = "sha256-eDzoCT28gRhmHxRHKUXl2Gm0Rpso/R5SKaxCuFkZjS8=";
          npmDeps = prev.fetchNpmDeps {
            inherit src;
            hash = npmDepsHash;
          };
          # prefetch-npm-deps leaves a zero-filled cache entry for
          # stylehacks-6.1.1 on aarch64-linux, causing npmConfigHook
          # (a postPatchHook) to fail with "dependency should have a hash".
          # Fix: in postPatch (runs before postPatchHooks/npmConfigHook),
          # copy npmDeps to a writable tmpdir and reconstruct the corrupt
          # index entry with valid JSON using the known integrity hash.
          postPatch = (old.postPatch or "") + ''
            tmpCache=$(mktemp -d)
            cp -r "$npmDeps"/. "$tmpCache"/
            chmod -R u+w "$tmpCache"
            tmpCache="$tmpCache" ${prev.python3}/bin/python3 ${npmStylehacksFix prev}
            export npmDeps="$tmpCache"
          '';
        });
      }
    )

    inputs.nix-openclaw.overlays.default

    # Redis/Valkey cluster tests are flaky in the Nix sandbox
    (final: prev: {
      redis = prev.redis.overrideAttrs (_: {
        doCheck = false;
        doInstallCheck = false;
      });
      valkey = prev.valkey.overrideAttrs (_: {
        doCheck = false;
        doInstallCheck = false;
      });
    })
  ];
}
