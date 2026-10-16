import SwiftUI
import SwiftData

/// Pick a folder of Xero exports and bring that company's history in.
struct XeroImportView: View {
    @Environment(\.modelContext) private var context
    @State private var showPicker = false
    @State private var running = false
    @State private var summary: XeroImport.Summary?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Brings a company's history in from Xero: its chart of accounts, every journal (with tax rates), and the receipts and invoices in Xero Files. Running it again on the same folder updates instead of duplicating.")
                    .foregroundStyle(.secondary)
                Text("In Xero, export the Journal Report and the Chart of Accounts (and optionally the General Ledger Detail with tax rates) into one folder, with any Files library folder beside them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    showPicker = true
                } label: {
                    HStack {
                        Label("Choose Xero export folder", systemImage: "folder")
                        if running { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(running)
            }
            if let s = summary {
                Section("Imported \(s.company)") {
                    LabeledContent("Chart accounts", value: "\(s.accounts)")
                    LabeledContent("Bank accounts", value: "\(s.bankAccounts)")
                    LabeledContent("Journals", value: "\(s.journals)")
                    LabeledContent("Lines with tax rates", value: "\(s.linesWithTax)")
                    LabeledContent("Receipts and invoices", value: "\(s.receipts)")
                    ForEach(s.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle("Import from Xero")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await run(url) }
        }
    }

    private func run(_ url: URL) async {
        running = true
        error = nil
        defer { running = false }
        do {
            summary = try await XeroImport.run(folder: url, context: context)
            await CloudDriveSync.shared.sync(context: context)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Read only list of journals (imported from Xero or added later), newest first.
struct JournalsView: View {
    @Query(sort: \LedgerJournal.date, order: .reverse) private var journals: [LedgerJournal]
    @Query(sort: \Company.name) private var companies: [Company]
    @State private var company = ""

    private var shown: [LedgerJournal] {
        journals.filter { company.isEmpty || $0.company?.name == company }
    }

    var body: some View {
        List {
            Section {
                Picker("Company", selection: $company) {
                    Text("All companies").tag("")
                    ForEach(companies.filter { !($0.journals ?? []).isEmpty }) { Text($0.name).tag($0.name) }
                }
            }
            Section("\(shown.count) journals") {
                if shown.isEmpty {
                    Text("No journals yet. Import a company's history from Xero to see them here.").foregroundStyle(.secondary)
                }
                ForEach(shown.prefix(500)) { j in
                    DisclosureGroup {
                        ForEach(Array(j.lines.enumerated()), id: \.offset) { _, l in
                            HStack {
                                Text(l.code).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                                Text(l.name).lineLimit(1)
                                Spacer()
                                if let t = l.taxType.flatMap(TaxType.init(rawValue:)) {
                                    Text(t.name).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(l.amount, format: .number.precision(.fractionLength(2)))
                                    .monospacedDigit()
                                    .foregroundStyle(l.amount < 0 ? Color.secondary : Color.primary)
                                    .frame(minWidth: 80, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(j.narration.isEmpty ? j.reference : j.narration).lineLimit(1)
                            Text("\(j.date.formatted(date: .abbreviated, time: .omitted)) · \(j.reference) · \(j.company?.name ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Journals")
    }
}
