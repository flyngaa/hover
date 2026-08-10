import HoverCore
import Observation

/// Main-actor presentation state for the one-time model download. Agent Mode
/// uses `ModelSetup` directly and does not construct this controller.
@MainActor @Observable
final class ModelSetupController {
    private(set) var status: ModelSetupStatus

    @ObservationIgnored private let modelSetup: any ModelSetup
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    var isComplete: Bool { modelSetup.isComplete }

    init(modelSetup: any ModelSetup) {
        self.modelSetup = modelSetup
        status = modelSetup.isComplete ? .notNeeded : .running(fraction: 0)
    }

    func startIfNeeded() {
        guard fetchTask == nil else { return }
        guard !modelSetup.isComplete else {
            status = .notNeeded
            return
        }

        let setup = modelSetup
        fetchTask = Task { [weak self] in
            do {
                for try await fraction in setup.fetchMissing() {
                    guard !Task.isCancelled else { return }
                    self?.status = .running(fraction: fraction)
                }
                guard !Task.isCancelled else { return }
                self?.status = .notNeeded
                self?.fetchTask = nil
            } catch is CancellationError {
                self?.fetchTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                let message =
                    error.localizedDescription.isEmpty
                    ? "Couldn't download model data."
                    : error.localizedDescription
                self?.status = .failed(message: message)
                self?.fetchTask = nil
            }
        }
    }

    func retry() {
        cancel()
        startIfNeeded()
    }

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
    }
}
