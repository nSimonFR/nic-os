{ lib, python3Packages }:
# nicos-scripts — the shared library + connector entry points for the rpi5
# Python scripts (hosts/rpi5/scripts/lib/).
#
# Why a package at all: the old wiring was
# `${pkgs.python3}/bin/python3 ${./scripts/steam-to-ryot.py}`, which puts a bare
# file in the store with no importable sibling — so a shared helper module was
# impossible (hence nine copies of `log()`), and nothing could be imported by a
# test either. Building a real Python package gives both: `bin/steam-to-ryot` for
# the systemd units, and `import nicos_scripts` for pytest.
#
# Stdlib only, on purpose (see pyproject.toml). If a script ever needs a real
# dependency, add it to `dependencies` there AND to `dependencies` here — the
# build will not resolve anything from PyPI.
#
# The tests run in checkPhase, so building this derivation IS the test run:
#   nix build .#checks.aarch64-linux.nicos-scripts   (or x86_64-linux on beast)
# Pure Python, so it builds on either platform — the checks do not need the Pi.
python3Packages.buildPythonPackage {
  pname = "nicos-scripts";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSourceWith {
    src = ../../hosts/rpi5/scripts/lib;
    # Keep the store path stable no matter what a local `pytest` run left behind.
    filter =
      path: _type:
      !(lib.hasInfix "__pycache__" path || lib.hasInfix ".pytest_cache" path);
  };

  build-system = [ python3Packages.setuptools ];

  # The one real dependency, declared in pyproject.toml too. papra.tag_sync writes
  # Nextcloud systemtags directly into Postgres; it imports psycopg2 lazily so the
  # module stays importable (and its tests runnable) without it.
  dependencies = [ python3Packages.psycopg2 ];

  nativeCheckInputs = [ python3Packages.pytestCheckHook ];

  # Every entry point, imported in the sandbox. This is the guard against the class
  # of bug that made these files unloadable off-host in the first place: an
  # `os.environ[...]`, a `sqlite3.connect()` or a secret read at module level fails
  # right here instead of at 05:20 on a timer.
  pythonImportsCheck = [
    "nicos_scripts"
    "nicos_scripts.connectors.steam"
    "nicos_scripts.connectors.spotify"
    "nicos_scripts.connectors.scale"
    "nicos_scripts.connectors.moxfield"
    "nicos_scripts.connectors.travel_cal"
    "nicos_scripts.connectors.wealthfolio"
    "nicos_scripts.homepage.stats"
    "nicos_scripts.claude.notify_aggregator"
    "nicos_scripts.claude.boot_resume"
    "nicos_scripts.claude.memory_sync"
    "nicos_scripts.papra.tag_sweep"
    "nicos_scripts.papra.proton_poll"
    "nicos_scripts.papra.tag_sync"
  ];

  meta = {
    description = "Shared library + connector entry points for the nic-os rpi5 scripts";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
