{ pkgs, username, ... }:
# Mail tooling for rpi5: himalaya CLI talking to the local hydroxide ProtonMail
# bridge. Co-located with the picoclaw `protonmail` skill that consumes it.
#
# Bridge endpoints + group access are configured in rpi5/hydroxide.nix:
#   - IMAP 127.0.0.1:1143, SMTP 127.0.0.1:1025 (also exposed on tailscale0)
#   - ${username} is a member of the `hydroxide` group → 0440 read on
#     /run/agenix/protonmail-bridge-password.
let
  protonAddress = "${username}@protonmail.com";
in
{
  home.packages = [ pkgs.himalaya ];

  home.file.".config/himalaya/config.toml".text = ''
    [accounts.proton]
    default = true
    email = "${protonAddress}"
    display-name = "Nicolas Simon"

    backend.type = "imap"
    backend.host = "127.0.0.1"
    backend.port = 1143
    backend.encryption.type = "none"
    backend.login = "${protonAddress}"
    backend.auth.type = "password"
    backend.auth.cmd = "cat /run/agenix/protonmail-bridge-password"

    message.send.backend.type = "smtp"
    message.send.backend.host = "127.0.0.1"
    message.send.backend.port = 1025
    message.send.backend.encryption.type = "none"
    message.send.backend.login = "${protonAddress}"
    message.send.backend.auth.type = "password"
    message.send.backend.auth.cmd = "cat /run/agenix/protonmail-bridge-password"

    folder.aliases.inbox = "INBOX"
    folder.aliases.sent = "Sent"
    folder.aliases.trash = "Trash"
    folder.aliases.drafts = "Drafts"
  '';
}
