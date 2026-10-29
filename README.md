# Switchboard

A Liquid Glass pill for macOS that watches all your Claude Code sessions and tells you which ones need you.

- **Pill** — always on screen: one dot per session (red = blocked on you, yellow = ready for review, green = working) and the longest wait.
- **Peek** — when a session hits a permission prompt, the pill shows it with **Deny / Allow / Always** buttons. Claude Code's own prompt stays up in the terminal; whichever you answer first wins.
- **Done flash** — when a session finishes, the pill briefly says so and its dot keeps a ring until you look.
- **Expanded list** — hover (or click to pin) for every session, what it's doing, and how long it's been waiting. Click a row's "Go to session" to jump to its Terminal/iTerm2 tab.
- Drag the pill anywhere; it expands toward the middle of the screen. ⌥S hides it.

## Install

Requires macOS 13+ (Liquid Glass on macOS 26+) and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh --install
```

That builds the app, copies it to `/Applications`, and launches it. On first launch Switchboard:

- adds its hooks to `~/.claude/settings.json` (backing the file up first, leaving your other hooks alone),
- adds itself to Login Items,
- asks for notification permission.

Running Claude Code sessions pick up the hooks on their next action. Both setup steps can be turned off in the pill's **⋯** menu.

## How it works

Claude Code [hooks](https://code.claude.com/docs/en/hooks) POST each event to `127.0.0.1:7777`. A pure reducer (`Sources/SwitchboardCore/Reducer.swift`) turns events into per-session state, persisted in SQLite under `~/Library/Application Support/Switchboard/`. The `PermissionRequest` hook waits on the app for an answer, which is how Allow/Deny from the pill works. Sessions whose `claude` process has exited are pruned automatically.

## Development

```sh
swift test                     # reducer, installer and parser tests
./build.sh --run               # build and launch from build/
scripts/fake-events.sh --live  # simulate five sessions changing state
```

`install-hooks.sh` / `uninstall-hooks.sh` do the hook setup from the command line (the app does the same thing itself).
