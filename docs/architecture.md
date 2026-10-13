# Architecture

## Runtime flow

```
 keyboard ──► TabberInput.KeyboardMonitor (event tap, own thread)
                 │  typed / editing / accept / dismiss / hotkey events
                 ▼
 AX notifications & polls ──► TabberAX.FocusTracker (own thread) ──► FieldSnapshot
                 │                                                    │
                 ▼                                                    ▼
            TabberApp.AppCoordinator (main thread) ── owns ── TabberCore.Session
                 │        ▲                                   (pure state machine)
   effects:      │        │ completion results
   request ──────┼──► TabberEngine.LlamaEngine (own queue)
   show/hide ────┼──► TabberOverlay.OverlayController (main thread)
   insert ───────┴──► TabberInput.TextInserter (own queue)
                          ▲
 TabberContext (OCR, clipboard) ──► PromptBuilder preamble
```

1. The event tap sees every keyDown before the app does. It never blocks: it reads an `InterceptState` snapshot (is a ghost visible, which keys accept) and either swallows an accept/dismiss key or lets everything through. It reports what happened to the coordinator asynchronously.
2. Typed characters advance the ghost immediately when they match it ("type-through"), so no model call is needed.
3. After any key, the focus tracker re-reads the field until the app has published the change. Each read produces a `FieldSnapshot`.
4. `Session` turns snapshots and key events into effects: request a completion, show or hide the ghost, insert text.
5. The engine continues the text before the caret with a base model. It reuses the prompt cache across keystrokes and imposes the partially typed word as a byte constraint (token healing).
6. The overlay draws the remainder of the ghost at the caret in the app's font and a translucent shade of its text color, or in a mirror card when the caret position is unknown.

## Module contracts

These are the public APIs the coordinator relies on. Modules may add more, but keep these stable.

### TabberCore

Shared value types: `FieldSnapshot`, `CaretGeometry`, `TextStyle`, `AppIdentity`, `FieldIdentity`, `Ghost`, `Session`, `SessionEvent`, `SessionEffect`, `SessionPolicy`, `CompletionRequest`, `CompletionResult`, `CompletionEngine`, `TextRules`, `PromptBuilder`, `PromptContext`, `TabberSettings`, `AppOverride`, `KeyBinding`, `InsertionMethod`.

### TabberAX

```swift
public enum AXPermission {
    public static var isTrusted: Bool { get }
    public static func requestTrust()          // shows the system prompt
}

public final class FocusTracker: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var textWindowBefore: Int       // UTF-16 units read before the caret (default 4000)
        public var textWindowAfter: Int        // after the caret (default 1000)
        public var idlePollInterval: TimeInterval
        public var excludedBundleIDs: Set<String>
    }
    public init(configuration: Configuration = .init())
    /// Called on the main queue with every new read, or nil when no editable text field is focused.
    public var onSnapshot: (@MainActor (FieldSnapshot?) -> Void)?
    public func start()
    public func stop()
    /// Re-read soon: at short intervals until the field's text or caret changes, or a deadline passes.
    public func refreshSoon()
    public var latest: FieldSnapshot? { get }  // thread-safe
}
```

### TabberInput

```swift
public enum HotkeyAction: Sendable, Hashable { case forceActivate, pauseInApp, toggleGlobally }

public struct InterceptState: Sendable, Equatable {
    public var ghostVisible: Bool
    public var acceptWord: KeyBinding?
    public var acceptAll: KeyBinding?
    public var dismissWithEscape: Bool
    public var hotkeys: [KeyBinding: HotkeyAction]   // always active
}

public enum KeyEvent: Sendable, Equatable {
    case typed(String)          // printable text the user typed (passed through to the app)
    case editing                // backspace, delete, return, arrows, navigation, Cmd shortcuts...
    case accept(AcceptKind)     // swallowed accept key
    case dismiss                // swallowed Esc
    case hotkey(HotkeyAction)   // swallowed hotkey
    case pointerDown            // any mouse click
}

public final class KeyboardMonitor: @unchecked Sendable {
    public init()
    public var onEvent: (@MainActor (KeyEvent) -> Void)?
    public func start() throws
    public func stop()
    public func update(_ state: InterceptState)        // cheap, thread-safe
    public static var isSecureInputEnabled: Bool { get }
}

public final class TextInserter: @unchecked Sendable {
    public init()
    public func insert(_ text: String, method: InsertionMethod)   // async on its own queue, in order
    public func passThroughTab()                                  // send a real Tab to the app
}
```

### TabberOverlay

```swift
@MainActor public final class OverlayController {
    public struct Appearance: Equatable {
        public var opacity: Double         // of the host text color, default 0.5
        public var greyText: Bool
        public var fontScale: Double       // 1 = as reported
        public var verticalOffset: Double  // points
        public var animate: Bool
        public var forceMirror: Bool
    }
    public init()
    /// Draws `ghost.remainder` at the caret described by `snapshot`. When the snapshot lags behind the
    /// ghost (the user typed through faster than the app published), the drawing is shifted by the
    /// width of the characters already consumed.
    public func show(ghost: Ghost, snapshot: FieldSnapshot, appearance: Appearance)
    public func hide(animated: Bool)
    public var isVisible: Bool { get }
}
```

### TabberContext

```swift
public final class ScreenContextProvider: @unchecked Sendable {
    public init()
    public static var isPermitted: Bool { get }
    /// Recognized text near the field (mostly above it), cached per window for a few seconds.
    public func screenText(for snapshot: FieldSnapshot) async -> String?
}

public final class ClipboardContextProvider: @unchecked Sendable {
    public init()
    /// Text copied recently (within `maxAge`), skipping concealed and transient items.
    public func recentText(maxAge: TimeInterval) -> String?
}
```

### TabberApp

`TabberAppMain.run()` starts the app. `AppCoordinator` wires the modules. `SettingsStore` persists `TabberSettings`. `ModelManager` lists, downloads, and selects models. `Updater` wraps Sparkle: it checks the appcast published with each GitHub release, prompts, and installs signed updates. UI: menu bar item, settings window, onboarding.

## Engine details

`TabberEngine.LlamaEngine` owns one llama.cpp context (n_ctx 4096, batch 512, all layers on Metal, `swa_full` so sliding-window caches can be trimmed, `kv_unified` so beam branches share the prompt's cells) and a private serial queue.

**Prompt.** `PromptBuilder` renders a short document header: labelled facts (app, website, window, field, author), the user's notes, earlier writing by the same author, text recognized on screen, and recently copied text, each quoted, then `Text being written:` and an opening quote. The user's text follows and the prompt ends exactly at the caret. The header is built once per field, so it stays byte-identical while the user types and the cache stays valid.

**Token healing.** The partially typed word (plus the space before it), trailing spaces, or a trailing punctuation mark are cut from the prompt and kept as *required bytes*. Generation must reproduce them: at each step only tokens consistent with the remaining required bytes are allowed, found with a sorted byte table (tokens that start with the bytes) and a hash map (tokens that are a prefix of them). This lets the model choose natural tokens such as ` jumps` when the user typed ` jum`.

**Cache reuse.** The context keeps the token sequence it holds. A new prompt is compared token by token; the cache is trimmed to the common prefix and only the rest is evaluated. Long texts are cut at a remembered anchor so the start of the window doesn't slide with every keystroke. Recurrent and hybrid models (Qwen3.5) can't be trimmed, so they re-evaluate and run greedy.

**First word: beam search.** Up to three branches advance in one batched decode, each on its own sequence (`llama_memory_seq_cp`). Branches whose next token is less than 5% likely are dropped. A branch that has started a word may *finish* it: its score is the log-probability of its tokens plus the log of the probability mass of every token that starts a new word, ends the line, or ends the text. The search stops when no open branch can beat the best finished word. The winner's tokens are then re-decoded into sequence 0 so the cache stays canonical, and the other finished words become alternatives.

**Rest: greedy with cut-offs.** From the winner, greedy decoding adds words until the length limit (2–4 words by default), a sentence end (not after abbreviations or initials), a line break, the end of text, or a word whose first token is less than 30% likely. A suggestion that repeats recent text is dropped; mid-line suggestions are trimmed where they would run into the text after the caret.

**Personalization.** With "learn my writing" on, `WritingHistory` keeps an AES-GCM-encrypted record of fields where the user accepted suggestions. Frequent personal words get a small capped logit bias on their first token, and the two most recent passages from the same app go into the header as examples.
