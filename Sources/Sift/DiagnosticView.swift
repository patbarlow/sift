import SwiftUI
import AppKit

/// Inspector that runs a one-off sample sync and surfaces the raw LLM
/// inputs/outputs for each candidate. Designed for iterating on prompts +
/// user-context without polluting the real database.
struct DiagnosticView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    @State private var report: SyncWorker.DiagnosticReport?
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if running && report == nil {
                HStack(spacing: 8) { SiftSpinner(); Text("Pulling candidates and running the model…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = report {
                resultsList(report)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 720, minHeight: 600)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Diagnostic")
                .font(.title3.weight(.semibold))
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            if running {
                SiftSpinner()
            }
            Button(running ? "Running…" : "Run again") {
                Task { await runDiagnostic() }
            }
            .disabled(running)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("Run the diagnostic to see the model's reasoning for each candidate.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Run diagnostic") {
                Task { await runDiagnostic() }
            }
            .disabled(running)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultsList(_ report: SyncWorker.DiagnosticReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryHeader(report)
                ForEach(report.items) { item in
                    DiagnosticItemCard(item: item)
                }
                if !report.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Errors").font(.subheadline.weight(.semibold))
                        ForEach(Array(report.errors.enumerated()), id: \.offset) { _, err in
                            Text("• \(err)").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func summaryHeader(_ report: SyncWorker.DiagnosticReport) -> some View {
        HStack(spacing: 14) {
            Label("\(report.items.count) candidates", systemImage: "tray")
            let kept = report.items.filter { $0.assessmentStatus == "open" || $0.assessmentStatus == "in_progress" }.count
            Label("\(kept) kept", systemImage: "checkmark.circle")
            let skipped = report.items.filter { $0.assessmentStatus == "skip" }.count
            Label("\(skipped) skipped", systemImage: "xmark.circle")
            let done = report.items.filter { $0.assessmentStatus == "done" }.count
            Label("\(done) already done", systemImage: "tray.full")
            Spacer()
            Text(String(format: "%.1fs", report.durationSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func runDiagnostic() async {
        guard let worker = SyncWorker(container: state.container, settings: state.settings) else {
            error = "Not configured — finish onboarding first."
            return
        }
        running = true
        error = nil
        let r = await worker.runDiagnostic(limit: 5)
        await MainActor.run {
            self.report = r
            self.running = false
            if !r.errors.isEmpty && r.items.isEmpty {
                self.error = r.errors.first
            }
        }
    }
}

struct DiagnosticItemCard: View {
    let item: SyncWorker.DiagnosticItem
    @State private var showThread = false
    @State private var showAssessIn = false
    @State private var showAssessOut = false
    @State private var showSummaryIn = false
    @State private var showSummaryOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: status + classification + channel
            HStack(spacing: 8) {
                statusBadge
                classificationBadge
                Text("#\(item.channel)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let title = item.title, !title.isEmpty {
                Text(title)
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = item.assessmentNote, !note.isEmpty {
                Text("Assessor note: \(note)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            }

            // Trigger excerpt
            Text("Trigger message")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(item.triggerText.prefix(400) + (item.triggerText.count > 400 ? "…" : ""))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )

            disclosureSection(title: "Resolved thread (\(item.resolvedThreadLines.count))", isShown: $showThread) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.resolvedThreadLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                            .textSelection(.enabled)
                    }
                }
            }
            disclosureSection(title: "Assessor input (Haiku)", isShown: $showAssessIn) {
                codeBlock(item.assessmentInput)
            }
            disclosureSection(title: "Assessor output (raw)", isShown: $showAssessOut) {
                codeBlock(item.assessmentRaw)
            }
            if let sIn = item.summariseInput {
                disclosureSection(title: "Summariser input (Sonnet)", isShown: $showSummaryIn) {
                    codeBlock(sIn)
                }
            }
            if let sOut = item.summariseRaw {
                disclosureSection(title: "Summariser output (raw)", isShown: $showSummaryOut) {
                    codeBlock(sOut)
                }
            }

            if let url = item.permalink {
                HStack {
                    Spacer()
                    Button("Open in Slack") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var statusBadge: some View {
        let color: Color = {
            switch item.assessmentStatus {
            case "open": return .orange
            case "in_progress": return .blue
            case "done": return .green
            case "skip": return .secondary
            default: return .secondary
            }
        }()
        return Text(item.assessmentStatus)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private var classificationBadge: some View {
        Text(item.assessmentClassification)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func disclosureSection<Content: View>(title: String,
                                                  isShown: Binding<Bool>,
                                                  @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: isShown) {
            content().padding(.top, 4)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .textSelection(.enabled)
    }
}
