# mail-mcp — Hermes' only mail tool: mcp-email-server over Proton (hydroxide,
# loopback) and Gmail (IMAP + app password). Replaces himalaya, gog and the
# protonmail skill.
#
# The server only takes passwords inline in its TOML, so the config is rendered
# per launch into an owner-only runtime dir and never lands in the store. Gmail
# is skipped while its app password is absent, so Proton keeps working.
{
  pkgs,
  mcp-email-server,
}:
pkgs.writeShellApplication {
  name = "mail-mcp";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    proton_pass=/run/agenix/protonmail-bridge-password
    gmail_pass=/run/agenix/gmail-app-password

    dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mail-mcp"
    umask 077
    mkdir -p "$dir"

    # TOML literal strings ('…') cannot hold a quote or a newline.
    literal() {
      local v
      v=$(cat "$1")
      case "$v" in
        *"'"* | *$'\n'*)
          echo "mail-mcp: $1 is not TOML-literal-safe" >&2
          exit 1
          ;;
      esac
      printf "'%s'" "$v"
    }

    # Assigned first: a failing $(…) inside echo's arguments would not stop the script.
    proton=$(literal "$proton_pass")
    gmail=""
    if [ -r "$gmail_pass" ]; then gmail=$(literal "$gmail_pass"); fi

    tmp=$(mktemp "$dir/config.XXXXXX")
    {
      # Sending is granted here but gated in Hermes: send_email/forward_email are
      # only exposed by the `mail-send` server, which asks on Telegram per call.
      cat <<'EOF'
    credential_storage = "plaintext"
    allowed_recipients = ["*"]
    allowed_mutations = ["draft", "organize", "send"]

    [[emails]]
    account_name = "proton"
    description = "Personal mail (nsimon@protonmail.com, @pm.me) via the hydroxide bridge"
    full_name = "Nicolas Simon"
    email_address = "nsimon@protonmail.com"
    # Proton files sent mail itself; an IMAP append would duplicate it.
    save_to_sent = false

    [emails.incoming]
    user_name = "nsimon@protonmail.com"
    host = "127.0.0.1"
    port = 1143
    use_ssl = false
    start_ssl = false
    verify_ssl = false
    EOF
      echo "password = $proton"
      cat <<'EOF'

    [emails.outgoing]
    user_name = "nsimon@protonmail.com"
    host = "127.0.0.1"
    port = 1025
    use_ssl = false
    start_ssl = false
    verify_ssl = false
    EOF
      echo "password = $proton"

      if [ -n "$gmail" ]; then
        cat <<'EOF'

    [[emails]]
    account_name = "gmail"
    description = "Personal Gmail (hemeraude@gmail.com)"
    email_address = "hemeraude@gmail.com"
    # Gmail's SMTP files sent mail itself.
    save_to_sent = false

    [emails.incoming]
    user_name = "hemeraude@gmail.com"
    host = "imap.gmail.com"
    port = 993
    use_ssl = true
    start_ssl = false
    verify_ssl = true
    EOF
        echo "password = $gmail"
        cat <<'EOF'

    [emails.outgoing]
    user_name = "hemeraude@gmail.com"
    host = "smtp.gmail.com"
    port = 465
    use_ssl = true
    start_ssl = false
    verify_ssl = true
    EOF
        echo "password = $gmail"
      fi
    } >"$tmp"
    mv -f "$tmp" "$dir/config.toml"

    export MCP_EMAIL_SERVER_CONFIG_PATH="$dir/config.toml"
    exec ${mcp-email-server}/bin/mcp-email-server stdio
  '';
}
