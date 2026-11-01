# `nix fmt` formats and lints the tree; `checks.<system>.formatting` fails CI on
# any diff or finding. Rule exceptions live here and in ruff.toml, each with why.
{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;
  programs.statix = {
    enable = true;
    # `{ ... }:` is the readable module header; `_:` says nothing.
    disabled-lints = [ "empty_pattern" ];
  };
  programs.deadnix = {
    enable = true;
    # Module args like `{ config, ... }` are an interface, and a function without
    # `...` called with an argument it dropped fails to evaluate.
    no-lambda-pattern-names = true;
  };

  programs.ruff-format.enable = true;
  programs.ruff-check.enable = true;

  programs.shellcheck.enable = true;
  programs.shfmt = {
    enable = true;
    indent_size = 2;
  };

  settings.global.excludes = [
    ".entire/**"
    "docs/reviews/**"
    "*.age"
    "flake.lock"
  ];
}
