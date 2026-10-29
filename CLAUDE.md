# ckmux

Personal, stripped-down fork of cmux (a Ghostty-based macOS terminal). Local terminals only:
the in-app browser, SSH/remote tmux, cmux Cloud, accounts, iOS/phone pairing, simulator,
Computer Use, git diff viewer, Chief, Canvas, Sentry/PostHog/Sparkle, remote feature flags,
feedback composer, menu-bar profiling, sudo broker, terminal import, herdr resume and all tests were
removed. Only English localization remains. `Packages/Shared/CMUXMobileCore` survives as a small
remnant: the terminal render-grid types (used for agent screen detection) and a no-op
`DiagnosticLog`.

## Build and run

- `scripts/dev.sh build` — incremental Debug build into `~/Library/Developer/Xcode/DerivedData/ckmux`.
- `scripts/dev.sh run` — build and launch `cmux DEV.app` with `CMUX_TAG=ckmux`
  (bundle id `com.cmuxterm.app.debug`, socket `/tmp/cmux-debug-ckmux.sock`), separate from the
  installed `/Applications/cmux.app`.
- `scripts/dev.sh cli <args>` — bundled CLI against the debug socket; `scripts/dev.sh stop` quits it.
- Opening `cmux.xcodeproj` in Xcode and pressing Run also works.
- GhosttyKit is a prebuilt xcframework symlinked at `GhosttyKit.xcframework`;
  `scripts/ensure-ghosttykit.sh` downloads the pinned build (sha in the script) when the link is
  broken. `ghostty/` holds only `include/`, `src/shell-integration/` and `build.zig.zon`; the Zig
  build is skipped (`CMUX_SKIP_ZIG_BUILD=1`).

## Layout

- `Sources/` app target, `CLI/` the `cmux` socket CLI, `Packages/{macOS,Shared}` local SwiftPM
  packages, `vendor/bonsplit` the split/tab engine, `Examples/` sidebar extension examples.
- Sidebar code lives in `Sources/Sidebar*`, `Sources/ContentView*.swift` and `Packages/macOS/CmuxSidebar`.
- Remote/cloud/browser call sites were replaced by local-only stubs rather than rewritten; see
  `Sources/Surfaces/SurfaceCatalog+Ownership.swift`, `Sources/Workspace+TitleOwnership.swift`,
  `Sources/TerminalControllerControlCommandContext.swift` and
  `Sources/TerminalController+RemoteTmuxControlTopology.swift` for the stub collections.
