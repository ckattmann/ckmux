# ckmux

A personal, lean fork of [cmux](https://github.com/manaflow-ai/cmux): a Ghostty-based macOS
terminal with vertical tabs and notifications for AI coding agents.

Removed from upstream: in-app browser, SSH/remote tmux, cmux Cloud, accounts/Pro, iOS app and phone
pairing, simulator, Computer Use, diff viewer, Chief, Canvas, telemetry, updater, remote feature
flags, feedback composer, menu-bar profiling, sudo/Touch ID broker, terminal-settings import, herdr
resume, tests and non-English localizations. The Ghostty source tree is reduced to the headers and
shell integration the build needs; GhosttyKit itself is a pinned prebuilt download.

```sh
scripts/dev.sh run    # build and launch the debug app
scripts/dev.sh cli workspace list
```

See `CLAUDE.md` for the layout. Licensed as upstream (`LICENSE`, `THIRD_PARTY_LICENSES.md`).
