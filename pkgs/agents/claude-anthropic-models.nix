# The list of Claude model IDs, extracted from the claude-code binary at build
# time and emitted as a JSON array.
#
# Anthropic's /v1/models rejects OAuth tokens, so the model list can't be
# queried — see the aperture-oauth-models known issue. claude-code 2.1.x ships
# as a single wrapped binary at bin/.claude-wrapped; earlier versions exposed
# the JS at lib/node_modules/.../cli.js. Bumping claude-code auto-updates the
# list; if extraction ever breaks, the count guard in jq fails the build rather
# than silently emitting an empty list.
#
# Consumer: hosts/rpi5/aperture-sync.nix (the Anthropic passthrough provider).
{
  runCommand,
  gnugrep,
  gnused,
  jq,
  claude-code,
}:

runCommand "claude-anthropic-models.json" { } ''
  ${gnugrep}/bin/grep -aoE '"claude-(opus|sonnet|haiku|fable|mythos)-[a-z0-9-]+"' \
    ${claude-code}/bin/.claude-wrapped \
    | ${gnused}/bin/sed 's/"//g; /-$/d' \
    | sort -u \
    | ${jq}/bin/jq -R . \
    | ${jq}/bin/jq -s 'if length < 5 then error("aperture-sync: only \(length) claude models extracted, expected >=5") else . end' \
    > $out
''
