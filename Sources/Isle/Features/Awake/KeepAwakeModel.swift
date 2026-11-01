import Foundation
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac and its display awake, indefinitely or for a while, like
/// `caffeinate -d`. Holds one power assertion; nothing runs in between.
@MainActor
@Observable
final class KeepAwakeModel {
    enum Duration: Hashable, CaseIterable, Identifiable {
        case minutes30, hour1, hours2, indefinitely

        var id: Self { self }
        var seconds: TimeInterval? {
            switch self {
            case .minutes30: 30 * 60
            case .hour1: 60 * 60
            case .hours2: 2 * 60 * 60
            case .indefinitely: nil
            }
        }
        var title: String {
            switch self {
            case .minutes30: "30 minutes"
            case .hour1: "1 hour"
            case .hours2: "2 hours"
            case .indefinitely: "Until turned off"
            }
        }
    }

    private(set) var isOn = false
    /// When the assertion ends on its own; nil while on indefinitely.
    private(set) var until: Date?

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var expiry: Task<Void, Never>?

    func start(_ duration: Duration) {
        stop()
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Isle: Keep Awake" as CFString, &id)
        guard result == kIOReturnSuccess else { return }
        assertion = id
        isOn = true
        guard let seconds = duration.seconds else { return }
        until = .now.addingTimeInterval(seconds)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        expiry?.cancel()
        expiry = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        isOn = false
        until = nil
    }

    func preview(on: Bool, until date: Date? = nil) {
        isOn = on
        until = date
    }
}
