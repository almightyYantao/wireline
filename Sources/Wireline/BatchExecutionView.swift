import SwiftUI
import WirelineCore

/// Select a set of hosts, run one command across all of them concurrently,
/// and read the aggregated per-host output.
struct BatchExecutionView: View {
    @Environment(HostStore.self) private var store
    @State private var selected: Set<String> = []
    @State private var command = ""
    @State private var results: [BatchResult] = []
    @State private var running = false

    private var allHosts: [Host] {
        store.hosts.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Targets").font(.headline)
                    Spacer()
                    Button(selected.count == allHosts.count ? "Deselect All" : "Select All") {
                        selected = selected.count == allHosts.count ? [] : Set(allHosts.map(\.alias))
                    }
                    .font(.caption)
                    ForEach(store.groups, id: \.self) { g in
                        Button(g) {
                            store.hosts(inGroup: g).forEach { selected.insert($0.alias) }
                        }.font(.caption)
                    }
                }
                List {
                    ForEach(allHosts) { host in
                        Toggle(isOn: Binding(
                            get: { selected.contains(host.alias) },
                            set: { on in
                                if on { selected.insert(host.alias) } else { selected.remove(host.alias) }
                            }
                        )) {
                            HStack {
                                Text(host.alias)
                                Text(host.connectionSummary).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if let g = host.group { Text(g).font(.caption2).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                }
            }
            .padding()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Command to run, e.g. uptime", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(run)
                    Button(running ? "Running…" : "Run on \(selected.count)") { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || selected.isEmpty || command.isEmpty)
                }
                if running { ProgressView(value: Double(results.count),
                                          total: Double(max(selected.count, 1))) }

                List(results) { result in
                    DisclosureGroup {
                        if !result.stdout.isEmpty {
                            Text(result.stdout).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !result.stderr.isEmpty {
                            Text(result.stderr).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red).textSelection(.enabled)
                        }
                    } label: {
                        HStack {
                            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.succeeded ? .green : .red)
                            Text(result.alias).font(.body.weight(.medium))
                            Spacer()
                            Text("exit \(result.exitCode) · \(String(format: "%.1fs", result.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .overlay {
                    if results.isEmpty && !running {
                        ContentUnavailableView("No Results", systemImage: "terminal",
                            description: Text("Select hosts and run a command."))
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Batch Execute")
    }

    private func run() {
        let targets = allHosts.filter { selected.contains($0.alias) }
        guard !targets.isEmpty, !command.isEmpty else { return }
        results = []
        running = true
        let executor = BatchExecutor()
        let cmd = command
        Task {
            let final = await executor.run(command: cmd, on: targets) { partial in
                Task { @MainActor in results.append(partial) }
            }
            await MainActor.run {
                results = final
                running = false
            }
        }
    }
}
