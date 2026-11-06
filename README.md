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

## Local release

Builds a Release copy and installs it as `/Applications/ckmux.app`, next to (not replacing) an
upstream `cmux.app`. Needs macOS with Xcode installed; no Apple developer account.

```sh
git clone https://github.com/ckattmann/ckmux.git && cd ckmux
scripts/dev.sh release
```

What `release` does:

- downloads the pinned GhosttyKit build if the `GhosttyKit.xcframework` link is missing,
- builds the Release configuration into `~/Library/Developer/Xcode/DerivedData/ckmux`,
- signs the app ad hoc (`codesign --sign -`), quits a running `ckmux.app` and replaces it,
- writes a `~/.local/bin/ckmux` CLI shim (put `~/.local/bin` on your `PATH`).

Run the same command again to update. Quitting the app closes its terminal sessions.

The release app uses its own bundle id (`com.chka.ckmux`), socket
(`/tmp/cmux-debug-ckmux-app.sock`) and URL scheme (`ckmux://`), so its settings and sessions are
separate from the debug app and from upstream cmux. Only processes started inside ckmux can use the
socket by default; to drive it from outside (for example `ckmux prompt` from a dashboard), allow
same-user access with `defaults write com.chka.ckmux socketControlMode automation` and restart it.

Start an agent in a new workspace from anywhere:

```sh
ckmux prompt --cwd ~/code/project "fix the failing test"
open "ckmux://prompt?text=fix%20the%20failing%20test&cwd=~/code/project"
```

The URL form asks for confirmation unless it carries `token=` matching
`~/.config/ckmux/prompt-url-token`.

See `CLAUDE.md` for the layout. Licensed as upstream (`LICENSE`, `THIRD_PARTY_LICENSES.md`).
