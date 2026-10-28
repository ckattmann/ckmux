# ckmux

Personal, stripped-down fork of cmux (a Ghostty-based macOS terminal). Local terminals only:
the in-app browser, SSH/remote tmux, cmux Cloud, accounts, iOS/phone pairing, simulator,
Computer Use, git diff viewer, Chief, Canvas, Sentry/PostHog/Sparkle and all tests were removed.
Only English localization remains.

## Build and run

- `scripts/dev.sh build` — incremental Debug build into `~/Library/Developer/Xcode/DerivedData/ckmux`.
- `scripts/dev.sh run` — build and launch `cmux DEV.app` with `CMUX_TAG=ckmux`
  (bundle id `com.cmuxterm.app.debug`, socket `/tmp/cmux-debug-ckmux.sock`), separate from the
  installed `/Applications/cmux.app`.
- `scripts/dev.sh cli <args>` — bundled CLI against the debug socket; `scripts/dev.sh stop` quits it.
- Opening `cmux.xcodeproj` in Xcode and pressing Run also works.
- GhosttyKit is a prebuilt xcframework symlinked at `GhosttyKit.xcframework`
  (`scripts/ensure-ghosttykit.sh` downloads it); the Zig build is skipped.

## Layout

- `Sources/` app target, `CLI/` the `cmux` socket CLI, `Packages/{macOS,Shared}` local SwiftPM
  packages, `vendor/bonsplit` the split/tab engine, `Examples/` sidebar extension examples.
- Sidebar code lives in `Sources/Sidebar*`, `Sources/ContentView*.swift` and `Packages/macOS/CmuxSidebar`.
- Remote/cloud/browser call sites were replaced by local-only stubs rather than rewritten; see
  `Sources/Surfaces/SurfaceCatalog+Ownership.swift`, `Sources/Workspace+TitleOwnership.swift`,
  `Sources/TerminalControllerControlCommandContext.swift` and
  `Sources/TerminalController+RemoteTmuxControlTopology.swift` for the stub collections.
