import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

@main
struct ReceiptsMacApp: App {
    let container = StoreInfo.makeContainer()

    var body: some Scene {
        WindowGroup("Receipts & Ledger") {
            MacRootView()
        }
        .modelContainer(container)
        .defaultSize(width: 1250, height: 820)
    }
}

enum SidebarItem: Hashable {
    case receipts(company: String?)
    case bank
    case match
    case companies
    case sync
    case reconcile
    case reports
    case chart
    case journals
    case xeroImport
}

struct MacRootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Company.name) private var companies: [Company]
    @Query private var transactions: [BankTransaction]
    @State private var selection: SidebarItem? = .receipts(company: nil)
    @State private var sync = CloudDriveSync.shared
    @State private var librarySync = LibrarySync.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Receipts") {
                    Label("All receipts", systemImage: "tray.full").tag(SidebarItem.receipts(company: nil))
                    ForEach(companies) { company in
                        Label(company.name, systemImage: "building.2")
                            .badge(company.receipts?.count ?? 0)
                            .tag(SidebarItem.receipts(company: company.name))
                    }
                }
                Section("Bank") {
                    Label("Accounts", systemImage: "building.columns").tag(SidebarItem.bank)
                    Label("Match", systemImage: "link")
                        .badge(transactions.filter { $0.status == .needsReceipt }.count)
                        .tag(SidebarItem.match)
                }
                Section("Ledger") {
                    Label("Reconcile", systemImage: "checkmark.rectangle.stack")
                        .badge(transactions.filter { !$0.isReconciled }.count)
                        .tag(SidebarItem.reconcile)
                    Label("Reports", systemImage: "chart.bar.doc.horizontal").tag(SidebarItem.reports)
                    Label("Chart of Accounts", systemImage: "list.number").tag(SidebarItem.chart)
                    Label("Journals", systemImage: "book.closed").tag(SidebarItem.journals)
                    Label("Import from Xero", systemImage: "square.and.arrow.down.on.square").tag(SidebarItem.xeroImport)
                }
                Section("Settings") {
                    Label("Companies", systemImage: "list.bullet").tag(SidebarItem.companies)
                    Label("Sync with iPhone apps", systemImage: "arrow.triangle.2.circlepath").tag(SidebarItem.sync)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if StoreInfo.loadError != nil {
                        Text("Saved data could not be opened. Nothing was changed.")
                            .foregroundStyle(.red)
                    }
                    Text(librarySync.folderName.map { "Syncing through \($0) folder" } ?? "Not syncing: choose a folder in Sync with iPhone apps")
                        .foregroundStyle(librarySync.folderName == nil ? Color.orange : Color.secondary)
                }
                .font(.caption)
                .padding(8)
            }
        } detail: {
            switch selection {
            case .receipts(let name):
                MacReceiptsView(companyName: name)
                    .id(name ?? "all")
            case .bank:
                NavigationStack { BankAccountsView() }
            case .match:
                NavigationStack { MatchView() }
            case .companies:
                NavigationStack { CompaniesView() }
            case .sync:
                NavigationStack { LibrarySyncView() }
            case .reconcile:
                NavigationStack { ReconcileView() }
            case .reports:
                NavigationStack { ReportsView() }
            case .chart:
                NavigationStack { ChartOfAccountsView() }
            case .journals:
                NavigationStack { JournalsView() }
            case .xeroImport:
                NavigationStack { XeroImportView() }
            case nil:
                ContentUnavailableView("Pick something in the sidebar", systemImage: "sidebar.left")
            }
        }
        .onAppear {
            CompanyStore.repairIDs(context)
            CompanyStore.seedIfNeeded(context)
            CompanyStore.applyFolds(context)
            CompanyStore.mergeDuplicates(context)
            Chart.seedIfNeeded(context)
            Chart.assignBankCodes(context)
        }
        .periodicSync()
        #if DEBUG
        .task { await XeroImportCheck.runIfRequested(context: context) }
        #endif
    }
}

struct MacReceiptsView: View {
    let companyName: String?
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Receipt.date, order: .reverse), SortDescriptor(\Receipt.createdAt, order: .reverse)])
    private var receipts: [Receipt]
    @Query(sort: \Company.name) private var companies: [Company]

    @State private var selection: PersistentIdentifier?
    @State private var showImporter = false
    @State private var search = ""
    @State private var message: String?

    private var company: Company? { companies.first { $0.name == companyName } }

    private var shown: [Receipt] {
        receipts
            .filter { companyName == nil || $0.company?.name == companyName }
            .filter { search.isEmpty || $0.merchant.localizedCaseInsensitiveContains(search) || $0.category.rawValue.localizedCaseInsensitiveContains(search) }
    }

    private var selected: Receipt? {
        shown.first { $0.persistentModelID == selection }
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(shown) { r in
                        HStack {
                            ReceiptMiniRow(receipt: r, caption: r.isProcessing ? "Reading receipt…" : nil)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(r.total, format: .currency(code: r.currency)).monospacedDigit()
                                if r.bankTransaction != nil {
                                    Label("In bank", systemImage: "checkmark.circle.fill")
                                        .labelStyle(.iconOnly)
                                        .foregroundStyle(.green)
                                        .help("Matched to a bank transaction")
                                }
                            }
                        }
                        .tag(r.persistentModelID)
                    }
                } header: {
                    HStack {
                        Text("\(shown.count) receipts")
                        Spacer()
                        Text(shown.reduce(0) { $0 + $1.total }, format: .currency(code: "AUD"))
                    }
                }
            }
            .frame(minWidth: 340, idealWidth: 400)
            .searchable(text: $search, prompt: "Search receipts")
            .dropDestination(for: URL.self) { urls, _ in
                addFiles(urls)
                return true
            }
            .overlay {
                if shown.isEmpty && search.isEmpty {
                    ContentUnavailableView {
                        Label("No receipts", systemImage: "doc.text.viewfinder")
                    } description: {
                        Text(company == nil
                             ? "Scan receipts on your iPhone, or pick a company and drop receipt images here."
                             : "Scan receipts on your iPhone, or drop receipt images or PDFs here.")
                    }
                }
            }

            Group {
                if let r = selected {
                    ReceiptEditView(receipt: r) {
                        selection = nil
                        context.delete(r)
                        try? context.save()
                    }
                    .id(r.persistentModelID)
                } else {
                    ContentUnavailableView("Select a receipt", systemImage: "doc.text")
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(companyName ?? "All receipts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("Add receipt images", systemImage: "plus") }
                    .disabled(company == nil)
                    .help(company == nil ? "Pick a company in the sidebar first" : "Add receipt images or PDFs")
                Button { Task { await exportSpreadsheet() } } label: { Label("Export spreadsheet", systemImage: "tablecells") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .alert("Receipts", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func addFiles(_ urls: [URL]) {
        guard let company else {
            message = "Pick a company in the sidebar first, then add the receipts."
            return
        }
        let files = urls.flatMap(PDFPages.receiptImages(from:))
        ReceiptIntake.add(imageData: files, to: company, context: context)
    }

    private func exportSpreadsheet() async {
        do {
            let file = try await CloudDriveSync.shared.makeShareableCopy(context: context)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.lastPathComponent
            panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: file, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            message = "Could not export: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
/// Testing: launch with -xeroImport <folder> to import and print reports to compare with Xero's.
@MainActor
enum XeroImportCheck {
    /// Unbuffered, so the output survives the app being stopped.
    static func print(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func runIfRequested(context: ModelContext) async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-xeroImport"), i + 1 < args.count else { return }
        do {
            let s = try await XeroImport.run(folder: URL(fileURLWithPath: args[i + 1]), context: context)
            print("XERO imported \(s.company): accounts \(s.accounts) banks \(s.bankAccounts) journals \(s.journals) taxlines \(s.linesWithTax) receipts \(s.receipts)")
            for w in s.warnings { print("XERO warning \(w)") }
            let book = LedgerBook(context: context)
            let journals = (try? context.fetch(FetchDescriptor<LedgerJournal>())) ?? []
            let cal = Calendar.current
            func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
            for (label, a, b) in [("FY2026", d(2025, 7, 1), d(2026, 7, 1)), ("FY2025", d(2024, 7, 1), d(2025, 7, 1)), ("2026-07-01..09-07", d(2026, 7, 1), d(2026, 9, 8))] {
                let p = Reports.postings(transactions: [], journals: journals, company: s.company, from: a, to: b, includeUnreconciled: true, book: book)
                let pl = Reports.profitAndLoss(p, book: book)
                print("XERO P&L \(label): income \(pl.totalIncome) expenses \(pl.totalExpenses) net \(pl.netProfit)")
                for l in pl.income + pl.expenses { print("XERO    \(l.code) \(l.name) \(l.amount)") }
            }
            for (y, m) in [(2024, 7), (2024, 10), (2025, 1), (2025, 4), (2025, 7), (2025, 10), (2026, 1), (2026, 4)] {
                let a = d(y, m, 1), b = cal.date(byAdding: .month, value: 3, to: a)!
                let g = Reports.gst(Reports.postings(transactions: [], journals: journals, company: s.company, from: a, to: b, includeUnreconciled: true, book: book))
                print("XERO GST \(y)-\(m): G1 \(g.g1TotalSales) 1A \(g.a1GSTOnSales) 1B \(g.b1GSTOnPurchases)")
            }
        } catch {
            print("XERO failed \(error)")
        }
    }
}
#endif
