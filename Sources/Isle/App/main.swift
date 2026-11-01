import AppKit

// Writing to a pipe whose reader died (the Now Playing bridge) must fail
// with EPIPE, not kill the app.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    if let index = CommandLine.arguments.firstIndex(of: "--snapshots") {
        // Offscreen render of every island state, for design review.
        let directory = CommandLine.arguments.dropFirst(index + 1).first ?? "snapshots"
        SnapshotRenderer.run(into: URL(fileURLWithPath: directory))
        exit(0)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--demo") {
        // Scripted tour in a window, for recording the showcase video.
        let style = CommandLine.arguments.dropFirst(index + 1).first.flatMap(IslandStyle.init) ?? .glass
        DemoReel.run(style: style)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
