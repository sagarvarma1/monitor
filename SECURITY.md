# Security

Switchboard can approve Claude Code permission prompts and send Claude messages. This page says what it protects,
against whom, and what it doesn't try to do. No app can promise it can't be hacked; each guarantee below is backed by
code you can read and, where code can show it, a test.

## What's being protected

- **Your permission decisions.** Only you, clicking in Switchboard, can answer a prompt it holds, and what you see is
  what you approve.
- **Messages you send to a session.** They reach that session and no other.
- **Session data.** Prompts, replies and transcript summaries stay on this Mac, readable only by your account.

## Who it defends against

| Attacker | Example |
| --- | --- |
| Other accounts on the Mac | A shared or school machine |
| Web pages and other machines | A page trying to reach a local port |
| A session that's been prompt-injected | Claude reads a malicious README and runs commands that target Switchboard |
| Deceptive tool requests | A command containing invisible or right-to-left characters so it reads differently from what runs |
| Lookalike downloads | A modified DMG or app |

## Out of scope

Malware already running as your user can read your files, edit `~/.claude/settings.json` or drive your apps directly,
so Switchboard doesn't try to defend against it. A compromised Claude Code session can also do anything your account
can; Switchboard only makes sure it can't use *Switchboard* to reach other sessions or fool you into approving
something.

## Guarantees

| Guarantee | How | Test |
| --- | --- | --- |
| Nothing off this account can reach the app | Unix socket only, no TCP port; folder `0700`, socket `0600`; each connection's user id is checked (`getpeereid`) | Manual: `curl` as another user is refused |
| No other program can stand in for the app while it's closed | Without a port there's nothing to squat; if the app isn't running every hook exits silently and Claude Code shows its own prompt | — |
| A session can't impersonate another session | The pid a hook claims (`X-Claude-PID`) only counts if it really is an ancestor of the connecting process (`LOCAL_PEERPID`); a session tied to a live Claude Code process only accepts events, prompts and reply hooks from that process | `SecurityTests.testClaimedPIDMustBeAnAncestor`, `testSessionBelongsToItsLiveProcess` |
| Your reply can't be intercepted by another session | Reply hooks are subject to the same ownership check | `testSessionBelongsToItsLiveProcess` |
| What you approve is what you see | The full request is shown next to Allow, never only a summary. Control characters, terminal escapes, bidi overrides, zero-width and tag characters are shown as `␛` or `⟨U+202E⟩`, with a warning above the buttons | `testBidiOverrideIsRevealedAndCounted`, `testZeroWidthAndTagCharactersAreRevealed`, `testTerminalEscapesAndControlsAreRevealed`, `testPermissionNeedLineIsRevealed` |
| "Always" says what it will add | The exact permission rule is shown before you click; with no rule to add, the button isn't offered | `testAlwaysRuleIsDescribed`, `testAlwaysRuleRevealsHiddenCharacters` |
| A flood can't exhaust the app | At most 64 connections still sending, 256 held hooks, 32 per session; unfinished requests are dropped after 5 s; headers capped at 64 KB, bodies at 2 MB | Manual: 1,000 stalled connections, the app keeps answering |
| A payload can't point the app at arbitrary files | Transcripts are read only from `~/.claude/projects` and `~/.codex/sessions`, after resolving symlinks and `..`; only regular files are opened (no FIFOs or devices); transcripts are read in chunks with a 16 MB line cap | `testTranscriptPathsAreConfinedToAgentFolders`, `testDefaultTranscriptPathCantEscapeWithTheSessionID`, `testReducerIgnoresTranscriptPathsOutsideAgentFolders`, `testOnlyRegularFilesAreOpened` |
| Nothing from a payload reaches a shell or script | Commands run with argument arrays, never a shell. The only values put into AppleScript are ttys from the kernel, checked against `^/dev/ttys[0-9]+$`; tmux panes are checked against `^%[0-9]+$` | Code: `TerminalFocus.safeTTY`, `TerminalMirror.readTmux` |
| Parsers survive hostile input | Seeded fuzzing of the HTTP parser, hook events through the reducer, the transcript reader, the ANSI and Markdown parsers, and the permission-rule text | `FuzzTests` |
| Files Claude wrote don't run when you click them | Only documents, images and PDFs open; apps, scripts (including `.py` and `.sh`), HTML and anything executable are shown in Finder instead | Code: `FileOpener.openSafely` |
| Links in replies can't launch apps | Only `http` and `https` links are clickable | Code: `MarkdownText` |
| Hooks posing as Switchboard are noticed | A hook in `settings.json` that talks to the socket but isn't Switchboard's own is listed as a warning in Settings | `testForeignCommandsUsingTheSocketAreFound` |
| Settings changes are consented to and reversible | Nothing changes until you choose Connect; `settings.json` is backed up before every edit | `HookInstallerTests` |
| Session data is private | `0700` folder and `0600` files under `~/Library/Application Support/Switchboard/` | — |
| The app you install is the one that was built | Developer ID signature, Apple notarization, hardened runtime. `scripts/release.sh` refuses to ship if the entitlements differ from `Resources/Switchboard.entitlements` (so no `get-task-allow` or `disable-library-validation`). `install.sh` checks the SHA-256, the Team ID and Gatekeeper before copying | Release script |

## Reporting a vulnerability

Please report it privately through
[GitHub's private vulnerability reporting](https://github.com/sagarvarma1/monitor/security/advisories/new)
rather than a public issue. Include what an attacker needs (another account, a malicious repo, a web page) and
what they get.
