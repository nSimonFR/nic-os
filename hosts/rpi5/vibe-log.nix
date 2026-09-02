# vibe-log — the coding-productivity report, served as a static page.
#
# There is NO process here, and no package. vibe-log-cli analyses the Claude
# Code transcripts under ~/.claude/projects and emits one self-contained HTML
# file; this module only makes the result reachable. Generation stays a manual
# step on purpose:
#
#   - the CLI is `npx --yes vibe-log-cli@latest` — unpinned, fetched from the
#     network at run time, which is the opposite of what this tree does with
#     every other dependency;
#   - it gates every action behind an inquirer menu and IGNORES its own flags
#     (`privacy --export <path>` still prompts), so it cannot be driven from a
#     systemd unit at all. Driving it needs a pty puppet answering the menu —
#     see ~/vibe-log-eval/{run.sh,drive.py}, which also documents the
#     environment scrub the child needs (CLAUDECODE et al must be unset, but
#     ANTHROPIC_BASE_URL and CLAUDE_CONFIG_DIR must NOT be);
#   - one run spawns 7 parallel analyser sub-agents through tiny-llm-gate. On a
#     3.9 GiB box that is not something to put on a timer.
#
# So: regenerate by hand, then drop the HTML in as index.html:
#   install -m444 vibe-log-report-<date>.html /var/lib/vibe-log/report/index.html
#
# `backend` is a FILESYSTEM PATH, not the usual http://127.0.0.1:port. Every
# other public entry forwards to a listening service; `tailscale serve <dir>`
# serves static files directly, so a page with no process behind it needs no
# port, no nginx vhost and no socket-activation proxy. tailscaled runs as root,
# which is why the directory only has to be world-readable, not owned by it.
{ ... }:
{
  # 0755 and owned by nsimon: the report is written by hand (or by an agent
  # running as nsimon), and read by tailscaled as root. `d` rather than `D` so a
  # rebuild never wipes a report that took ten minutes of model time to make.
  systemd.tmpfiles.rules = [
    "d /var/lib/vibe-log        0755 nsimon users - -"
    "d /var/lib/vibe-log/report 0755 nsimon users - -"
  ];

  nic.services.vibe-log = {
    # Nothing to dump: the report is derived from ~/.claude/projects, and is
    # cheaper to regenerate than to restore. The transcripts it is derived from
    # are a separate question and not this module's to answer.
    backup = [ "none" ];
    backupNote =
      "a generated HTML report — regenerate it with vibe-log-cli rather than "
      + "restoring it. Holds no state of its own.";

    public = {
      # 240 completes the short last row of the Apps grid (210–230 was Forgejo,
      # Gramps Web, ShowMyCards — three tiles in a four-column layout), so this
      # is the one case where appending does not need the row renumbered.
      order = 240;

      # 3980, next in the 39xx tailnet run after freereps (3960) and searxng
      # (3970). The eval served this on an ad-hoc `tailscale serve --https=8395`,
      # which is off-scheme and — being imperative — was wiped by the next
      # tailscale-serve.service run, since that unit does `serve reset` first.
      # Declaring it here is what makes the route survive a rebuild.
      port = 3980;
      backend = "/var/lib/vibe-log/report";

      tile = {
        name = "vibe-log";
        icon = "mdi-chart-timeline-variant";
        category = "Apps";
        description = "Coding productivity report";
      };
    };
  };
}
