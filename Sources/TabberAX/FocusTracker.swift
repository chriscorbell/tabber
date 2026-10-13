import AppKit
import ApplicationServices
import TabberCore

/// Follows the focused text field in whatever app is frontmost and publishes a `FieldSnapshot` on every change.
///
/// All Accessibility work happens on a dedicated thread with its own run loop. Snapshots arrive on the main queue.
/// Changes are picked up three ways, because no single one is reliable across apps: AXObserver notifications,
/// a short burst of reads after each keystroke (`refreshSoon()`), and a slow idle poll.
public final class FocusTracker: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        /// UTF-16 units read before the caret.
        public var textWindowBefore: Int
        /// UTF-16 units read after the caret.
        public var textWindowAfter: Int
        /// Base interval of the idle poll. It backs off to 4x while nothing changes.
        public var idlePollInterval: TimeInterval
        public var excludedBundleIDs: Set<String>
        /// Read fields in Tabber's own windows too (the onboarding practice field).
        public var includeOwnProcess = false

        public init(
            textWindowBefore: Int = 4000,
            textWindowAfter: Int = 1000,
            idlePollInterval: TimeInterval = 0.5,
            excludedBundleIDs: Set<String> = []
        ) {
            self.textWindowBefore = textWindowBefore
            self.textWindowAfter = textWindowAfter
            self.idlePollInterval = idlePollInterval
            self.excludedBundleIDs = excludedBundleIDs
        }
    }

    /// Per-message AX timeout, so a hung app costs at most this per call.
    static let messagingTimeout: Float = 0.08

    private let lock = NSLock()
    private var _onSnapshot: (@MainActor (FieldSnapshot?) -> Void)?
    private var _latest: FieldSnapshot?
    private var _configuration: Configuration
    private var started = false
    private var workspaceTokens: [NSObjectProtocol] = []

    private let thread = AXThread(name: "app.tabber.ax")
    private let core: TrackerCore

    public init(configuration: Configuration = .init()) {
        _configuration = configuration
        core = TrackerCore(thread: thread, configuration: configuration)
        core.owner = self
    }

    deinit {
        let tokens = workspaceTokens
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        let core = self.core
        let thread = self.thread
        thread.perform {
            core.stop()
            thread.stop()
        }
    }

    /// Called on the main queue with every new read, or nil when no editable text field is focused.
    public var onSnapshot: (@MainActor (FieldSnapshot?) -> Void)? {
        get { lock.withLock { _onSnapshot } }
        set { lock.withLock { _onSnapshot = newValue } }
    }

    /// The most recent read. Thread-safe.
    public var latest: FieldSnapshot? {
        lock.withLock { _latest }
    }

    public var configuration: Configuration {
        get { lock.withLock { _configuration } }
        set {
            lock.withLock { _configuration = newValue }
            let core = self.core
            thread.perform { core.update(configuration: newValue) }
        }
    }

    public func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        let begin = { [weak self] in
            // stop() may have run before this block got to the main thread.
            guard let self, self.lock.withLock({ self.started && self.workspaceTokens.isEmpty }) else { return }
            let center = NSWorkspace.shared.notificationCenter
            let core = self.core
            let thread = self.thread
            let activated = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let front = FrontApp(app)
                thread.perform { core.activated(front) }
            }
            let terminated = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                thread.perform { core.terminated(pid: pid) }
            }
            self.lock.withLock { self.workspaceTokens = [activated, terminated] }
            let front = NSWorkspace.shared.frontmostApplication.map(FrontApp.init)
            thread.perform { core.start(frontmost: front) }
        }
        // The frontmost app is read on the main thread; AX work then moves to the AX thread.
        if Thread.isMainThread { begin() } else { DispatchQueue.main.async(execute: begin) }
    }

    public func stop() {
        let tokens = lock.withLock { () -> [NSObjectProtocol]? in
            guard started else { return nil }
            started = false
            _latest = nil
            defer { workspaceTokens = [] }
            return workspaceTokens
        }
        guard let tokens else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        let core = self.core
        thread.perform { core.stop() }
    }

    /// Re-read soon: at short intervals until the field's text or caret changes, or a deadline passes.
    public func refreshSoon() {
        let baseline = TextState(latest)
        let core = self.core
        thread.perform { core.refreshSoon(baseline: baseline) }
    }

    // MARK: - From the AX thread

    fileprivate func store(_ snapshot: FieldSnapshot?) {
        lock.withLock { if started { _latest = snapshot } }
    }

    fileprivate func deliver(_ snapshot: FieldSnapshot?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let (callback, isStarted) = self.lock.withLock { (self._onSnapshot, self.started) }
            guard isStarted, let callback else { return }
            MainActor.assumeIsolated { callback(snapshot) }
        }
    }
}

/// What the tracker needs to know about an app, read from NSRunningApplication on the main thread.
struct FrontApp: Sendable {
    var pid: pid_t
    var bundleID: String?
    var bundleURL: URL?

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        bundleURL = app.bundleURL
    }
}

/// The parts of a snapshot that a keystroke changes. Used to end a refresh burst early.
struct TextState: Equatable, Sendable {
    var field: FieldIdentity?
    var before: String
    var after: String
    var caretOffset: Int?
    var selectionLength: Int

    init(_ snapshot: FieldSnapshot?) {
        field = snapshot?.field
        before = snapshot?.textBeforeCaret ?? ""
        after = snapshot?.textAfterCaret ?? ""
        caretOffset = snapshot?.caretOffset
        selectionLength = snapshot?.selectionLength ?? 0
    }
}

enum SnapshotComparison {
    /// Equal in every field except `capturedAt`.
    static func sameExceptTimestamp(_ a: FieldSnapshot?, _ b: FieldSnapshot?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            var b = b
            b.capturedAt = a.capturedAt
            return a == b
        default: return false
        }
    }
}

// MARK: - AX-thread state

/// Everything the tracker does on the AX thread. Confined to that thread; never touched elsewhere.
final class TrackerCore {
    weak var owner: FocusTracker?

    static let refreshOffsets: [TimeInterval] = [0.008, 0.025, 0.060, 0.120, 0.250]
    /// Reads that fail in a row before the field counts as gone.
    static let failureLimit = 4

    private let thread: AXThread
    private let reader: FieldReader
    private let enabler: WebAccessibilityEnabler
    private var configuration: FocusTracker.Configuration
    private var running = false

    private var frontmost: FrontApp?
    private var appObservation: AppObservation?
    private var fieldObservation: FieldObservation?
    private var registrationAttempts: [pid_t: Int] = [:]

    private var readQueued = false
    private var hasPublished = false
    private var published: FieldSnapshot?
    private var failures = 0

    private var burst: Burst?
    private lazy var burstTimer = thread.makeTimer { [unowned self] in burstFired() }
    private lazy var pollTimer = thread.makeTimer { [unowned self] in pollFired() }
    private lazy var webCheckTimer = thread.makeTimer { [unowned self] in webCheckFired() }
    private var webCheck: (pid: pid_t, start: CFAbsoluteTime, step: Int)?
    /// After activating a Chromium or Electron app, check its accessibility flag again at these offsets: other
    /// tools reset it right after activation.
    static let webCheckOffsets: [TimeInterval] = [0.35, 1.5]
    private var pollInterval: TimeInterval

    private struct AppObservation {
        var pid: pid_t
        var observer: AXObserver
        var element: AXUIElement
        var registered: [String]
    }

    private struct FieldObservation {
        var pid: pid_t
        var element: AXUIElement
        var observer: AXObserver
        /// False when it shares the app observation's observer.
        var ownsObserver: Bool
        var registered: [String]
    }

    private struct Burst {
        var start: CFAbsoluteTime
        var step: Int
        var baseline: TextState
    }

    init(thread: AXThread, configuration: FocusTracker.Configuration) {
        self.thread = thread
        self.configuration = Self.sanitized(configuration)
        self.reader = FieldReader(configuration: self.configuration)
        self.enabler = WebAccessibilityEnabler(client: reader.client)
        self.pollInterval = self.configuration.idlePollInterval
    }

    /// A zero poll interval would spin the AX thread.
    private static func sanitized(_ configuration: FocusTracker.Configuration) -> FocusTracker.Configuration {
        var result = configuration
        result.idlePollInterval = max(0.1, configuration.idlePollInterval.isFinite ? configuration.idlePollInterval : 0.5)
        result.textWindowBefore = max(0, configuration.textWindowBefore)
        result.textWindowAfter = max(0, configuration.textWindowAfter)
        return result
    }

    // MARK: Lifecycle

    func start(frontmost front: FrontApp?) {
        guard !running else { return }
        running = true
        failures = 0
        hasPublished = false
        published = nil
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), FocusTracker.messagingTimeout)
        if let front {
            activated(front)
        } else {
            schedulePoll(after: configuration.idlePollInterval)
            requestRead()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        burst = nil
        webCheck = nil
        thread.cancel(burstTimer)
        thread.cancel(pollTimer)
        thread.cancel(webCheckTimer)
        stopObservingField()
        stopObservingApp()
        hasPublished = false
        published = nil
    }

    func update(configuration: FocusTracker.Configuration) {
        self.configuration = Self.sanitized(configuration)
        reader.configuration = self.configuration
        pollInterval = self.configuration.idlePollInterval
        guard running else { return }
        schedulePoll(after: pollInterval)
        requestRead()
    }

    func activated(_ app: FrontApp) {
        frontmost = app
        guard running else { return }
        let kind = enabler.prepare(
            pid: app.pid, bundleID: app.bundleID, bundleURL: app.bundleURL, appElement: reader.appElement(app.pid)
        )
        if kind != .other {
            webCheck = (app.pid, CFAbsoluteTimeGetCurrent(), 0)
            thread.schedule(webCheckTimer, after: Self.webCheckOffsets[0])
        } else {
            webCheck = nil
            thread.cancel(webCheckTimer)
        }
        registrationAttempts[app.pid] = 0
        observeApp(pid: app.pid)
        pollInterval = configuration.idlePollInterval
        schedulePoll(after: pollInterval)
        // Freshly activated apps (and Chromium building its tree) settle over the next few hundred ms.
        startBurst(baseline: TextState(published))
        requestRead()
    }

    func terminated(pid: pid_t) {
        reader.forget(pid: pid)
        enabler.forget(pid: pid)
        registrationAttempts[pid] = nil
        if fieldObservation?.pid == pid { stopObservingField() }
        if appObservation?.pid == pid { stopObservingApp() }
        if frontmost?.pid == pid { frontmost = nil }
    }

    // MARK: Reads

    func refreshSoon(baseline: TextState) {
        guard running else { return }
        startBurst(baseline: baseline)
    }

    private func startBurst(baseline: TextState) {
        burst = Burst(start: CFAbsoluteTimeGetCurrent(), step: 0, baseline: baseline)
        thread.schedule(burstTimer, after: Self.refreshOffsets[0])
    }

    private func burstFired() {
        guard running, burst != nil else { return }
        if !readQueued { performRead() }
        // The read may have ended the burst.
        guard var current = burst else { return }
        current.step += 1
        guard current.step < Self.refreshOffsets.count else {
            burst = nil
            return
        }
        burst = current
        let due = current.start + Self.refreshOffsets[current.step]
        thread.schedule(burstTimer, after: due - CFAbsoluteTimeGetCurrent())
    }

    private func pollFired() {
        guard running else { return }
        retryAppObservationIfNeeded()
        let changed = readQueued ? false : performRead()
        let base = configuration.idlePollInterval
        pollInterval = changed ? base : min(pollInterval * 1.5, base * 4)
        schedulePoll(after: pollInterval)
    }

    private func webCheckFired() {
        guard running, var check = webCheck, check.pid == frontmost?.pid else { return }
        enabler.ensureEnabled(pid: check.pid, minimumInterval: 0)
        check.step += 1
        guard check.step < Self.webCheckOffsets.count else {
            webCheck = nil
            return
        }
        webCheck = check
        thread.schedule(webCheckTimer, after: check.start + Self.webCheckOffsets[check.step] - CFAbsoluteTimeGetCurrent())
    }

    /// A web app that can't place its caret (or shows no field) may have lost its accessibility flag.
    private func checkWebAccessibility(after snapshot: FieldSnapshot?) {
        let pid = snapshot?.app.pid ?? frontmost?.pid
        guard let pid, enabler.kind(of: pid) != .other else { return }
        if let caret = snapshot?.caret, caret.quality > .estimated { return }
        enabler.ensureEnabled(pid: pid, minimumInterval: 2)
    }

    private func schedulePoll(after delay: TimeInterval) {
        thread.schedule(pollTimer, after: delay)
    }

    /// Queues one read. Further requests while it is pending are dropped, since that read will see their changes.
    private func requestRead() {
        guard running, !readQueued else { return }
        readQueued = true
        thread.perform { [self] in
            readQueued = false
            performRead()
        }
    }

    /// Reads now and publishes. Returns true when the published snapshot changed.
    @discardableResult
    private func performRead() -> Bool {
        guard running else { return false }
        reader.frontmostPID = frontmost?.pid
        let snapshot: FieldSnapshot?
        switch reader.read() {
        case .failed:
            failures += 1
            guard failures >= Self.failureLimit else { return false }
            snapshot = nil
            observeField(nil)
        case .noField:
            failures = 0
            snapshot = nil
            observeField(nil)
        case .field(let field):
            failures = 0
            snapshot = field
            observeField(reader.lastElement)
        }

        checkWebAccessibility(after: snapshot)

        if let current = burst, TextState(snapshot) != current.baseline {
            burst = nil
            thread.cancel(burstTimer)
        }

        owner?.store(snapshot)
        if hasPublished, SnapshotComparison.sameExceptTimestamp(published, snapshot) { return false }
        hasPublished = true
        published = snapshot
        owner?.deliver(snapshot)

        // Activity: poll at the base rate again, and soon.
        let base = configuration.idlePollInterval
        if pollInterval > base {
            pollInterval = base
            if CFRunLoopTimerGetNextFireDate(pollTimer) > CFAbsoluteTimeGetCurrent() + base { schedulePoll(after: base) }
        }
        return true
    }

    // MARK: Observers

    private func handle(notification: String, element: AXUIElement) {
        guard running else { return }
        if notification == AXName.elementDestroyed, let field = fieldObservation, CFEqual(field.element, element) {
            stopObservingField()
        }
        requestRead()
    }

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let core = Unmanaged<TrackerCore>.fromOpaque(refcon).takeUnretainedValue()
        autoreleasepool { core.handle(notification: notification as String, element: element) }
    }

    /// The observer only lives while this core does: every observer is removed in `stop()`, on this thread,
    /// before the core can go away, so an unretained refcon is safe.
    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func makeObserver(pid: pid_t) -> AXObserver? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &observer) == .success, let observer else { return nil }
        CFRunLoopAddSource(thread.cfRunLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        return observer
    }

    private func discard(_ observer: AXObserver) {
        CFRunLoopRemoveSource(thread.cfRunLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func register(_ observer: AXObserver, _ element: AXUIElement, _ names: [String]) -> [String] {
        names.filter { name in
            let error = AXObserverAddNotification(observer, element, name as CFString, refcon)
            return error == .success || error == .notificationAlreadyRegistered
        }
    }

    private func observeApp(pid: pid_t) {
        if let current = appObservation, current.pid == pid, !current.registered.isEmpty { return }
        stopObservingApp()
        guard let observer = makeObserver(pid: pid) else { return }
        let element = reader.appElement(pid)
        let registered = register(observer, element, [AXName.focusedUIElementChanged, AXName.focusedWindowChanged])
        appObservation = AppObservation(pid: pid, observer: observer, element: element, registered: registered)
        registrationAttempts[pid, default: 0] += 1
    }

    /// Apps that are still launching (or building their AX tree) refuse registration; the poll retries a few times.
    private func retryAppObservationIfNeeded() {
        guard let front = frontmost else { return }
        let needsRetry = appObservation.map { $0.pid != front.pid || $0.registered.isEmpty } ?? true
        guard needsRetry, registrationAttempts[front.pid, default: 0] < 10 else { return }
        observeApp(pid: front.pid)
    }

    private func stopObservingApp() {
        guard let app = appObservation else { return }
        if let field = fieldObservation, !field.ownsObserver { stopObservingField() }
        for name in app.registered {
            AXObserverRemoveNotification(app.observer, app.element, name as CFString)
        }
        discard(app.observer)
        appObservation = nil
    }

    private func observeField(_ element: AXUIElement?) {
        if let current = fieldObservation, let element, CFEqual(current.element, element) { return }
        stopObservingField()
        guard let element, let pid = element.pid else { return }

        let observer: AXObserver
        let owns: Bool
        if let app = appObservation, app.pid == pid {
            observer = app.observer
            owns = false
        } else {
            // A field in another process than the frontmost app (Spotlight, panels, remote views).
            guard let own = makeObserver(pid: pid) else { return }
            observer = own
            owns = true
        }
        let registered = register(observer, element, [AXName.valueChanged, AXName.selectedTextChanged, AXName.elementDestroyed])
        fieldObservation = FieldObservation(pid: pid, element: element, observer: observer, ownsObserver: owns, registered: registered)
    }

    private func stopObservingField() {
        guard let field = fieldObservation else { return }
        for name in field.registered {
            AXObserverRemoveNotification(field.observer, field.element, name as CFString)
        }
        if field.ownsObserver { discard(field.observer) }
        fieldObservation = nil
    }
}
