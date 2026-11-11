# Messaging: a Matrix homeserver, the bridges to every chat network, and the
# web client. Replaces Beeper.
{
  imports = [
    ./tuwunel.nix
    ./bridges.nix
    ./cinny.nix
  ];
}
