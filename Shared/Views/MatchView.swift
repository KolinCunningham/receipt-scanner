import SwiftUI
import SwiftData

/// Reconcile: suggested receipt and bank pairs, spending with no receipt, receipts not seen in the bank.
struct MatchView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Receipt.date, order: .reverse) private var receipts: [Receipt]
    @Query(sort: \BankTransaction.date, order: .reverse) private var transactions: [BankTransaction]

    @State private var pairs: [Matcher.Pair] = []
    @State private var skipped = Set<String>()

    private var receiptByID: [UUID: Receipt] {
        Dictionary(receipts.map { ($0.receiptID, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var transactionByID: [UUID: BankTransaction] {
        Dictionary(transactions.map { ($0.transactionID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var openPairs: [Matcher.Pair] { pairs.filter { !skipped.contains($0.id) } }
    private var needsReceipt: [BankTransaction] { transactions.filter { $0.status == .needsReceipt } }
    private var unseenReceipts: [Receipt] {
        let weekAgo = Date.now.addingTimeInterval(-7 * 86400)
        return receipts.filter { $0.bankTransaction == nil && !$0.isProcessing && $0.date < weekAgo }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    StatTile(value: "\(transactions.filter { $0.status == .matched }.count)", label: "Matched", color: .green)
                    StatTile(value: "\(needsReceipt.count)", label: "Need a receipt", color: .orange)
                    StatTile(value: "\(openPairs.count)", label: "Suggestions", color: .accentColor)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if transactions.isEmpty {
                    Text("Import a bank statement in Bank to start matching.")
                        .foregroundStyle(.secondary)
                } else if openPairs.isEmpty {
                    Text("No suggestions right now. New receipts and statements are matched automatically when the match is certain.")
                        .foregroundStyle(.secondary)
                }
                ForEach(openPairs) { pair in
                    if let r = receiptByID[pair.receiptID], let t = transactionByID[pair.transactionID] {
                        PairRow(receipt: r, transaction: t, pair: pair) {
                            Ledger.link(r, t, by: "You", context: context)
                            refresh()
                        } onSkip: {
                            skipped.insert(pair.id)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Suggested matches")
                    Spacer()
                    if openPairs.contains(where: \.isConfident) {
                        Button("Accept all sure ones") {
                            Ledger.autoMatch(context: context)
                            refresh()
                        }
                        .font(.caption)
                    }
                }
            }

            if !needsReceipt.isEmpty {
                Section("Spending without a receipt") {
                    ForEach(needsReceipt.prefix(100)) { t in
                        NavigationLink(value: t) { TransactionRow(transaction: t) }
                    }
                    if needsReceipt.count > 100 {
                        Text("and \(needsReceipt.count - 100) more").foregroundStyle(.secondary)
                    }
                }
            }

            if !unseenReceipts.isEmpty && !transactions.isEmpty {
                Section {
                    ForEach(unseenReceipts.prefix(50)) { r in
                        NavigationLink(value: r) { ReceiptMiniRow(receipt: r) }
                    }
                } header: {
                    Text("Receipts not found in the bank")
                } footer: {
                    Text("Older than a week with no matching transaction. Maybe paid from an account you have not imported, paid in cash, or the amount was read wrongly.")
                }
            }
        }
        .navigationTitle("Match")
        .navigationDestination(for: BankTransaction.self) { TransactionDetailView(transaction: $0) }
        .navigationDestination(for: Receipt.self) { ReceiptEditView(receipt: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { refresh() } label: { Label("Find matches", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: transactions.count) { refresh() }
        .onChange(of: receipts.count) { refresh() }
    }

    private func refresh() {
        pairs = Ledger.suggestions(context: context)
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

struct PairRow: View {
    let receipt: Receipt
    let transaction: BankTransaction
    let pair: Matcher.Pair
    var onAccept: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReceiptMiniRow(receipt: receipt)
            HStack(spacing: 10) {
                Image(systemName: "building.columns").frame(width: 34)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transaction.merchantName).lineLimit(1)
                    Text("\(transaction.amount.formatted(.currency(code: transaction.account?.currency ?? "AUD"))) · \(transaction.date.formatted(date: .abbreviated, time: .omitted)) · \(transaction.account?.name ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(pair.reason) · \(Int(pair.score * 100))% sure")
                    .font(.caption)
                    .foregroundStyle(pair.isConfident ? Color.green : Color.secondary)
                Spacer()
                Button("Skip", action: onSkip).buttonStyle(.bordered)
                Button("Match", action: onAccept).buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
