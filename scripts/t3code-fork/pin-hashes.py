#!/usr/bin/env python3
"""Pin the three t3code release assets in pkgs/agents.

    pin-hashes.py LINUX_TGZ DARWIN_TGZ DESKTOP_ZIP

LINUX_TGZ and DESKTOP_ZIP are the fork's -issues release; DARWIN_TGZ is
upstream's CLI archive. scripts/nix-fix-hashes.py cannot do this: the URLs
interpolate the version and the fork asset does not exist until it is built.
"""

import base64
import hashlib
import pathlib
import re
import sys


def sri(path: str) -> str:
    digest = hashlib.sha256(pathlib.Path(path).read_bytes()).digest()
    return "sha256-" + base64.b64encode(digest).decode()


def pin(path: str, key: str, asset: str) -> bool:
    file = pathlib.Path(path)
    text = file.read_text()
    new, n = re.subn(
        rf'({key} \{{\s*url = [^;]+;\s*hash = ")[^"]+(")',
        lambda m: m.group(1) + sri(asset) + m.group(2),
        text,
        count=1,
    )
    if n != 1:
        sys.exit(f"{path}: no `{key}` block with a hash")
    file.write_text(new)
    return new != text


linux, darwin, desktop = sys.argv[1:4]
changed = [
    pin("pkgs/agents/t3code.nix", "linux-arm64 =", linux),
    pin("pkgs/agents/t3code.nix", "darwin-arm64 =", darwin),
    pin("pkgs/agents/t3code-desktop.nix", "src = fetchurl", desktop),
]
print("pinned" if any(changed) else "already pinned")
