import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: Accounts

struct BankAccountsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BankAccount.name) private var accounts: [BankAccount]
    @State private var showAdd = false
    @State private var deleting: BankAccount?

    var body: some View {
        List {
            if accounts.isEmpty {
                ContentUnavailableView {
                    Label("No bank accounts yet", systemImage: "building.columns")
                } description: {
                    Text("Add each business and personal account, then import a statement exported from your internet banking as CSV or OFX.")
                } actions: {
                    Button("Add account") { showAdd = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            ForEach(["Business", "Personal"], id: \.self) { kind in
                let list = accounts.filter { $0.kind == kind }
                if !list.isEmpty {
                    Section(kind) {
                        ForEach(list) { account in
                            NavigationLink(value: account) { AccountRow(account: account) }
                                .contextMenu {
                                    Button("Delete account", role: .destructive) { deleting = account }
                                }
                                .swipeActions {
                                    Button("Delete", role: .destructive) { deleting = account }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("Bank")
        .navigationDestination(for: BankAccount.self) { TransactionsView(account: $0) }
        .navigationDestination(for: BankTransaction.self) { TransactionDetailView(transaction: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("Add account", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack { AccountEditor(account: nil) }
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete account and its transactions", role: .destructive) {
                if let a = deleting { context.delete(a); try? context.save() }
                deleting = nil
            }
        } message: {
            Text("Receipts are kept. Only the imported bank transactions are removed.")
        }
    }
}

struct AccountRow: View {
    let account: BankAccount

    var body: some View {
        let txns = account.transactions ?? []
        let missing = txns.filter { $0.status == .needsReceipt }.count
        let latest = txns.max { $0.date < $1.date }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(account.name).font(.headline)
                Spacer()
                if let balance = latest?.balance {
                    Text(balance, format: .currency(code: account.currency)).monospacedDigit()
                }
            }
            Text([account.institution, account.company?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(txns.isEmpty ? "No transactions imported" : missing == 0 ? "\(txns.count) transactions, all sorted" : "\(txns.count) transactions, \(missing) need a receipt")
                .font(.caption)
                .foregroundStyle(missing == 0 ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 2)
    }
}

struct AccountEditor: View {
    let account: BankAccount?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Company.name) private var companies: [Company]

    @State private var name = ""
    @State private var institution = ""
    @State private var kind = "Business"
    @State private var companyName = ""
    @State private var currency = "AUD"

    var body: some View {
        Form {
            TextField("Account name, e.g. Business Everyday", text: $name)
            TextField("Bank, e.g. CommBank", text: $institution)
            Picker("Type", selection: $kind) {
                Text("Business").tag("Business")
                Text("Personal").tag("Personal")
            }
            Picker("Company", selection: $companyName) {
                Text("None").tag("")
                ForEach(companies) { Text($0.name).tag($0.name) }
            }
            TextField("Currency", text: $currency)
        }
        .formStyle(.grouped)
        .navigationTitle(account == nil ? "New account" : "Edit account")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let a = account else { return }
            name = a.name
            institution = a.institution
            kind = a.kind
            companyName = a.company?.name ?? ""
            currency = a.currency
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func save() {
        let a = account ?? BankAccount(name: "")
        if account == nil { context.insert(a) }
        a.name = name.trimmingCharacters(in: .whitespaces)
        a.institution = institution.trimmingCharacters(in: .whitespaces)
        a.kind = kind
        a.currency = currency.isEmpty ? "AUD" : currency.uppercased()
        let newCompany = companies.first { $0.name == companyName }
        if a.company?.persistentModelID != newCompany?.persistentModelID {
            a.company = newCompany
            // Give transactions without a company the account's company.
            for t in a.transactions ?? [] where t.company == nil { t.company = newCompany }
        }
        try? context.save()
        Chart.assignBankCodes(context)
        dismiss()
    }
}

// MARK: Transactions

enum TransactionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsReceipt = "Needs receipt"
    case matched = "Matched"
    case moneyIn = "Money in"
    var id: String { rawValue }
}

struct TransactionsView: View {
    @Bindable var account: BankAccount
    @Environment(\.modelContext) private var context
    @State private var filter: TransactionFilter = .all
    @State private var search = ""
    @State private var showImporter = false
    @State private var showEdit = false
    @State private var importing = false
    @State private var message: String?

    private static let statementTypes: [UTType] = [
        .commaSeparatedText, .plainText, .text,
        UTType(filenameExtension: "ofx") ?? .data,
        UTType(filenameExtension: "qfx") ?? .data,
    ]

    private var shown: [BankTransaction] {
        (account.transactions ?? [])
            .filter { t in
                switch filter {
                case .all: true
                case .needsReceipt: t.status == .needsReceipt
                case .matched: t.status == .matched
                case .moneyIn: t.amount > 0
                }
            }
            .filter { search.isEmpty || $0.details.localizedCaseInsensitiveContains(search) || $0.category.rawValue.localizedCaseInsensitiveContains(search) }
            .sorted { $0.date == $1.date ? $0.importedAt > $1.importedAt : $0.date > $1.date }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(TransactionFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section {
                if (account.transactions ?? []).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import a statement").font(.headline)
                        Text("In your internet banking, export transactions for this account as CSV (or OFX/QFX), save the file, then tap Import. Importing an overlapping date range is fine; duplicates are skipped.")
                            .foregroundStyle(.secondary)
                        Button("Import statement") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 6)
                }
                ForEach(shown) { t in
                    NavigationLink(value: t) { TransactionRow(transaction: t) }
                        .swipeActions {
                            if t.status == .needsReceipt {
                                Button("No receipt needed") { t.status = .noReceiptNeeded; try? context.save() }
                                    .tint(.gray)
                            } else if t.status == .noReceiptNeeded {
                                Button("Needs receipt") { t.status = .needsReceipt; try? context.save() }
                                    .tint(.orange)
                            }
                        }
                }
            } header: {
                let out = shown.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }
                HStack {
                    Text("\(shown.count) transactions")
                    Spacer()
                    Text("Spent \((-out).formatted(.currency(code: account.currency)))")
                }
            }
        }
        .searchable(text: $search, prompt: "Search transactions")
        .navigationTitle(account.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if importing { ProgressView().controlSize(.small) }
                Button { showImporter = true } label: { Label("Import statement", systemImage: "square.and.arrow.down") }
                    .disabled(importing)
                Button { showEdit = true } label: { Label("Edit account", systemImage: "pencil") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.statementTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await importFiles(urls) }
        }
        .sheet(isPresented: $showEdit) {
            NavigationStack { AccountEditor(account: account) }
        }
        .alert("Import", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func importFiles(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        var added = 0, duplicates = 0, matched = 0
        var problems: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let parsed = try BankImport.parse(data: data, fileName: url.lastPathComponent)
                let summary = await Ledger.importTransactions(parsed, into: account, context: context)
                added += summary.added
                duplicates += summary.duplicates
                matched += summary.autoMatched
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        var lines = ["Added \(added) transactions."]
        if duplicates > 0 { lines.append("Skipped \(duplicates) already imported.") }
        if matched > 0 { lines.append("Matched \(matched) to receipts automatically.") }
        lines += problems
        message = lines.joined(separator: "\n")
        await CloudDriveSync.shared.sync(context: context)
    }
}

struct TransactionRow: View {
    let transaction: BankTransaction

    var body: some View {
        let t = transaction
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(t.merchantName).lineLimit(1)
                HStack(spacing: 6) {
                    Text(t.date, format: .dateTime.day().month(.abbreviated).year())
                    Text("·")
                    Text(t.category.rawValue)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(t.amount, format: .currency(code: t.account?.currency ?? "AUD"))
                .monospacedDigit()
                .foregroundStyle(t.amount > 0 ? Color.green : Color.primary)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch transaction.status {
        case .matched:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsReceipt:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        case .noReceiptNeeded:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: Transaction detail

struct TransactionDetailView: View {
    @Bindable var transaction: BankTransaction
    @Environment(\.modelContext) private var context
    @Query(sort: \Company.name) private var companies: [Company]
    @Query(sort: \Receipt.date, order: .reverse) private var receipts: [Receipt]

    private var categoryBinding: Binding<ReceiptCategory> {
        Binding {
            transaction.category
        } set: { newValue in
            transaction.category = newValue
            transaction.classifiedBy = "You"
            // Apply to other transactions from the same merchant you have not set yourself.
            let key = BankText.key(transaction.merchantName)
            let all = (try? context.fetch(FetchDescriptor<BankTransaction>())) ?? []
            for other in all where other.classifiedBy != "You" && other.receipt == nil && BankText.key(other.merchantName) == key {
                other.category = newValue
                other.classifiedBy = "Your earlier choices"
            }
            try? context.save()
        }
    }

    private var companyBinding: Binding<String> {
        Binding { transaction.company?.name ?? "" } set: { name in
            transaction.company = companies.first { $0.name == name }
            try? context.save()
        }
    }

    private var statusBinding: Binding<Bool> {
        Binding { transaction.status == .noReceiptNeeded } set: {
            transaction.status = $0 ? .noReceiptNeeded : .needsReceipt
            try? context.save()
        }
    }

    /// Unmatched receipts that could be this payment, best first.
    private var candidates: [(Receipt, Double, String)] {
        let t = transaction
        let info = Matcher.TransactionInfo(id: t.transactionID, date: t.date, amount: t.amount, details: t.details)
        return receipts
            .filter { $0.bankTransaction == nil && !$0.isProcessing }
            .compactMap { r -> (Receipt, Double, String)? in
                let ri = Matcher.ReceiptInfo(id: r.receiptID, date: r.date, total: r.total, merchant: r.merchant, currency: r.currency)
                guard let (s, why) = Matcher.score(ri, info, accountCurrency: t.account?.currency ?? "AUD") else { return nil }
                return (r, s, why)
            }
            .sorted { $0.1 > $1.1 }
    }

    /// Other unmatched receipts within ten days, for picking by hand.
    private var nearby: [Receipt] {
        let ids = Set(candidates.map { $0.0.receiptID })
        return receipts.filter { r in
            r.bankTransaction == nil && !ids.contains(r.receiptID) && abs(r.date.timeIntervalSince(transaction.date)) < 10 * 86400
        }
    }

    var body: some View {
        let t = transaction
        Form {
            Section {
                LabeledContent("Amount") {
                    Text(t.amount, format: .currency(code: t.account?.currency ?? "AUD"))
                        .foregroundStyle(t.amount > 0 ? Color.green : Color.primary)
                }
                LabeledContent("Date", value: t.date.formatted(date: .long, time: .omitted))
                LabeledContent("Account", value: t.account?.name ?? "")
                if let b = t.balance {
                    LabeledContent("Balance after", value: b.formatted(.currency(code: t.account?.currency ?? "AUD")))
                }
                Text(t.details).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section {
                Picker("Category", selection: categoryBinding) {
                    ForEach(ReceiptCategory.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                Picker("Company", selection: companyBinding) {
                    Text("None").tag("")
                    ForEach(companies) { Text($0.name).tag($0.name) }
                }
            } footer: {
                if !t.classifiedBy.isEmpty { Text("Category chosen by \(t.classifiedBy).") }
            }

            LedgerCodingSection(transaction: t)

            if let r = t.receipt {
                Section("Receipt") {
                    NavigationLink {
                        ReceiptEditView(receipt: r)
                    } label: {
                        ReceiptMiniRow(receipt: r)
                    }
                    Button("Unmatch", role: .destructive) { Ledger.unlink(t, context: context) }
                }
            } else {
                Section {
                    Toggle("No receipt needed", isOn: statusBinding)
                }
                if t.status == .needsReceipt {
                    Section("Likely receipts") {
                        if candidates.isEmpty {
                            Text("No receipt with this amount around this date. Scan it, or pick one below.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(candidates, id: \.0.receiptID) { r, score, why in
                            HStack {
                                ReceiptMiniRow(receipt: r, caption: "\(why) · \(Int(score * 100))% sure")
                                Spacer()
                                Button("Match") { Ledger.link(r, t, by: "You", context: context) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    if !nearby.isEmpty {
                        Section("Other receipts near this date") {
                            ForEach(nearby) { r in
                                HStack {
                                    ReceiptMiniRow(receipt: r)
                                    Spacer()
                                    Button("Match") { Ledger.link(r, t, by: "You", context: context) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }

            Section("Notes") {
                TextField("Notes", text: $transaction.notes, axis: .vertical)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(t.merchantName)
        .inlineTitle()
        .onDisappear { try? context.save() }
    }
}

struct ReceiptMiniRow: View {
    let receipt: Receipt
    var caption: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let data = receipt.thumbnailData, let image = PlatformImage(data: data) {
                    Image(platformImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.merchant.isEmpty ? "Unknown merchant" : receipt.merchant).lineLimit(1)
                Text(caption ?? "\(receipt.total.formatted(.currency(code: receipt.currency))) · \(receipt.date.formatted(date: .abbreviated, time: .omitted)) · \(receipt.company?.name ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
