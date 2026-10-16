import SwiftUI
import SwiftData

/// Ledger on iPhone: Xero style bookkeeping. Receipts come from the Receipts app through the
/// shared Receipts Library folder (Settings › Sync).
@main
struct LedgerApp: App {
    let container = StoreInfo.makeContainer()
    @State private var tab = ProcessInfo.processInfo.arguments.contains("-startReports") ? 2
        : ProcessInfo.processInfo.arguments.contains("-startBank") ? 1 : 0

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                Tab("Reconcile", systemImage: "checkmark.rectangle.stack", value: 0) {
                    NavigationStack { ReconcileView() }
                }
                Tab("Bank", systemImage: "building.columns", value: 1) {
                    NavigationStack { BankAccountsView() }
                }
                Tab("Reports", systemImage: "chart.bar.doc.horizontal", value: 2) {
                    NavigationStack { ReportsView() }
                }
                Tab("Accounts", systemImage: "list.number", value: 3) {
                    NavigationStack { ChartOfAccountsView() }
                }
                Tab("Settings", systemImage: "gearshape", value: 4) {
                    NavigationStack { LedgerSettingsView() }
                }
            }
            .periodicSync()
            .task {
                let context = container.mainContext
                CompanyStore.repairIDs(context)
                CompanyStore.seedIfNeeded(context)
                CompanyStore.applyFolds(context)
                Chart.seedIfNeeded(context)
                Chart.assignBankCodes(context)
                #if DEBUG
                await DemoData.loadIfRequested(context: context)
                Chart.assignBankCodes(context)
                if ProcessInfo.processInfo.arguments.contains("-reconcileAll") {
                    let book = LedgerBook(context: context)
                    let all = (try? context.fetch(FetchDescriptor<BankTransaction>())) ?? []
                    for t in all where !t.isReconciled { book.reconcile(t, context: context) }
                    // Every transaction's double entry must balance.
                    for t in all {
                        let sum = book.postings(for: t).reduce(0) { $0 + $1.amount }
                        if abs(sum) > 0.001 { print("LEDGER UNBALANCED \(t.details) \(sum)") }
                    }
                    let postings = Reports.postings(transactions: all, journals: [], company: nil, from: .distantPast,
                                                    to: .distantFuture, includeUnreconciled: true, book: book)
                    let pl = Reports.profitAndLoss(postings, book: book)
                    let g = Reports.gst(postings)
                    print("LEDGER P&L income \(pl.totalIncome) expenses \(pl.totalExpenses) net \(pl.netProfit)")
                    for l in pl.income + pl.expenses { print("LEDGER   \(l.code) \(l.name) \(l.amount)") }
                    print("LEDGER GST G1 \(g.g1TotalSales) 1A \(g.a1GSTOnSales) 1B \(g.b1GSTOnPurchases) net \(g.net)")
                }
                #endif
            }
        }
        .modelContainer(container)
    }
}

struct LedgerSettingsView: View {
    var body: some View {
        List {
            NavigationLink { LibrarySyncView() } label: {
                Label("Sync with Receipts and Mac", systemImage: "arrow.triangle.2.circlepath")
            }
            NavigationLink { CompaniesView() } label: {
                Label("Companies", systemImage: "building.2")
            }
            NavigationLink { JournalsView() } label: {
                Label("Journals", systemImage: "book.closed")
            }
            NavigationLink { XeroImportView() } label: {
                Label("Import from Xero", systemImage: "square.and.arrow.down.on.square")
            }
            if let problem = StoreInfo.loadError {
                Text("Saved data could not be opened, so nothing was changed. \(problem)").foregroundStyle(.red)
            }
        }
        .navigationTitle("Settings")
    }
}
