import AppKit
import Carbon
import Combine
import TabberAX
import TabberContext
import TabberCore
import TabberEngine
import TabberInput
import TabberOverlay
import os

/// Wires the runtime: field snapshots and key events go into the `Session`; its effects drive the
/// engine, the overlay, and text insertion.
///
/// Everything here runs on the main thread, but nothing here blocks: Accessibility reads, the event
/// tap, inference, OCR, and insertion each run on their own thread or queue.
@MainActor
final class AppCoordinator {
    private let state: AppState
    private let settings: SettingsStore
    private let models: ModelManager
    private let stats: StatsStore
    private let log = Logger(subsystem: "app.tabber", category: "coordinator")

    private let tracker = FocusTracker()
    private let keyboard = KeyboardMonitor()
    private let inserter = TextInserter()
    private let overlay = OverlayController()
    private let alternativesCard = AlternativesController()
    private var alternativesWork: DispatchWorkItem?
    /// Insert texts for the numbered alternatives on screen.
    private var shownAlternatives: [String] = []
    private let screenContext = ScreenContextProvider()
    private let clipboard = ClipboardContextProvider()
    let history = WritingHistory()
    private let typoGuard = TypoGuard()

    private var session = Session()
    private var engine: LlamaEngine?
    private var loadedModelPath: URL?
    private var loadTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var housekeeping: Timer?

    /// Context for the current field, built once per field so the prompt prefix stays stable.
    private struct FieldContext {
        var field: FieldIdentity
        var base: PromptContext
        var preamble: String
        var hasScreenText = false
        var screenAttempts = 0
        var lastScreenAttempt = Date.distantPast
    }
    private var fieldContext: FieldContext?
    private var forcedField: FieldIdentity?
    private var lastSnapshot: FieldSnapshot?
    private var interceptState = InterceptState(ghostVisible: false, acceptWord: .tab, acceptAll: .keyAboveTab, dismissWithEscape: true, hotkeys: [:])

    init(state: AppState, settings: SettingsStore, models: ModelManager, stats: StatsStore) {
        self.state = state
        self.settings = settings
        self.models = models
        self.stats = stats
    }

    // MARK: - Lifecycle

    func start() {
        tracker.onSnapshot = { [weak self] snapshot in self?.handleSnapshot(snapshot) }
        keyboard.onEvent = { [weak self] event in self?.handleKey(event) }

        settings.$settings
            .removeDuplicates()
            .sink { [weak self] _ in
                // Read the new value on the next turn, after the publisher has stored it.
                DispatchQueue.main.async { self?.settingsChanged() }
            }
            .store(in: &cancellables)
        models.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.reloadEngineIfNeeded() }
            .store(in: &cancellables)
        state.$isRecordingShortcut
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppSpecificIntercept() } }
            .store(in: &cancellables)
        state.$isOnboardingVisible
            .removeDuplicates()
            .sink { [weak self] visible in self?.tracker.configuration.includeOwnProcess = visible }
            .store(in: &cancellables)
        state.$permissions
            .removeDuplicates()
            .sink { [weak self] p in DispatchQueue.main.async { self?.permissionsChanged(p) } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name("TabberDeleteHistory"))
            .sink { [weak self] _ in self?.history.deleteAll() }
            .store(in: &cancellables)

        housekeeping = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        permissionsChanged(state.permissions)
        settingsChanged()
        reloadEngineIfNeeded()
        // Vision compiles its models on first use; do it now rather than during the first suggestion.
        if ScreenContextProvider.isPermitted, settings.settings.useScreenContext {
            Task.detached(priority: .utility) { await ScreenContextProvider.warmUp() }
        }
    }

    func stop() {
        tracker.stop()
        keyboard.stop()
        overlay.hide(animated: false)
        housekeeping?.invalidate()
        requestTask?.cancel()
        engine?.cancel()
        history.flush()
    }

    /// Shows a suggestion now, even where Tabber would normally stay quiet.
    func forceSuggestion() {
        guard let snapshot = tracker.latest ?? lastSnapshot else { return }
        forcedField = snapshot.field
        handleSnapshot(snapshot)
    }

    func reloadEngine() {
        loadedModelPath = nil
        reloadEngineIfNeeded()
    }

    private var started = false

    private func permissionsChanged(_ p: AppState.Permissions) {
        guard p.accessibility else { return }
        if !started {
            started = true
            tracker.start()
            do {
                try keyboard.start()
            } catch {
                log.error("Keyboard monitor failed to start: \(error.localizedDescription, privacy: .public)")
                started = false
            }
        }
    }

    private var lastActivity = Date()
    /// Free the model's memory after this long without typing; it reloads on the next keystroke in about a second.
    private static let idleUnload: TimeInterval = 2 * 60

    private func tick() {
        state.secureInputActive = KeyboardMonitor.isSecureInputEnabled
        if engine != nil, Date().timeIntervalSince(lastActivity) > Self.idleUnload {
            log.info("Unloading the model after a quiet period")
            engine = nil
            loadedModelPath = nil
            if let name = models.selectedModelID.map({ models.displayName(for: $0) }) { state.engineStatus = .ready("\(name), sleeping") }
        }
        // Expire pauses.
        let now = Date()
        if let until = state.pausedUntil, until <= now { state.pausedUntil = nil }
        for (id, until) in state.pausedApps where until <= now { state.pausedApps[id] = nil }
        history.flushIfNeeded()
    }

    // MARK: - Engine

    private func reloadEngineIfNeeded() {
        guard let path = models.selectedModelPath else {
            if engine == nil { state.engineStatus = .noModel }
            return
        }
        guard path != loadedModelPath else { return }
        loadedModelPath = path
        let name = models.selectedModelID.map { models.displayName(for: $0) } ?? path.deletingPathExtension().lastPathComponent
        state.engineStatus = .loading(name)
        loadTask?.cancel()
        engine?.cancel()
        let modelPath = path.path
        loadTask = Task { [weak self] in
            let result: Result<LlamaEngine, Error> = await Task.detached(priority: .userInitiated) {
                Result { try LlamaEngine(modelPath: modelPath, config: AppCoordinator.engineConfig()) }
            }.value
            guard let self, !Task.isCancelled, self.loadedModelPath?.path == modelPath else { return }
            switch result {
            case .success(let engine):
                self.engine = engine
                self.state.engineStatus = .ready(name)
                self.log.info("Loaded \(engine.info.description, privacy: .public)")
                if let snapshot = self.lastSnapshot { self.handleSnapshot(snapshot) }
            case .failure(let error):
                self.engine = nil
                self.state.engineStatus = .failed("Couldn't load \(name): \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func engineConfig() -> EngineConfig {
        var c = EngineConfig()
        c.wordStartFloor = 0.3
        return c
    }

    // MARK: - Settings

    private func settingsChanged() {
        let s = settings.settings
        interceptState.acceptWord = s.acceptWordKey
        interceptState.acceptAll = s.acceptAllKey.map(KeyboardGeometry.physical)
        interceptState.dismissWithEscape = s.escapeBehavior == .dismiss
        var hotkeys: [KeyBinding: HotkeyAction] = [:]
        if let k = s.forceActivateKey { hotkeys[KeyboardGeometry.physical(k)] = .forceActivate }
        if let k = s.pauseInAppKey { hotkeys[KeyboardGeometry.physical(k)] = .pauseInApp }
        if let k = s.toggleGloballyKey { hotkeys[KeyboardGeometry.physical(k)] = .toggleGlobally }
        interceptState.hotkeys = hotkeys
        applyAppSpecificIntercept()
        history.isRecording = s.recordWriting
        // The model choice lives in settings too.
        reloadEngineIfNeeded()
        // Context and instructions may have changed: rebuild the preamble for the current field.
        fieldContext = nil
        if let snapshot = lastSnapshot { handleSnapshot(snapshot) }
    }

    /// Tab may be turned off for the focused app; shortcut recording disables all interception.
    private func applyAppSpecificIntercept() {
        var st = interceptState
        if let bundleID = lastSnapshot?.app.bundleID, !settings.tabAccepts(in: bundleID), st.acceptWord == .tab {
            st.acceptWord = nil
        }
        if state.isRecordingShortcut {
            st.ghostVisible = false
            st.hotkeys = [:]
        }
        keyboard.update(st)
    }

    private func setGhostVisible(_ visible: Bool) {
        guard interceptState.ghostVisible != visible else { return }
        interceptState.ghostVisible = visible
        applyAppSpecificIntercept()
    }

    // MARK: - Snapshots

    private func handleSnapshot(_ snapshot: FieldSnapshot?) {
        trace("snapshot \(snapshot.map { "\($0.app.name) …\(String($0.textBeforeCaret.suffix(30)).debugDescription) sel=\($0.selectionLength)" } ?? "nil")")
        // Tabber's own windows only get suggestions in the onboarding practice field.
        var snapshot = snapshot
        if let s = snapshot, s.app.pid == ProcessInfo.processInfo.processIdentifier, !state.isOnboardingVisible {
            snapshot = nil
        }
        let fieldChanged = snapshot?.field != lastSnapshot?.field
        if let previous = lastSnapshot, fieldChanged {
            history.fieldEnded(previous)
        }
        lastSnapshot = snapshot

        if let s = snapshot {
            if state.focusedBundleID != s.app.bundleID { state.focusedBundleID = s.app.bundleID; state.focusedAppName = s.app.name }
            if state.focusedDomain != s.domain { state.focusedDomain = s.domain }
            if fieldChanged {
                forcedField = forcedField == s.field ? forcedField : nil
                applyAppSpecificIntercept()
                if wantsScreenText(s) { screenContext.prefetch(for: s) }
            }
            session.policy = policy(for: s)
            history.observe(s)
        } else {
            session.policy.enabled = false
        }
        perform(session.handle(.snapshot(snapshot)))
    }

    /// The rules for this field: settings, per-app overrides, pauses, battery.
    private func policy(for s: FieldSnapshot) -> SessionPolicy {
        let all = settings.settings
        let o = all.override(bundleID: s.app.bundleID, domain: s.domain)
        var p = SessionPolicy()
        let forced = forcedField == s.field
        p.forced = forced
        p.enabled = engine != nil
            && (forced || (settings.isEnabled(bundleID: s.app.bundleID, domain: s.domain)
                && !state.isPaused() && !state.isPaused(bundleID: s.app.bundleID)
                && !(all.onDemandOnBattery && Power.onBattery)
                // After a likely typo: offer the fix if we can, otherwise stay quiet rather than build on it.
                && (!typoGuard.suspectsTypo(before: s.textBeforeCaret) || all.autocorrect)))
        p.length = (all.shorterOnBattery && Power.onBattery && all.length != .short) ? .short : all.length
        p.allowMidLine = o.allowMidLine ?? all.allowMidLine
        p.includeTrailingSpace = all.includeTrailingSpace
        p.includeTrailingPunctuation = all.includeTrailingPunctuation
        if o.ignoreSizeThresholds == true { p.minimumSingleLineWidth = 0 }
        p.preamble = preamble(for: s, override: o)
        p.wordBias = history.wordBias(strength: all.personalization, app: s.app.bundleID, before: s.textBeforeCaret)
        return p
    }

    private func preamble(for s: FieldSnapshot, override o: AppOverride) -> String {
        if let ctx = fieldContext, ctx.field == s.field {
            // OCR answers "not yet" while its first capture runs; ask again a few times.
            if wantsScreenText(s), !ctx.hasScreenText, ctx.screenAttempts < 10, Date().timeIntervalSince(ctx.lastScreenAttempt) > 0.3 {
                loadScreenText(for: s)
            }
            return ctx.preamble
        }
        let all = settings.settings
        var instructions = all.customInstructions
        if let extra = o.instructions, !extra.isEmpty { instructions += (instructions.isEmpty ? "" : "\n") + extra }
        var context = PromptContext(
            appName: s.app.name,
            windowTitle: s.windowTitle,
            domain: s.domain,
            fieldLabel: s.label ?? s.placeholder,
            authorName: all.authorName.isEmpty ? nil : all.authorName,
            instructions: instructions.isEmpty ? nil : instructions,
            examples: history.examples(for: s)
        )
        if all.useClipboardContext, let clip = clipboard.recentText(maxAge: 180) {
            context.clipboard = SecretRedactor.redact(clip)
        }
        let text = PromptBuilder.preamble(for: context)
        trace("preamble:\n\(text)")
        fieldContext = FieldContext(field: s.field, base: context, preamble: text)
        if wantsScreenText(s) { loadScreenText(for: s) }
        return text
    }

    private func wantsScreenText(_ s: FieldSnapshot) -> Bool {
        settings.settings.useScreenContext && ScreenContextProvider.isPermitted && !s.isSecure
    }

    /// OCR runs in the background; when its text lands, the preamble is rebuilt once for the field.
    private func loadScreenText(for s: FieldSnapshot) {
        let field = s.field
        fieldContext?.screenAttempts += 1
        fieldContext?.lastScreenAttempt = Date()
        Task { [weak self] in
            guard let self else { return }
            let text = await self.screenContext.screenText(for: s)
            guard var current = self.fieldContext, current.field == field, !current.hasScreenText,
                  let text, !text.isEmpty else { return }
            var context = current.base
            context.screenText = SecretRedactor.redact(text)
            let preamble = PromptBuilder.preamble(for: context)
            self.trace("preamble with screen text:\n\(preamble)")
            current.hasScreenText = true
            current.preamble = preamble
            self.fieldContext = current
            if let snapshot = self.lastSnapshot, snapshot.field == field {
                self.session.policy.preamble = preamble
                // Warm the cache with the new prefix so the next suggestion is fast.
                if let engine = self.engine, self.requestTask == nil || self.session.pending == nil {
                    Task { await engine.prewarm(preamble: preamble, text: snapshot.textBeforeCaret) }
                }
            }
        }
    }

    // MARK: - Keys

    private func handleKey(_ event: KeyEvent) {
        lastActivity = Date()
        if case .pickAlternative(let n) = event {
            pickAlternative(n)
            return
        }
        hideAlternatives()
        if engine == nil, loadTask == nil || loadedModelPath == nil { reloadEngineIfNeeded() }
        switch event {
        case .typed(let text):
            history.typed(text)
            let predicted = (session.ghost?.expectedTextBeforeCaret ?? lastSnapshot?.textBeforeCaret ?? "") + text
            perform(session.handle(.typed(text)))
            // A typo fix or an emoji outranks whatever ghost the model showed before this key: ask again.
            if session.ghost != nil, needsSpecialSuggestion(after: predicted) {
                perform(session.handle(.editingKey))
            }
            tracker.refreshSoon()
        case .editing:
            perform(session.handle(.editingKey))
            tracker.refreshSoon()
        case .pointerDown:
            perform(session.handle(.pointerOrFocusChange))
            tracker.refreshSoon()
        case .accept(let kind):
            accept(kind, isRepeat: false)
        case .acceptRepeat:
            accept(.word, isRepeat: true)
        case .pickAlternative:
            break // handled above
        case .dismiss:
            let effects = session.handle(.dismiss)
            if effects.isEmpty, interceptState.dismissWithEscape { inserter.passThrough(.escape) }
            perform(effects)
        case .hotkey(let action):
            switch action {
            case .forceActivate:
                forceSuggestion()
            case .pauseInApp:
                guard let bundleID = lastSnapshot?.app.bundleID else { return }
                if state.isPaused(bundleID: bundleID) {
                    state.resume(bundleID: bundleID)
                } else {
                    state.pausedApps[bundleID] = Date().addingTimeInterval(10 * 60)
                    perform(session.handle(.dismiss))
                }
                if let s = lastSnapshot { handleSnapshot(s) }
            case .toggleGlobally:
                settings.settings.enabled.toggle()
            }
        }
    }

    // MARK: - Alternatives

    /// After a pause, offer the other first words the engine weighed, if the user hasn't started on this one.
    private func scheduleAlternatives(for ghost: Ghost, snapshot: FieldSnapshot) {
        alternativesWork?.cancel()
        guard settings.settings.showAlternatives, ghost.consumed == 0, ghost.replacing == 0, !ghost.alternatives.isEmpty else { return }
        let requestID = ghost.requestID
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.session.ghost, current.requestID == requestID, current.consumed == 0,
                  self.overlay.isVisible else { return }
            let partial = String(TextRules.partialWord(before: current.anchor))
            let inserts = Array(current.alternatives.prefix(3))
            let labels = inserts.map { alt -> String in
                let word = alt.first == " " ? String(alt.drop { $0 == " " }) : partial + alt
                return String(TextRules.nextChunk(of: Substring(word)))
            }
            self.shownAlternatives = inserts
            self.alternativesCard.show(labels, snapshot: snapshot)
            self.interceptState.alternativesShown = inserts.count
            self.applyAppSpecificIntercept()
        }
        alternativesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.settings.alternativesDelay, execute: work)
    }

    private func hideAlternatives() {
        alternativesWork?.cancel()
        alternativesWork = nil
        guard alternativesCard.isVisible || interceptState.alternativesShown > 0 else { return }
        alternativesCard.hide()
        shownAlternatives = []
        interceptState.alternativesShown = 0
        applyAppSpecificIntercept()
    }

    private func pickAlternative(_ n: Int) {
        let choices = shownAlternatives
        hideAlternatives()
        guard n >= 1, n <= choices.count else { return }
        // Insert just the alternative's first word; the next suggestion follows from it.
        let text = String(TextRules.nextChunk(of: Substring(choices[n - 1]), includeTrailingPunctuation: true))
        perform(session.handle(.editingKey))
        inserter.insert(text, method: insertionMethod)
        stats.recordAccepted(words: 1)
        history.accepted(text)
        tracker.refreshSoon()
    }

    private func needsSpecialSuggestion(after text: String) -> Bool {
        let all = settings.settings
        if all.emojiSuggestions, EmojiSuggester.suggestion(before: text) != nil { return true }
        return all.autocorrect && typoGuard.correction(before: text) != nil
    }

    private func accept(_ kind: AcceptKind, isRepeat: Bool) {
        let effects = session.handle(.accept(kind))
        guard effects.contains(where: { switch $0 { case .insert, .replace: return true; default: return false } }) else {
            // The ghost went away between the tap's decision and now: give the key back (never a repeat).
            if !isRepeat, let key = kind == .word ? interceptState.acceptWord : interceptState.acceptAll {
                inserter.passThrough(key)
            }
            setGhostVisible(false)
            overlay.hide(animated: false)
            return
        }
        perform(effects)
        tracker.refreshSoon()
    }

    // MARK: - Effects

    /// `defaults write app.tabber.Tabber TabberDebugLog -bool YES` logs session effects, including text. Off by default.
    private let debugLog = UserDefaults.standard.bool(forKey: "TabberDebugLog")

    private func trace(_ message: @autoclosure () -> String) {
        guard debugLog else { return }
        let m = message()
        #if DEBUG
        log.notice("\(m, privacy: .public)")
        #else
        // Release builds redact the text unless the user enables private data logging themselves.
        log.notice("\(m, privacy: .private)")
        #endif
    }

    private func perform(_ effects: [SessionEffect]) {
        if debugLog, !effects.isEmpty {
            trace("effects: " + effects.map { e -> String in
                switch e {
                case .show(let g, let s): return "show(\(g.remainder.debugDescription) caret=\(s.caret.map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)) q\($0.quality.rawValue)" } ?? "nil"))"
                case .hide: return "hide"
                case .request(let r): return "request#\(r.id)(…\(String(r.text.suffix(30)).debugDescription))"
                case .cancelRequest: return "cancel"
                case .insert(let t): return "insert(\(t.debugDescription))"
                case .replace(let n, let t): return "replace(\(n), \(t.debugDescription))"
                }
            }.joined(separator: ", "))
        }
        for effect in effects {
            switch effect {
            case .show(let ghost, let snapshot):
                overlay.show(ghost: ghost, snapshot: snapshot, appearance: appearance(for: snapshot))
                // Only own Tab when the user can actually see what it would insert.
                setGhostVisible(overlay.isVisible)
                scheduleAlternatives(for: ghost, snapshot: snapshot)
            case .hide:
                overlay.hide(animated: false)
                setGhostVisible(false)
                hideAlternatives()
            case .request(let request):
                startRequest(request)
            case .cancelRequest:
                requestTask?.cancel()
                requestTask = nil
            case .insert(let text):
                inserter.insert(text, method: insertionMethod)
                stats.recordAccepted(words: max(1, TextRules.wordCount(text)))
                history.accepted(text)
            case .replace(let count, let text):
                inserter.replace(deleting: count, with: text, method: insertionMethod)
            }
        }
    }

    private var insertionMethod: InsertionMethod {
        lastSnapshot.flatMap { settings.settings.override(bundleID: $0.app.bundleID, domain: $0.domain).insertion } ?? .keystrokes
    }

    private func appearance(for s: FieldSnapshot) -> OverlayController.Appearance {
        let all = settings.settings
        let o = all.override(bundleID: s.app.bundleID, domain: s.domain)
        var a = OverlayController.Appearance()
        a.opacity = all.ghostOpacity
        a.animate = all.animateSuggestions
        a.greyText = o.greyText ?? false
        a.fontScale = o.fontScale ?? 1
        a.verticalOffset = o.verticalOffset ?? 0
        a.forceMirror = o.forceMirror ?? false
        return a
    }

    private func startRequest(_ request: CompletionRequest, retried: Bool = false) {
        if typoGuard.suspectsTypo(before: request.text) {
            requestTask?.cancel()
            if settings.settings.autocorrect, let fix = typoGuard.correction(before: request.text) {
                perform(session.handle(.completion(CompletionResult(requestID: request.id, text: fix.text, replacing: fix.replacing))))
            } else {
                perform(session.handle(.completionFailed(requestID: request.id)))
            }
            return
        }
        if settings.settings.emojiSuggestions, let emoji = EmojiSuggester.suggestion(before: request.text) {
            requestTask?.cancel()
            perform(session.handle(.completion(CompletionResult(requestID: request.id, text: emoji.emoji, alternatives: emoji.alternatives, replacing: emoji.replacing))))
            return
        }
        guard let engine else { return }
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            do {
                let result = try await engine.complete(request, onPartial: nil)
                guard let self, !Task.isCancelled else { return }
                self.trace("result#\(result.requestID) \(result.text.debugDescription) \(result.stopReason.rawValue) \(Int(result.timings.totalMs))ms")
                self.state.lastLatencyMs = result.timings.totalMs
                self.forcedField = nil
                self.perform(self.session.handle(.completion(result)))
            } catch {
                guard let self, !Task.isCancelled else { return }
                // The engine yielded to other work (e.g. a prewarm) though this request is still wanted: ask again once.
                if case CompletionError.cancelled = error, self.session.pending?.id == request.id, !retried {
                    self.startRequest(request, retried: true)
                    return
                }
                self.perform(self.session.handle(.completionFailed(requestID: request.id)))
            }
        }
    }
}

/// Power source, refreshed lazily.
enum Power {
    private static var cached: (value: Bool, at: Date) = (false, .distantPast)

    static var onBattery: Bool {
        if Date().timeIntervalSince(cached.at) < 10 { return cached.value }
        let value = ProcessInfo.processInfo.isLowPowerModeEnabled || IOPower.isOnBattery()
        cached = (value, Date())
        return value
    }
}

/// Maps layout-independent bindings to the physical key on this keyboard.
enum KeyboardGeometry {
    /// On ISO keyboards the key above Tab (§ / ^) reports key code 10, not the ANSI grave key's 50.
    static func physical(_ binding: KeyBinding) -> KeyBinding {
        guard binding.keyCode == KeyBinding.keyAboveTab.keyCode, isISO else { return binding }
        return KeyBinding(keyCode: 10, modifiers: binding.modifiers)
    }

    static var isISO: Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    }
}
