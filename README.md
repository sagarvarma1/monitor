# Switchboard

A Liquid Glass pill for macOS that watches all your Claude Code sessions and tells you which ones need you.

- **Pill** — always on screen: one dot per session (red = blocked on you, yellow = ready for review, green = working) and the longest wait.
- **Peek** — when a session hits a permission prompt, the pill shows it with **Deny / Allow / Always** buttons. Claude Code's own prompt stays up in the terminal; whichever you answer first wins.
- **Done flash** — when a session finishes, the pill briefly says so and its dot keeps a ring until you look.
- **Reply** — send a finished session its next message from the pill without switching to the terminal.
- **Chat** — message any session from the Dashboard, with images (attach, drop or paste). It sends right away if the turn is over; otherwise it goes out when the turn ends.
- **Live terminal** — the Dashboard mirrors a session's Terminal or iTerm2 tab, or its tmux pane in any terminal, refreshed every second. tmux keeps its real colors; Terminal and iTerm2 only share plain text, so Claude Code's lines are highlighted approximately. Other terminals get the Activity view.
- **Cost estimate** — per session at API rates: by token type, model and prompt.
- **Expanded list** — hover (or click to pin) for every session, what it's doing, and how long it's been waiting. Click a row's "Go to session" to jump to its Terminal/iTerm2 tab.
- Drag the pill anywhere; it expands toward the middle of the screen. ⌥S hides it.

## Install

Requires macOS 13+ (Liquid Glass on macOS 26+).

**Download:** [Switchboard.dmg](https://github.com/sagarvarma1/monitor/releases/latest/download/Switchboard.dmg), then drag it to Applications.

**Command line:**

```sh
curl -fsSL https://raw.githubusercontent.com/sagarvarma1/monitor/main/install.sh | bash
```

**From source** (needs Xcode 26 and `brew install xcodegen`):

```sh
git clone https://github.com/sagarvarma1/monitor.git && cd monitor && ./build.sh --install
```

On first launch a welcome screen says what Switchboard will do, and nothing changes until you choose **Connect**:

- add its hooks to `~/.claude/settings.json` (backing the file up first, leaving your other hooks alone),
- optionally open at login,
- ask for notification permission.

Running Claude Code sessions pick up the hooks on their next action. Everything can be changed or undone in Settings.

## Quit or uninstall

Quit from the capsule icon in the menu bar. If the app ever stops responding it shuts itself down within three minutes; to stop it sooner, run `pkill -9 -x Switchboard` (it has no Dock icon, so the Force Quit window doesn't list it).

To uninstall, turn off the hooks in Settings, quit, and delete the app. Hooks left behind do nothing while the app isn't running.

## How it works

Claude Code [hooks](https://code.claude.com/docs/en/hooks) POST each event to the app over its Unix socket. A pure reducer (`Sources/SwitchboardCore/Reducer.swift`) turns events into per-session state, persisted in SQLite under `~/Library/Application Support/Switchboard/`. The `PermissionRequest` hook waits on the app for an answer, which is how Allow/Deny from the pill works. Sessions whose `claude` process has exited are pruned automatically.

A second, background `Stop` hook (`asyncRewake`) waits for a reply typed into the pill or the Dashboard; when one comes it exits 2 with the text, which wakes Claude with it.

## Privacy and security

- **No network.** Switchboard has no account, analytics or server of its own. Hooks reach the app through a Unix socket at `~/Library/Application Support/Switchboard/hook.sock`, not a TCP port: the folder is private to your account, and the app checks each connection's user id. Web pages and other accounts on the Mac can't reach it, and while the app is closed nothing else can stand in for it.
- **Fails closed.** If the app isn't running, hooks do nothing and Claude Code's own prompts stay in charge.
- **You see what you approve.** Permission prompts in the pill show the full request, not a summary.
- **Private data.** The session database and attachments are readable by your account only. Links in Claude's replies open only if they're web links; files that could run are shown in Finder rather than opened.
- **Asks first.** Nothing in `~/.claude/settings.json` changes until you choose Connect.
- **Verified installs.** `install.sh` checks the release's checksum, signature and notarization before installing.

Programs running as you can still talk to the socket, as they could edit your Claude Code settings directly. See [SECURITY.md](SECURITY.md) to report a problem.

## Development

```sh
swift test                     # core tests (reducer, installer, transcripts, pricing, terminal text)
xcodegen generate              # Switchboard.xcodeproj from project.yml (build.sh does this when needed)
./build.sh --run               # build and launch from build/
scripts/fake-events.sh --live  # simulate five sessions changing state
```

`scripts/release.sh` builds the universal, notarized `dist/Switchboard.dmg`; upload it and `Switchboard.dmg.sha256` to a GitHub release. `swift scripts/make-icon.swift` redraws the app icon.

`install-hooks.sh` / `uninstall-hooks.sh` do the hook setup from the command line (the app does the same thing itself).

## License

[MIT](LICENSE)
