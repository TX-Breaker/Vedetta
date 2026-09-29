import Foundation
import VedettaL10n

/// What Vedetta may do with a device's credentials right now.
public enum AccessState: Equatable, Sendable {
    /// Credentials not confirmed yet in this session: one attempt at a time.
    case unverified
    /// Credentials confirmed by the device.
    case online
    /// Device not reachable: no logins, only unauthenticated checks with growing pauses.
    case offline(reason: String, retryAt: Date)
    /// User name or password refused: nothing is attempted until the user acts.
    case rejected(String)
    /// Account locked by the device (`until` = unlock time, when the device tells it).
    case locked(until: Date?)
    /// No saved password (e.g. Keychain access denied): never try with an empty one.
    case missingPassword
    /// The user signed out of the device.
    case signedOut

    public var isUsable: Bool { self == .online || self == .unverified }
    public var isOffline: Bool { if case .offline = self { return true } else { return false } }
    /// Automatic attempts are stopped until the user signs in or retries.
    public var needsUser: Bool {
        switch self {
        case .rejected, .locked, .missingPassword, .signedOut: return true
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .unverified: return L("Connecting…")
        case .online: return L("Connected")
        case .offline(_, let at):
            return L("Recorder not reachable. Vedetta checks again at %@, without sending the password.", AccessState.time(at))
        case .rejected(let why): return why
        case .locked(let until):
            if let until { return L("The recorder locked this user after too many attempts. Vedetta will try once more at %@.", AccessState.time(until)) }
            return L("The recorder locked this user after too many attempts. Vedetta will not try again by itself.")
        case .missingPassword: return L("The saved password is not available. Sign in again.")
        case .signedOut: return L("Signed out of the recorder.")
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}

/// How an operation ended, as far as the account is concerned.
public enum AccessOutcome: Equatable, Sendable {
    /// The device accepted the credentials.
    case confirmed
    /// Completed without telling anything about the credentials (e.g. stream not found).
    case neutral
    /// The device did not answer (timeout, connection refused…).
    case network(String)
    /// Login refused: the credentials are wrong.
    case rejected(String)
    /// Refused, but it may only be a missing permission for this camera/operation.
    case denied(String)
    /// Account locked (seconds until unlock, when known).
    case locked(seconds: Int?)
}

/// Thrown instead of contacting the device when the guard does not allow it.
public struct AccessBlocked: LocalizedError, Sendable {
    public let state: AccessState
    public init(state: AccessState) { self.state = state }
    public var errorDescription: String? { state.message }
}

/// Exponential backoff with jitter (5 s, 10 s, 20 s… up to 5 minutes by default).
public struct Backoff: Sendable {
    public var base: Double
    public var maximum: Double
    public var jitter: Double
    public init(base: Double, maximum: Double, jitter: Double) {
        self.base = base; self.maximum = maximum; self.jitter = jitter
    }
    public static let standard = Backoff(base: 5, maximum: 300, jitter: 0.2)

    /// `random` in 0…1 spreads the attempts of many clients (±jitter).
    public func delay(attempt: Int, random: Double) -> Double {
        let d = min(maximum, base * pow(2, Double(min(max(attempt, 0), 30))))
        let r = min(max(random, 0), 1)
        return min(maximum, max(1, d * (1 - jitter + 2 * jitter * r)))
    }
}

/// Time source (replaced by a virtual clock in tests).
public protocol AccessClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemAccessClock: AccessClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// FIFO async mutex (serializes login exchanges on devices that keep a single login nonce).
public final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go: Bool = lock.withLock {
                if busy { waiters.append(c); return false }
                busy = true
                return true
            }
            if go { c.resume() }
        }
    }

    private func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { busy = false; return nil }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

/// Protects one device's account from lockouts.
///
/// - Only one operation that sends the credentials runs while they are not confirmed; the others wait for its result.
/// - Refused credentials or a locked account stop every automatic attempt until the user acts
///   (a lock with a known unlock time allows one new attempt after it).
/// - Network failures never cause logins: an unauthenticated check confirms the device is down, then it is
///   probed with exponential backoff and jitter; sessions and tokens are reused when it comes back.
public final class AccessGuard: @unchecked Sendable {
    public let label: String
    public let clock: AccessClock
    public let backoff: Backoff
    /// Serializes login exchanges (VIGI keeps one login nonce: two parallel logins make one fail).
    public let loginMutex = AsyncMutex()

    private let random: @Sendable () -> Double
    private let log: AccessLog?
    private let probe: @Sendable () async -> Bool
    private let lock = NSLock()
    private var _state: AccessState
    private var verified = false
    private var slotBusy = false
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    private var confirmingReachability = false
    private var checkingDenial = false
    private var denials = 0
    private var suppressed = 0
    private var timerTask: Task<Void, Never>?
    private var observers: [UUID: @Sendable (AccessState) -> Void] = [:]
    /// Asks the device, without credentials, whether the account is locked (seconds left).
    private var lockProbe: (@Sendable () async -> Int?)?
    /// Checks whether the saved credentials are still valid (true/false, nil = cannot tell).
    private var credentialCheck: (@Sendable () async -> Bool?)?
    /// The device's preferred first check (a request every user may make, e.g. the VIGI API login): it runs
    /// with the slot reserved whenever the credentials must be confirmed, so no video stream goes first.
    private var verifier: (@Sendable () async -> Void)?
    private var reserved = false
    private var _attempts = 0
    private var _probes = 0

    public init(label: String, initial: AccessState = .unverified, clock: AccessClock = SystemAccessClock(),
                backoff: Backoff = .standard, random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                log: AccessLog? = .shared, probe: @escaping @Sendable () async -> Bool) {
        self.label = label
        self._state = initial
        self.clock = clock
        self.backoff = backoff
        self.random = random
        self.log = log
        self.probe = probe
    }

    deinit { timerTask?.cancel() }

    public func setLockProbe(_ p: (@Sendable () async -> Int?)?) { lock.withLock { lockProbe = p } }
    public func setCredentialCheck(_ c: (@Sendable () async -> Bool?)?) { lock.withLock { credentialCheck = c } }
    public func setVerifier(_ v: (@Sendable () async -> Void)?) { lock.withLock { verifier = v } }

    /// Starts the preferred first check when the credentials are not confirmed yet.
    public func verifyIfNeeded() {
        let run = lock.withLock { reserveForVerifier() }
        launch(run)
    }

    /// Must be called with the lock held.
    private func reserveForVerifier() -> (@Sendable () async -> Void)? {
        guard _state == .unverified, let v = verifier, !slotBusy else { return nil }
        slotBusy = true
        reserved = true
        return v
    }

    private func launch(_ run: (@Sendable () async -> Void)?) {
        guard let run else { return }
        Task { [weak self] in
            await run()
            self?.releaseReservation()
        }
    }

    private func releaseReservation() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard reserved else { return [] }
            reserved = false
            slotBusy = false
            let w = slotWaiters
            slotWaiters.removeAll()
            return w
        }
        for w in waiters { w.resume() }
    }

    /// Must be called with the lock held: `.unverified` plus the reserved first check, if any.
    private func becomeUnverified() -> (AccessState?, (@Sendable () async -> Void)?) {
        let changed = transition(.unverified)
        return (changed, reserveForVerifier())
    }

    public var state: AccessState { lock.withLock { _state } }
    /// Operations that sent the credentials (diagnostics and tests).
    public var attempts: Int { lock.withLock { _attempts } }
    /// Unauthenticated reachability checks made.
    public var probes: Int { lock.withLock { _probes } }

    // MARK: Observers

    /// `handler` runs on an arbitrary thread after every state change.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (AccessState) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return id
    }

    public func removeObserver(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }

    private func broadcast(_ s: AccessState?) {
        guard let s else { return }
        let handlers = lock.withLock { Array(observers.values) }
        for h in handlers { h(s) }
    }

    /// Must be called with the lock held. Returns the new state when it changed.
    private func transition(_ s: AccessState) -> AccessState? {
        guard _state != s else { return nil }
        let old = _state
        _state = s
        if old.needsUser || old.isOffline, suppressed > 0 {
            let n = suppressed
            DispatchQueue.global().async { self.log?.record(self.label, "guard", "suppressed", "\(n) automatic attempts not made") }
        }
        suppressed = 0
        if case .offline = old, case .offline = s {} else {
            let text = Self.describe(s)
            DispatchQueue.global().async { self.log?.record(self.label, "state", text.0, text.1) }
        }
        return s
    }

    public static func describe(_ s: AccessState) -> (String, String?) {
        switch s {
        case .unverified: return ("unverified", nil)
        case .online: return ("online", nil)
        case .offline(let r, _): return ("offline", r)
        case .rejected(let r): return ("rejected", r)
        case .locked(let u): return ("locked", u.map { "until \(ISO8601DateFormatter().string(from: $0))" })
        case .missingPassword: return ("missing-password", nil)
        case .signedOut: return ("signed-out", nil)
        }
    }

    // MARK: Operations that send the credentials

    /// Runs an operation that sends the device credentials.
    /// - Parameters:
    ///   - manual: requested by the user (sign-in, "Try again"): allowed even when automatic attempts are stopped.
    ///   - important: always written to the connection log (otherwise only failures and first checks are).
    ///   - reserved: the caller is the device's verifier and uses the slot reserved for it.
    public func credentialed<T>(_ action: String, manual: Bool = false, important: Bool = true, reserved: Bool = false,
                                _ body: () async throws -> T,
                                outcome: (Result<T, Error>) -> AccessOutcome) async throws -> T {
        let usesReservation = reserved && lock.withLock { () -> Bool in
            // Signed out / refused meanwhile: fall back to the normal checks (which then refuse).
            guard self.reserved, _state == .unverified else { return false }
            self.reserved = false
            _attempts += 1
            return true
        }
        let slot = usesReservation ? true : try await admit(action, manual: manual)
        let result: Result<T, Error>
        do { result = .success(try await body()) } catch { result = .failure(error) }
        let o = outcome(result)
        if important || slot || manual || !(o == .confirmed || o == .neutral) {
            log?.record(label, action + (manual ? " (manual)" : ""), Self.result(o), Self.detail(o, result))
        }
        finish(holdsSlot: slot, manual: manual, outcome: o)
        return try result.get()
    }

    /// Returns true when the caller holds the single "first check" slot.
    private func admit(_ action: String, manual: Bool) async throws -> Bool {
        while true {
            if Task.isCancelled { throw CancellationError() }
            enum Step { case go(Bool), wait, blocked(AccessState) }
            let step: Step = lock.withLock {
                if manual || _state == .unverified {
                    if slotBusy { return .wait }
                    slotBusy = true
                    _attempts += 1
                    return .go(true)
                }
                if _state == .online { _attempts += 1; return .go(false) }
                suppressed += 1
                return .blocked(_state)
            }
            switch step {
            case .go(let slot): return slot
            case .blocked(let s): throw AccessBlocked(state: s)
            case .wait:
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let now: Bool = lock.withLock {
                        if slotBusy { slotWaiters.append(c); return false }
                        return true
                    }
                    if now { c.resume() }
                }
            }
        }
    }

    /// Fast check before a request that reuses an existing session (no credentials sent).
    public func admitRequest() throws {
        try lock.withLock {
            if _state.isUsable { return }
            suppressed += 1
            throw AccessBlocked(state: _state)
        }
    }

    /// Reports the result of a request made without credentials (e.g. with a session token).
    public func report(_ outcome: AccessOutcome, action: String = "request") {
        if case .network(let why) = outcome { log?.record(label, action, "network", why) }
        finish(holdsSlot: false, manual: false, outcome: outcome)
    }

    private func finish(holdsSlot: Bool, manual: Bool, outcome: AccessOutcome) {
        var changed: AccessState?
        var waiters: [CheckedContinuation<Void, Never>] = []
        var confirmReason: String?
        var checkLock = false
        var checkDenial = false
        var verify: (@Sendable () async -> Void)?
        lock.withLock {
            if holdsSlot {
                slotBusy = false
                waiters = slotWaiters
                slotWaiters.removeAll()
            }
            switch outcome {
            case .confirmed:
                verified = true
                denials = 0
                // After a refusal/lock/sign out, a successful sign-in becomes effective only when the app has
                // stored the new credentials (`reset`): nothing may reconnect with the old ones meanwhile.
                if _state.isUsable || _state.isOffline {
                    timerTask?.cancel()
                    confirmingReachability = false
                    changed = transition(.online)
                }
            case .neutral:
                if _state.isOffline {
                    // The device answered: it is reachable again.
                    timerTask?.cancel()
                    if verified { changed = transition(.online) } else { (changed, verify) = becomeUnverified() }
                }
            case .network(let why):
                if !_state.isOffline && !_state.needsUser && !confirmingReachability {
                    confirmingReachability = true
                    confirmReason = why
                }
            case .rejected(let why):
                if !manual || !_state.isUsable {
                    timerTask?.cancel()
                    changed = transition(.rejected(why))
                    checkLock = lockProbe != nil
                }
            case .denied(let why):
                if holdsSlot || _state == .unverified || (manual && !_state.isUsable) {
                    timerTask?.cancel()
                    changed = transition(.rejected(why))
                    checkLock = lockProbe != nil
                } else if _state == .online {
                    // Maybe only a missing permission: confirm before stopping everything.
                    if credentialCheck != nil {
                        if !checkingDenial { checkingDenial = true; checkDenial = true }
                    } else {
                        denials += 1
                        if denials >= 2 {
                            changed = transition(.rejected(why))
                            checkLock = lockProbe != nil
                        }
                    }
                }
            case .locked(let seconds):
                timerTask?.cancel()
                if let seconds, seconds > 0 {
                    changed = transition(.locked(until: clock.now().addingTimeInterval(TimeInterval(seconds))))
                    scheduleUnlock(after: Double(seconds))
                } else {
                    changed = transition(.locked(until: nil))
                    checkLock = lockProbe != nil
                }
            }
        }
        for w in waiters { w.resume() }
        broadcast(changed)
        launch(verify)
        if let confirmReason { confirmReachability(confirmReason) }
        if checkLock { askLockStatus() }
        if checkDenial { verifyAfterDenial(outcome) }
    }

    // MARK: Reachability

    private func confirmReachability(_ why: String) {
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.probe()
            self.countProbe(ok, note: "check after a failed request")
            if ok {
                self.lock.withLock { self.confirmingReachability = false }
            } else {
                self.enterOffline(why)
            }
        }
    }

    private func enterOffline(_ why: String) {
        let changed: AccessState? = lock.withLock {
            confirmingReachability = false
            guard !_state.needsUser, !_state.isOffline else { return nil }
            timerTask?.cancel()
            // Offline at once, so late failures of requests already under way start no other check.
            let changed = transition(.offline(reason: why, retryAt: clock.now().addingTimeInterval(backoff.delay(attempt: 0, random: 0.5))))
            timerTask = Task { [weak self] in await self?.probeLoop(why) }
            return changed
        }
        broadcast(changed)
    }

    private func probeLoop(_ why: String) async {
        var attempt = 0
        while !Task.isCancelled {
            let delay = backoff.delay(attempt: attempt, random: random())
            let retryAt = clock.now().addingTimeInterval(delay)
            var stop = false
            let changed: AccessState? = lock.withLock {
                if _state.needsUser { stop = true; return nil }
                return transition(.offline(reason: why, retryAt: retryAt))
            }
            if stop { return }
            broadcast(changed)
            do { try await clock.sleep(seconds: delay) } catch { return }
            if Task.isCancelled { return }
            let ok = await probe()
            countProbe(ok, note: "attempt \(attempt + 1)")
            if Task.isCancelled { return }
            if ok {
                let (back, run): (AccessState?, (@Sendable () async -> Void)?) = lock.withLock {
                    guard _state.isOffline else { return (nil, nil) }
                    return verified ? (transition(.online), nil) : becomeUnverified()
                }
                broadcast(back)
                launch(run)
                return
            }
            attempt += 1
        }
    }

    private func countProbe(_ ok: Bool, note: String) {
        lock.withLock { _probes += 1 }
        log?.record(label, "probe (no password)", ok ? "reachable" : "unreachable", note)
    }

    // MARK: Locks and denials

    /// Must be called with the lock held.
    private func scheduleUnlock(after seconds: Double) {
        let delay = seconds + 5 + 10 * random()
        timerTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(seconds: delay) } catch { return }
            if Task.isCancelled { return }
            let (s, run): (AccessState?, (@Sendable () async -> Void)?) = self.lock.withLock {
                guard case .locked = self._state else { return (nil, nil) }
                return self.becomeUnverified()
            }
            if s != nil { self.log?.record(self.label, "guard", "unlock-time-reached", "one new attempt allowed") }
            self.broadcast(s)
            self.launch(run)
        }
    }

    private func askLockStatus() {
        guard let p = lock.withLock({ lockProbe }) else { return }
        Task { [weak self] in
            guard let secs = await p(), secs > 0, let self else { return }
            let s: AccessState? = self.lock.withLock {
                switch self._state {
                case .rejected, .locked(until: nil):
                    self.timerTask?.cancel()
                    let changed = self.transition(.locked(until: self.clock.now().addingTimeInterval(TimeInterval(secs))))
                    self.scheduleUnlock(after: Double(secs))
                    return changed
                default: return nil
                }
            }
            self.broadcast(s)
        }
    }

    private func verifyAfterDenial(_ outcome: AccessOutcome) {
        guard let check = lock.withLock({ credentialCheck }), case .denied(let why) = outcome else { return }
        Task { [weak self] in
            let valid = await check()
            guard let self else { return }
            var changed: AccessState?
            var checkLock = false
            self.lock.withLock {
                self.checkingDenial = false
                switch valid {
                case .some(true): self.denials = 0
                case .some(false):
                    changed = self.transition(.rejected(why))
                    checkLock = self.lockProbe != nil
                case .none:
                    self.denials += 1
                    if self.denials >= 2 { changed = self.transition(.rejected(why)); checkLock = self.lockProbe != nil }
                }
            }
            self.log?.record(self.label, "credential check", valid == true ? "valid (permission issue)" : (valid == false ? "rejected" : "unknown"), why)
            self.broadcast(changed)
            if checkLock { self.askLockStatus() }
        }
    }

    // MARK: User actions

    /// "Try again": one new attempt with the saved password, or an immediate reachability check.
    public func retryNow() {
        var changed: AccessState?
        var verify: (@Sendable () async -> Void)?
        lock.withLock {
            switch _state {
            case .offline(let why, _):
                timerTask?.cancel()
                timerTask = Task { [weak self] in
                    guard let self else { return }
                    let ok = await self.probe()
                    self.countProbe(ok, note: "requested by the user")
                    if Task.isCancelled { return }
                    if ok {
                        let (st, run): (AccessState?, (@Sendable () async -> Void)?) = self.lock.withLock {
                            guard self._state.isOffline else { return (nil, nil) }
                            return self.verified ? (self.transition(.online), nil) : self.becomeUnverified()
                        }
                        self.broadcast(st)
                        self.launch(run)
                    } else {
                        await self.probeLoop(why)
                    }
                }
            case .rejected, .locked:
                timerTask?.cancel()
                (changed, verify) = becomeUnverified()
            default: break
            }
        }
        log?.record(label, "retry", "requested by the user")
        broadcast(changed)
        launch(verify)
    }

    /// New credentials were entered (or confirmed by a sign-in).
    public func reset(verified v: Bool) {
        let (changed, run): (AccessState?, (@Sendable () async -> Void)?) = lock.withLock {
            timerTask?.cancel()
            confirmingReachability = false
            verified = v
            denials = 0
            return v ? (transition(.online), nil) : becomeUnverified()
        }
        broadcast(changed)
        launch(run)
    }

    /// Stops everything: no attempts, no probes, until `reset`.
    public func signOut() {
        let changed: AccessState? = lock.withLock {
            timerTask?.cancel()
            confirmingReachability = false
            verified = false
            return transition(.signedOut)
        }
        log?.record(label, "sign out", "local", nil)
        broadcast(changed)
    }

    /// Silences a guard that is being replaced (device address changed): no more callbacks or timers.
    public func retire() {
        lock.withLock {
            timerTask?.cancel()
            observers.removeAll()
            _state = .signedOut
        }
    }

    public func markMissingPassword() {
        let changed: AccessState? = lock.withLock {
            timerTask?.cancel()
            return transition(.missingPassword)
        }
        broadcast(changed)
    }

    /// Writes a line in the connection log for this device.
    public func note(_ action: String, _ result: String, _ detail: String? = nil) {
        log?.record(label, action, result, detail)
    }

    // MARK: Log text

    static func result(_ o: AccessOutcome) -> String {
        switch o {
        case .confirmed: return "ok"
        case .neutral: return "done"
        case .network: return "network"
        case .rejected: return "rejected"
        case .denied: return "denied"
        case .locked(let s): return s.map { "locked \($0)s" } ?? "locked"
        }
    }

    static func detail<T>(_ o: AccessOutcome, _ r: Result<T, Error>) -> String? {
        switch o {
        case .network(let s), .rejected(let s), .denied(let s): return s
        default:
            if case .failure(let e) = r { return e.localizedDescription }
            return nil
        }
    }
}
