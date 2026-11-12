# mcp-email-server — IMAP/SMTP MCP server (Wh1isper/mcp-email-server). Hermes'
# only mail tool: Proton through hydroxide and Gmail over IMAP, wired in
# hosts/rpi5/agents/hermes/mail-mcp.nix.
{ python3Packages }:
let
  # nixpkgs' aioimaplib 2.0.1 fails 2 of its own tests (test_store*, an imaplib2
  # tuple-shape mismatch in the test server), not in the client code we call.
  aioimaplib = python3Packages.aioimaplib.overridePythonAttrs { doCheck = false; };
in
python3Packages.buildPythonApplication rec {
  pname = "mcp-email-server";
  # renovate: datasource=pypi depName=mcp-email-server
  version = "1.14.0";
  pyproject = true;

  src = python3Packages.fetchPypi {
    pname = "mcp_email_server";
    inherit version;
    hash = "sha256-3z3rjQZF2W2MAxY95pUUy4TPp2DajgCyZC++4eJ2Amo=";
  };

  # nixpkgs trails upstream's floors (filelock 3.20 vs >=3.32); no API it uses changed.
  pythonRelaxDeps = true;

  build-system = [ python3Packages.hatchling ];

  dependencies = [
    aioimaplib
  ]
  ++ (with python3Packages; [
    aiosmtplib
    anyio
    beautifulsoup4
    click
    filelock
    jinja2
    keyring
    loguru
    mcp
    pydantic
    pydantic-settings
    starlette
    tomli-w
    typer
    uvicorn
  ]);

  pythonImportsCheck = [ "mcp_email_server" ];

  meta = {
    description = "MCP server to read, search, organise and send email over IMAP/SMTP";
    homepage = "https://github.com/Wh1isper/mcp-email-server";
    mainProgram = "mcp-email-server";
  };
}
