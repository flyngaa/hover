import AppKit
import Foundation

/// Cross-process recording state for the one menu-bar moth.
///
/// Hover has two front-ends — the GUI app and the headless `hover record` — and
/// they run as separate processes. Only one parks a moth (see the `show()`
/// guards), but to the user they are the same app, so the moth has to turn blue
/// whenever *any* Hover is recording, not only the process that happens to own
/// the icon.
///
/// Each process announces its own state and listens for the others over
/// `DistributedNotificationCenter`; the moth owner renders ``combinedState``.
/// Peers that died without announcing `.idle` are dropped by a liveness check,
/// so a crash can't leave the moth stuck blue.
@MainActor
final class RecordingPresence {

    enum State: String, Sendable {
        case idle
        case recording
        case processing
    }

    private static let notificationName = Notification.Name("com.hover.recording-presence")
    private let processID = ProcessInfo.processInfo.processIdentifier

    private var localState: State = .idle
    private var remoteStates: [Int32: State] = [:]
    private var livenessTimer: Timer?

    /// Fired when a peer's state changes (or a dead peer is pruned), so the moth
    /// owner can re-render.
    var onChange: (() -> Void)?

    init() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(didReceive(_:)),
            name: Self.notificationName,
            object: nil
        )
    }

    deinit {
        // The liveness timer holds only a weak self and stops itself once peers
        // go idle; a `RecordingPresence` lives for the whole process anyway, so
        // there's nothing to tear down here but the observer.
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Publish this process's state to any peers. A no-op when unchanged, so it's
    /// safe to call on every render tick.
    func announce(_ state: State) {
        guard state != localState else { return }
        localState = state
        DistributedNotificationCenter.default().postNotificationName(
            Self.notificationName,
            object: String(processID),
            userInfo: ["pid": String(processID), "state": state.rawValue],
            deliverImmediately: true
        )
    }

    /// The state across every *live* Hover process: recording wins over
    /// processing wins over idle.
    var combinedState: State {
        Self.combine(local: localState, remotes: liveRemoteStates())
    }

    /// Pure reducer, split out so the precedence is testable without processes.
    static func combine(local: State, remotes: [State]) -> State {
        let all = [local] + remotes
        if all.contains(.recording) { return .recording }
        if all.contains(.processing) { return .processing }
        return .idle
    }

    private func liveRemoteStates() -> [State] {
        remoteStates
            .filter { $0.key != processID && Self.isRunning($0.key) }
            .map(\.value)
    }

    @objc private nonisolated func didReceive(_ note: Notification) {
        // Pull the plist-safe values off the notification here (it isn't
        // Sendable) and hop to the main actor with just those.
        guard let info = note.userInfo,
            let pidString = info["pid"] as? String, let pid = Int32(pidString),
            let stateString = info["state"] as? String,
            let state = State(rawValue: stateString)
        else { return }
        Task { @MainActor in self.receive(pid: pid, state: state) }
    }

    private func receive(pid: Int32, state: State) {
        guard pid != processID else { return }
        remoteStates[pid] = state
        updateLivenessTimer()
        onChange?()
    }

    /// Poll for dead peers only while some peer is mid-recording — the one time a
    /// crash would otherwise strand the moth on blue. Idle again, the timer stops.
    private func updateLivenessTimer() {
        let peerActive = remoteStates.contains { $0.key != processID && $0.value != .idle }
        if peerActive, livenessTimer == nil {
            livenessTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.pruneDeadPeers() }
            }
        } else if !peerActive {
            livenessTimer?.invalidate()
            livenessTimer = nil
        }
    }

    private func pruneDeadPeers() {
        let before = remoteStates.count
        remoteStates = remoteStates.filter { $0.key == processID || Self.isRunning($0.key) }
        if remoteStates.count != before {
            updateLivenessTimer()
            onChange?()
        }
    }

    /// Whether `pid` is still a live process. `EPERM` means it exists but we may
    /// not signal it, which still counts as alive.
    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

extension StatusItemSnapshot.Activity {
    var presenceState: RecordingPresence.State {
        switch self {
        case .idle: return .idle
        case .recording: return .recording
        case .processing: return .processing
        }
    }
}

extension RecordingPresence.State {
    /// The moth projection for this combined state.
    var statusItemSnapshot: StatusItemSnapshot {
        switch self {
        case .idle:
            return StatusItemSnapshot(activity: .idle, tooltip: "Hover")
        case .recording:
            return StatusItemSnapshot(activity: .recording, tooltip: "Hover — recording")
        case .processing:
            return StatusItemSnapshot(activity: .processing, tooltip: "Hover — processing")
        }
    }
}
