import SwiftUI
import PortviewHostCore

struct ContentView: View {
    let model: HostAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            permissions
            status
            if case .ready(let details) = model.state {
                readyDetails(details)
            }
            if !model.messages.isEmpty {
                logMessages
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 480, alignment: .topLeading)
        .task { model.start() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Portview Host")
                    .font(.largeTitle.bold())
                Text("Runs the Mac host under Portview's own Screen Recording identity.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.isRunning ? "Stop Hosting" : "Start Hosting") {
                model.isRunning ? model.stop() : model.start()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Screen Recording: required for viewing", systemImage: "display")
            HStack {
                Button("Open Screen Recording Settings") { model.openScreenRecordingSettings() }
                Text("Grant Portview Host.app, then quit and reopen if macOS asks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Label("Accessibility: required for remote control", systemImage: "cursorarrow.motionlines")
            HStack {
                Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                Text(model.accessibilityWarning ?? "Viewing can start before Accessibility is granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.state.title, systemImage: statusIcon)
                .font(.headline)
            if case .failed(let message) = model.state {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }

    private func readyDetails(_ details: HostReadyDetails) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Service", details.serviceName)
            row("Address", "\(details.address):\(details.port)")
            row("Pin", details.pinHex)
            GridRow {
                Text("Pairing URL").foregroundStyle(.secondary)
                HStack {
                    Text(details.pairingURL)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Button("Copy") { model.copyPairingURL() }
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var logMessages: some View {
        ScrollView {
            Text(model.messages.joined(separator: "\n\n"))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(minHeight: 120)
        .padding()
        .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusIcon: String {
        switch model.state {
        case .idle: "pause.circle"
        case .starting: "hourglass"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
