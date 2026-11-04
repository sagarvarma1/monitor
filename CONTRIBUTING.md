# Contributing

Thanks for helping. Switchboard is small on purpose; please keep changes focused.

## Setup

Needs macOS 13+, Xcode 26 and `brew install xcodegen`.

```sh
swift test                     # core tests
./build.sh --run               # build and launch from build/
scripts/fake-events.sh --live  # simulate sessions without running Claude Code
```

Run against a scratch database so your real sessions and `~/.claude/settings.json` are left alone:
`SWITCHBOARD_DB=/tmp/sb.db SWITCHBOARD_SOCKET=/tmp/sb.sock build/Switchboard.app/Contents/MacOS/Switchboard`.

## Guidelines

- State logic belongs in `SwitchboardCore` (pure, tested); the app target is UI and system glue.
- Add a test for every reducer, installer or parser change.
- No third-party dependencies without discussing it in an issue first.
- Nothing from a hook payload may reach a shell, AppleScript or URL without validation.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.
