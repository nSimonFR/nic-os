{
  lib,
  buildGo126Module,
  mtg-mcp-src,
  version ? "2.1.0",
  vendorHash ? "sha256-UsWmkMp+kHOXjKvtPbpm4Y4hw7FtjEJgHtjkr4PhTjY=",
}:

# MTG MCP — Magic: The Gathering / Commander MCP server. Go, stdio transport,
# no secrets (just needs outbound HTTPS to Scryfall/EDHREC/Moxfield/Archidekt).
# Source input pinned in flake.nix (mtg-mcp-src); wired into Claude Code by
# home/mcp.nix. main.go is at the repo root, so the default build produces a
# `mtg-mcp` binary.
buildGo126Module {
  pname = "mtg-mcp";
  inherit version vendorHash;

  src = mtg-mcp-src;

  # The *_e2e_test.go suites hit live external APIs — skip tests in the sandbox.
  doCheck = false;

  ldflags = [
    "-s"
    "-w"
  ];

  meta = with lib; {
    description = "Magic: The Gathering / Commander MCP server (Scryfall, EDHREC, Moxfield, Archidekt, rules)";
    homepage = "https://github.com/nathanmartins/mtg-mcp";
    license = licenses.mit;
    mainProgram = "mtg-mcp";
  };
}
