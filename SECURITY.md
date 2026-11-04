# Security

Switchboard can approve Claude Code permission prompts and send Claude messages, so it is built to make sure only
you can do either.

## How it's protected

- Hooks talk to the app over a Unix socket in a folder only your account can open (`0700`), the socket itself is
  `0600`, and the app rejects any connection whose user id isn't yours. There is no TCP port: web pages, other
  accounts on the Mac and other machines can't reach it, and no other program can take its place while it's closed.
- If the app isn't running, every hook exits without output, so Claude Code falls back to its own prompts.
- The pill shows the full tool request next to Allow, so nothing can hide past a truncated summary.
- Session data and attachments are stored `0600` under `~/Library/Application Support/Switchboard/`.
- Only `http` and `https` links in Claude's replies are clickable, and changed files that could execute are revealed
  in Finder instead of opened.
- On first launch nothing changes until you choose Connect. Settings are backed up before every edit.
- Releases are signed with a Developer ID, notarized by Apple and checked by `install.sh` before installing.

## Out of scope

Malware already running as your user can talk to the socket, read your transcripts or edit
`~/.claude/settings.json` directly, so Switchboard doesn't try to defend against it.

## Reporting a vulnerability

Please report it privately through
[GitHub's private vulnerability reporting](https://github.com/sagarvarma1/monitor/security/advisories/new)
rather than a public issue.
