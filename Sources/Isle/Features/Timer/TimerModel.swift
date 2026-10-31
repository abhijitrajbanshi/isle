import AppKit
import Observation

/// A single countdown, like the Clock app's timer.
@MainActor
@Observable
final class TimerModel {
    enum State: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
    }

    private(set) var state: State = .idle
    private(set) var total: TimeInterval = 0
    private(set) var lastDuration: TimeInterval = 300

    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored private var fireTask: Task<Void, Never>?

    static let presets: [TimeInterval] = [60, 180, 300, 600, 900, 1500, 2700, 3600]

    var isActive: Bool { state != .idle }
    var isRunning: Bool { if case .running = state { true } else { false } }
    /// When a running timer fires; nil while paused or idle.
    var end: Date? { if case .running(let end) = state { end } else { nil } }

    /// Seconds to show for `remaining`: rounded up like the Clock app, but
    /// tolerant of floating-point noise on whole-second ticks.
    static func displayed(_ remaining: TimeInterval) -> TimeInterval {
        max(0, (remaining - 0.001).rounded(.up))
    }

    func remaining(at date: Date = .now) -> TimeInterval {
        switch state {
        case .idle: 0
        case .running(let end): max(0, end.timeIntervalSince(date))
        case .paused(let remaining): remaining
        }
    }

    /// 1 when full, 0 when done.
    func fraction(at date: Date = .now) -> Double {
        total > 0 ? remaining(at: date) / total : 0
    }

    func start(_ seconds: TimeInterval) {
        total = seconds
        lastDuration = seconds
        run(until: .now.addingTimeInterval(seconds))
    }

    func toggle() {
        switch state {
        case .running:
            fireTask?.cancel()
            state = .paused(remaining: remaining())
        case .paused(let remaining):
            run(until: .now.addingTimeInterval(remaining))
        case .idle:
            break
        }
    }

    func addMinute() {
        total += 60
        switch state {
        case .running(let end): run(until: end.addingTimeInterval(60))
        case .paused(let remaining): state = .paused(remaining: remaining + 60)
        case .idle: start(60)
        }
    }

    func cancel() {
        fireTask?.cancel()
        state = .idle
    }

    private func run(until end: Date) {
        state = .running(end: end)
        fireTask?.cancel()
        fireTask = Task { [weak self] in
            try? await Task.sleep(until: .now + .seconds(end.timeIntervalSinceNow), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.state = .idle
            NSSound(named: "Glass")?.play()
            self.onFinish()
        }
    }

    func preview(remaining: TimeInterval, of total: TimeInterval) {
        self.total = total
        state = .running(end: .now.addingTimeInterval(remaining))
    }
}
