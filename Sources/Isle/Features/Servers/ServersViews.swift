import SwiftUI

/// Your localhost servers: port, program, project; Open and Stop.
struct ServersCard: View {
    @Environment(ServersModel.self) private var servers

    var body: some View {
        VStack(spacing: 0) {
            ForEach(servers.servers.prefix(5)) { server in
                ServerRow(server: server)
            }
        }
    }
}

private struct ServerRow: View {
    let server: ServersModel.Server
    @Environment(ServersModel.self) private var servers
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: ":\(server.port)").font(.islandNumber(15, .semibold)).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(server.project ?? server.program).font(.island(13, .semibold)).lineLimit(1)
                Text(verbatim: server.project == nil ? "pid \(server.pid)" : server.program)
                    .font(.island(11.5)).foregroundStyle(Palette.tertiaryLabel).lineLimit(1)
            }
            Spacer(minLength: 8)
            if confirming {
                CapsuleButton(title: "Cancel", isQuiet: true) { confirming = false }
                CapsuleButton(title: "Stop \(server.program)?", isPrimary: true) { servers.stop(server) }
            } else {
                CapsuleButton(title: "Stop", isQuiet: true) { confirming = true }
                CapsuleButton(title: "Open") { servers.open(server) }
            }
        }
        .frame(minHeight: 44)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
        .animation(Motion.snappy, value: confirming)
    }
}
