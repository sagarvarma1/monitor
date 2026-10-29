# Switchboard

A Liquid Glass pill for macOS that watches all your Claude Code sessions and tells you which ones need you.

- **Pill** — always on screen: one dot per session (red = blocked on you, yellow = ready for review, green = working) and the longest wait.
- **Peek** — when a session hits a permission prompt, the pill shows it with **Deny / Allow / Always** buttons. Claude Code's own prompt stays up in the terminal; whichever you answer first wins.
- **Done flash** — when a session finishes, the pill briefly says so and its dot keeps a ring until you look.
- **Reply** — send a finished session its next message from the pill (or your phone) without switching to the terminal.
- **Expanded list** — hover (or click to pin) for every session, what it's doing, and how long it's been waiting. Click a row's "Go to session" to jump to its Terminal/iTerm2 tab.
- Drag the pill anywhere; it expands toward the middle of the screen. ⌥S hides it.

## Install

Requires macOS 13+ (Liquid Glass on macOS 26+), Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./build.sh --install
```

That builds the app (signed with your team, for iCloud), copies it to `/Applications`, and launches it. On first launch Switchboard:

- adds its hooks to `~/.claude/settings.json` (backing the file up first, leaving your other hooks alone),
- adds itself to Login Items,
- asks for notification permission.

Running Claude Code sessions pick up the hooks on their next action. Both setup steps can be turned off in the pill's **⋯** menu. Without an Apple developer team, `./build.sh --adhoc` builds the Mac app without iCloud (the iPhone features switch themselves off).

## iPhone: Live Activity

Sessions show in the Dynamic Island and on the Lock Screen, with **Deny / Allow / Always** for permission prompts and **Reply** for finished turns, from anywhere (the phone and Mac sync through your private iCloud).

1. Install the phone app: connect and unlock your iPhone, then `./build.sh --phone`.
2. Give the Mac an APNs key so it can update the Live Activity: in [Certificates, Identifiers & Profiles → Keys](https://developer.apple.com/account/resources/authkeys/list), create a key with **Apple Push Notifications service (APNs)** enabled, download `AuthKey_XXXXXXXXXX.p8`, and drop it into the folder the pill's **⋯ → Open APNs Key Folder** opens (`~/Library/Application Support/Switchboard/apns/`).
3. Open Switchboard on the phone once. From then on the Mac starts the Live Activity itself when a session needs you.

## How it works

Claude Code [hooks](https://code.claude.com/docs/en/hooks) POST each event to `127.0.0.1:7777`. A pure reducer (`Sources/SwitchboardCore/Reducer.swift`) turns events into per-session state, persisted in SQLite under `~/Library/Application Support/Switchboard/`. The `PermissionRequest` hook waits on the app for an answer, which is how Allow/Deny from the pill works. Sessions whose `claude` process has exited are pruned automatically.

A second, background `Stop` hook (`asyncRewake`) waits for a reply typed into the pill or the phone; when one comes it exits 2 with the text, which wakes Claude with it. The Mac mirrors sessions into a CloudKit zone for the phone, sends Live Activity updates over APNs, and applies the Allow/Deny/reply commands the phone writes back.

## Development

```sh
swift test                     # core tests (reducer, installer, Live Activity payloads, APNs token)
xcodegen generate              # Switchboard.xcodeproj from project.yml (build.sh does this when needed)
./build.sh --run               # build and launch from build/
scripts/fake-events.sh --live  # simulate five sessions changing state
```

`install-hooks.sh` / `uninstall-hooks.sh` do the hook setup from the command line (the app does the same thing itself).
