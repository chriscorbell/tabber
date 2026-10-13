# Tabber

Tabber is an open-source (MIT) macOS app that predicts your next words in any app and shows them as ghost text at the caret. Tab accepts the next word, the key above Tab accepts the whole suggestion, and typing over it refines it. Everything runs on-device with llama.cpp and a base (pretrained, non-chat) model.

Read [docs/architecture.md](docs/architecture.md) before changing code.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/TabberCore` | Pure logic shared by everything: `FieldSnapshot`, the `Session` state machine, text rules, prompt building, settings. No AppKit. |
| `Sources/TabberEngine` | llama.cpp wrapper: model loading, prompt-cache reuse, constrained decoding. |
| `Sources/TabberAX` | Accessibility: tracking the focused field and reading its text, caret, and style. |
| `Sources/TabberInput` | Keyboard: the event tap that owns Tab while a ghost is visible, and synthetic text insertion. |
| `Sources/TabberOverlay` | The ghost-text window and the mirror fallback. |
| `Sources/TabberContext` | Extra context: on-screen text (OCR) and the clipboard. |
| `Sources/TabberApp` | The app: coordinator, menu bar, settings, onboarding, model downloads. |
| `Sources/tabber-bench` | Simulates a user typing passages to measure keystroke savings and latency. |
| `Sources/tabber-probe` | Manual live checks of the AX, input, and overlay layers. |
| `App/` | The thin app target (`main.swift`, Info.plist, entitlements, assets) built by XcodeGen from `project.yml`. |
| `bench/` | Bench passages. |

## Rules

- MIT licensed. Only bring in code whose license is compatible with MIT.
- Coordinates: every screen rect in Core/AX is in global Quartz space (top-left origin, y down), as Accessibility reports it. Only the overlay converts to AppKit space.
- Never do Accessibility IPC, model work, or disk I/O on the main thread or inside the event-tap callback. The tap must decide from in-memory state only and return immediately.
- The event tap fails open: it only swallows a key when a ready suggestion is visible and the key is bound to an action.
- Never read or keep text from secure fields. Never log typed text outside debug builds.
- Keep `TabberCore` free of AppKit so the session logic stays unit-testable.
- Swift 6 tools, Swift 5 language mode, macOS 14+.

## Build and test

```sh
swift build                    # compile everything
swift test                     # unit tests
swift build -c release --product tabber-bench
.build/release/tabber-bench simulate --model ~/Library/Application\ Support/Tabber/Models/<model>.gguf
scripts/build-app.sh           # signed Tabber.app in build/
```

## Live testing

- Run the built app's binary directly from a terminal (`build/Tabber.app/Contents/MacOS/Tabber`) so it inherits the terminal's Accessibility and Screen Recording grants; a launched-by-Finder copy needs its own grant in System Settings.
- Tabber is system-wide while it runs. Stop it as soon as a live check is done, test only in windows you created, and never type into a window you didn't open. The Mac is usually in use.
- `defaults write app.tabber.Tabber TabberDebugLog -bool YES` traces snapshots, requests, results and effects to the unified log (`log stream --predicate 'subsystem == "app.tabber"'`). Text is public in Debug builds and redacted in Release. Delete the key when done.
- Debug builds accept `-TabberOnboardingStep N`, `-TabberSettingsPane <pane>` and `-TabberOpenMenu YES` for UI work.
- Measure model or decoding changes with `tabber-bench simulate` before and after; record results in `docs/benchmarks.md`.
