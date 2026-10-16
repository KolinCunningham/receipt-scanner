import SwiftUI
import SwiftData

// MARK: Reconcile

/// Xero style: each bank line with its suggested account and tax, OK to accept or tap to change.
struct ReconcileView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BankTransaction.date, order: .reverse) private var transactions: [BankTransaction]
    @Query(sort: \LedgerAccount.code) private var ledgerAccounts: [LedgerAccount]
    @Query(sort: \Company.name) private var companies: [Company]
    @State private var companyFilter = ""
    @State private var showDone = false

    private var book: LedgerBook { LedgerBook(context: context) }

    private var open: [BankTransaction] {
        transactions.filter { !$0.isReconciled && (companyFilter.isEmpty || $0.company?.name == companyFilter) }
    }
    private var done: [BankTransaction] {
        transactions.filter { $0.isReconciled && (companyFilter.isEmpty || $0.company?.name == companyFilter) }
    }

    var body: some View {
        let book = self.book
        List {
            Section {
                Picker("Company", selection: $companyFilter) {
                    Text("All companies").tag("")
                    ForEach(companies) { Text($0.name).tag($0.name) }
                }
            }
            Section {
                if transactions.isEmpty {
                    Text("Import a bank statement in Bank first. Each line then shows up here to code and reconcile.")
                        .foregroundStyle(.secondary)
                } else if open.isEmpty {
                    Label("All reconciled", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                ForEach(open) { t in
                    ReconcileRow(transaction: t, coding: book.coding(for: t)) {
                        book.reconcile(t, context: context)
                    }
                }
            } header: {
                HStack {
                    Text("\(open.count) to reconcile")
                    Spacer()
                    let ready = open.filter { $0.receipt != nil }
                    if !ready.isEmpty {
                        Button("OK all \(ready.count) with receipts") {
                            for t in ready { book.reconcile(t, context: context) }
                        }
                        .font(.caption)
                    }
                }
            } footer: {
                Text("Suggested accounts come from the category. Tap a line to change the account, tax rate or receipt. Check the GST treatment of entertainment and anything unusual with your accountant.")
            }
            if !done.isEmpty {
                Section {
                    DisclosureGroup("Reconciled (\(done.count))", isExpanded: $showDone) {
                        ForEach(done.prefix(200)) { t in
                            NavigationLink(value: t) { ReconciledRow(transaction: t, coding: book.coding(for: t)) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Reconcile")
        .navigationDestination(for: BankTransaction.self) { TransactionDetailView(transaction: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { MatchView() } label: { Label("Match receipts", systemImage: "link") }
            }
        }
        .onAppear { Chart.seedIfNeeded(context); Chart.assignBankCodes(context) }
    }
}

struct ReconcileRow: View {
    let transaction: BankTransaction
    let coding: Coding
    var onOK: () -> Void

    var body: some View {
        let t = transaction
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: t) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.merchantName).font(.headline).lineLimit(1)
                        Text("\(t.date.formatted(date: .abbreviated, time: .omitted)) · \(t.account?.name ?? "") · \(t.company?.name ?? "No company")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(t.amount, format: .currency(code: t.account?.currency ?? "AUD"))
                        .monospacedDigit()
                        .foregroundStyle(t.amount > 0 ? Color.green : Color.primary)
                }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(coding.account?.label ?? "\(coding.code) · not in chart")
                        .font(.subheadline)
                        .foregroundStyle(coding.account == nil ? Color.orange : Color.primary)
                    HStack(spacing: 4) {
                        Text(coding.tax.name)
                        if coding.gst > 0 { Text("· GST \(coding.gst.formatted(.currency(code: "AUD")))") }
                        if t.receipt != nil { Label("receipt", systemImage: "paperclip").labelStyle(.titleAndIcon) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("OK", action: onOK)
                    .buttonStyle(.borderedProminent)
                    .disabled(coding.account == nil)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
        .padding(.vertical, 4)
    }
}

struct ReconciledRow: View {
    let transaction: BankTransaction
    let coding: Coding

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchantName).lineLimit(1)
                Text("\(transaction.date.formatted(date: .abbreviated, time: .omitted)) · \(coding.account?.label ?? coding.code)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(transaction.amount, format: .currency(code: "AUD")).monospacedDigit()
        }
    }
}

/// Account, tax rate and reconcile controls, shown inside the transaction detail screen.
struct LedgerCodingSection: View {
    @Bindable var transaction: BankTransaction
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerAccount.code) private var ledgerAccounts: [LedgerAccount]

    var body: some View {
        let book = LedgerBook(context: context)
        let c = book.coding(for: transaction)
        Section {
            Picker("Account", selection: Binding(get: { c.code }, set: { setCode($0) })) {
                if c.account == nil { Text("\(c.code) · not in chart").tag(c.code) }
                ForEach(book.accounts(for: transaction.company?.name)) { Text($0.label).tag($0.code) }
            }
            Picker("Tax rate", selection: Binding(get: { c.tax }, set: { transaction.taxTypeRaw = $0.rawValue; save() })) {
                ForEach(TaxType.allCases) { Text($0.name).tag($0) }
            }
            LabeledContent("GST", value: c.gst.formatted(.currency(code: "AUD")))
            if transaction.isReconciled {
                Label("Reconciled", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Button("Undo reconcile") { transaction.isReconciled = false; save() }
            } else {
                Button("OK, reconcile") { book.reconcile(transaction, context: context) }
                    .disabled(c.account == nil)
            }
        } header: {
            Text("Ledger")
        } footer: {
            Text("GST is taken from the matched receipt when it shows one, otherwise one eleventh of the amount for GST rates.")
        }
    }

    private func setCode(_ code: String) {
        transaction.ledgerCode = code
        transaction.taxTypeRaw = ""   // follow the new account's default tax rate
        // Same merchant, not yet reconciled and not set by hand: follow this choice.
        let key = BankText.key(transaction.merchantName)
        let all = (try? context.fetch(FetchDescriptor<BankTransaction>())) ?? []
        for other in all where !other.isReconciled && other.ledgerCode.isEmpty
            && other.persistentModelID != transaction.persistentModelID && BankText.key(other.merchantName) == key {
            other.ledgerCode = code
        }
        save()
    }

    private func save() { try? context.save() }
}

// MARK: Chart of accounts

struct ChartOfAccountsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerAccount.code) private var accounts: [LedgerAccount]
    @Query(sort: \Company.name) private var companies: [Company]
    @State private var editing: LedgerAccount?
    @State private var adding = false
    @State private var showArchived = false
    /// Empty means the standard chart.
    @State private var chartCompany = ""

    private var companiesWithCharts: [Company] {
        companies.filter { !($0.ledgerAccounts ?? []).isEmpty }
    }

    var body: some View {
        List {
            if !companiesWithCharts.isEmpty {
                Section {
                    Picker("Chart", selection: $chartCompany) {
                        Text("Standard chart").tag("")
                        ForEach(companiesWithCharts) { Text($0.name).tag($0.name) }
                    }
                } footer: {
                    Text(chartCompany.isEmpty ? "Used by every company without its own chart." : "\(chartCompany) has its own chart, imported from its Xero file.")
                }
            }
            ForEach(LedgerAccountType.allCases.filter { $0 != .bank }) { type in
                let list = accounts.filter {
                    $0.type == type && (showArchived || !$0.isArchived)
                        && ($0.company?.name ?? "") == chartCompany
                }
                if !list.isEmpty {
                    Section(type.name) {
                        ForEach(list) { a in
                            Button { editing = a } label: {
                                HStack {
                                    Text(a.code).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                                    VStack(alignment: .leading) {
                                        Text(a.name).foregroundStyle(a.isArchived ? .secondary : .primary)
                                        Text(a.taxType.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section {
                Toggle("Show archived accounts", isOn: $showArchived)
            } footer: {
                Text("Standard chart is based on Xero's Australian chart. Bank accounts appear in Bank.")
            }
        }
        .navigationTitle("Chart of Accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add account", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { a in NavigationStack { LedgerAccountEditor(account: a, company: a.company) } }
        .sheet(isPresented: $adding) {
            NavigationStack { LedgerAccountEditor(account: nil, company: companies.first { $0.name == chartCompany }) }
        }
        .onAppear { Chart.seedIfNeeded(context) }
    }
}

struct LedgerAccountEditor: View {
    let account: LedgerAccount?
    var company: Company? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var all: [LedgerAccount]
    @State private var code = ""
    @State private var name = ""
    @State private var type = LedgerAccountType.expense
    @State private var tax = TaxType.gstOnExpenses
    @State private var archived = false
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Code, e.g. 486", text: $code)
            TextField("Name", text: $name)
            Picker("Type", selection: $type) {
                ForEach(LedgerAccountType.allCases.filter { $0 != .bank }) { Text($0.name).tag($0) }
            }
            Picker("Default tax rate", selection: $tax) {
                ForEach(TaxType.allCases) { Text($0.name).tag($0) }
            }
            if account != nil {
                Toggle("Archived (hidden from pickers, kept in reports)", isOn: $archived)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(account == nil ? "New account" : "Edit account")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }
        .onAppear {
            guard let a = account else { return }
            code = a.code; name = a.name; type = a.type; tax = a.taxType; archived = a.isArchived
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }

    private func save() {
        let c = code.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !n.isEmpty else { error = "Enter a code and a name."; return }
        if all.contains(where: { $0.code == c && $0.company?.persistentModelID == company?.persistentModelID
                && $0.persistentModelID != account?.persistentModelID }) {
            error = "Code \(c) is already used."
            return
        }
        let a = account ?? {
            let n = LedgerAccount(code: c, name: n, type: type, tax: tax)
            context.insert(n)
            n.company = company
            if let company { n.ledgerAccountID = StableID.make("ledger:\(company.companyID.uuidString):\(c)") }
            return n
        }()
        // Changing a code would orphan transactions coded to it, so keep codes fixed once used.
        if account == nil { a.code = c }
        a.name = n
        a.type = type
        a.taxType = tax
        a.isArchived = archived
        try? context.save()
        dismiss()
    }
}

// MARK: Reports

enum ReportKind: String, CaseIterable, Identifiable {
    case profitAndLoss = "Profit & Loss"
    case gst = "GST (BAS)"
    var id: String { rawValue }
}

struct ReportsView: View {
    @Environment(\.modelContext) private var context
    @Query private var transactions: [BankTransaction]
    @Query private var journals: [LedgerJournal]
    @Query(sort: \Company.name) private var companies: [Company]
    @State private var kind = ReportKind.profitAndLoss
    @State private var period = ReportPeriod.thisFinancialYear
    @State private var company = ""
    @State private var includeUnreconciled = false
    @State private var shareFile: URL?
    @State private var showShare = false

    var body: some View {
        let book = LedgerBook(context: context)
        let (start, end) = period.range()
        let postings = Reports.postings(transactions: transactions, journals: journals, company: company.isEmpty ? nil : company,
                                        from: start, to: end, includeUnreconciled: includeUnreconciled, book: book)
        let txns = Reports.transactions(transactions, company: company.isEmpty ? nil : company, period: period, includeUnreconciled: includeUnreconciled)
        let unreconciled = Reports.transactions(transactions, company: company.isEmpty ? nil : company, period: period, includeUnreconciled: true)
            .filter { !$0.isReconciled }.count
        Form {
            Section {
                Picker("Report", selection: $kind) {
                    ForEach(ReportKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Company", selection: $company) {
                    Text("All companies").tag("")
                    ForEach(companies) { Text($0.name).tag($0.name) }
                }
                Picker("Period", selection: $period) {
                    ForEach(ReportPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Include unreconciled (as suggested)", isOn: $includeUnreconciled)
            } footer: {
                VStack(alignment: .leading) {
                    Text(period.label())
                    if unreconciled > 0 && !includeUnreconciled {
                        Text("\(unreconciled) transactions in this period are not reconciled yet and are left out.")
                            .foregroundStyle(.orange)
                    }
                }
            }

            switch kind {
            case .profitAndLoss:
                let pl = Reports.profitAndLoss(postings, book: book)
                ReportSection(title: "Income", lines: pl.income, total: pl.totalIncome)
                if !pl.directCosts.isEmpty {
                    ReportSection(title: "Less Cost of Sales", lines: pl.directCosts, total: pl.totalDirectCosts)
                    Section { TotalRow(label: "Gross Profit", value: pl.grossProfit) }
                }
                ReportSection(title: "Less Operating Expenses", lines: pl.expenses, total: pl.totalExpenses)
                Section { TotalRow(label: "Net Profit", value: pl.netProfit) }
            case .gst:
                let g = Reports.gst(postings)
                Section {
                    LabeledContent("G1 Total sales (incl GST)", value: g.g1TotalSales.formatted(.currency(code: "AUD")))
                    LabeledContent("1A GST on sales", value: g.a1GSTOnSales.formatted(.currency(code: "AUD")))
                    LabeledContent("1B GST on purchases", value: g.b1GSTOnPurchases.formatted(.currency(code: "AUD")))
                } header: {
                    Text("Simpler BAS, cash basis")
                } footer: {
                    Text("Worked out from reconciled bank transactions and journals (including history imported from Xero) and their tax rates. Your BAS agent or accountant should confirm before lodging.")
                }
                Section {
                    TotalRow(label: g.net >= 0 ? "GST payable" : "GST refund", value: abs(g.net))
                }
            }

            Section {
                Button { export(book: book, txns: txns, postings: postings) } label: {
                    Label("Export for accountant (Excel + Xero statement CSVs)", systemImage: "square.and.arrow.up")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Reports")
        .sheet(isPresented: $showShare) {
            if let url = shareFile { ShareSheet(url: url) }
        }
        .onAppear { Chart.seedIfNeeded(context) }
    }

    private func export(book: LedgerBook, txns: [BankTransaction], postings: [Posting]) {
        do {
            shareFile = try XeroExport.makePackage(transactions: txns, postings: postings, book: book,
                                                   company: company.isEmpty ? "All companies" : company,
                                                   period: period)
            showShare = true
        } catch {}
    }
}

struct ReportSection: View {
    let title: String
    let lines: [ProfitAndLoss.Line]
    let total: Double

    var body: some View {
        Section(title) {
            if lines.isEmpty { Text("Nothing in this period").foregroundStyle(.secondary) }
            ForEach(lines) { l in
                LabeledContent("\(l.code) \(l.name)", value: l.amount.formatted(.currency(code: "AUD")))
            }
            TotalRow(label: "Total \(title.replacingOccurrences(of: "Less ", with: ""))", value: total)
        }
    }
}

struct TotalRow: View {
    let label: String
    let value: Double
    var body: some View {
        LabeledContent {
            Text(value, format: .currency(code: "AUD")).bold().monospacedDigit()
        } label: {
            Text(label).bold()
        }
    }
}

// MARK: Export

@MainActor
enum XeroExport {
    /// A folder with an Excel workbook for the accountant and one Xero statement CSV per bank account.
    static func makePackage(transactions: [BankTransaction], postings: [Posting], book: LedgerBook, company: String, period: ReportPeriod) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Ledger \(CloudDriveSync.safeFileName(company)) \(f.string(from: .now))")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try workbook(transactions, postings: postings, book: book, company: company, period: period)
            .write(to: folder.appending(path: "Ledger \(CloudDriveSync.safeFileName(company)).xlsx"))

        // Xero bank statement import: Date, Amount, Payee, Description, Reference (money out negative).
        let byAccount = Dictionary(grouping: transactions, by: { $0.account?.name ?? "Unknown account" })
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_AU_POSIX")
        d.dateFormat = "dd/MM/yyyy"
        for (name, list) in byAccount {
            var csv = "Date,Amount,Payee,Description,Reference\n"
            for t in list.sorted(by: { $0.date < $1.date }) {
                csv += [d.string(from: t.date), String(format: "%.2f", t.amount), quote(t.merchantName), quote(t.details), quote(t.notes)]
                    .joined(separator: ",") + "\n"
            }
            try Data(csv.utf8).write(to: folder.appending(path: "Xero statement - \(CloudDriveSync.safeFileName(name)).csv"))
        }
        return folder
    }

    private static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    static func workbook(_ txns: [BankTransaction], postings: [Posting], book: LedgerBook, company: String, period: ReportPeriod) -> Data {
        typealias C = XLSXWriter.Cell
        let pl = Reports.profitAndLoss(postings, book: book)
        var plRows: [[C]] = [[.header("Profit & Loss"), .header(company)], [.text(period.label()), .empty], []]
        func block(_ title: String, _ lines: [ProfitAndLoss.Line], _ total: Double) {
            plRows.append([.boldText(title)])
            for l in lines { plRows.append([.text("\(l.code) \(l.name)"), .money(l.amount)]) }
            plRows.append([.boldText("Total"), .money(total)])
            plRows.append([])
        }
        block("Income", pl.income, pl.totalIncome)
        if !pl.directCosts.isEmpty { block("Less Cost of Sales", pl.directCosts, pl.totalDirectCosts) }
        block("Less Operating Expenses", pl.expenses, pl.totalExpenses)
        plRows.append([.boldText("Net Profit"), .money(pl.netProfit)])

        let g = Reports.gst(postings)
        let gstRows: [[C]] = [
            [.header("GST (Simpler BAS, cash basis)"), .header(company)],
            [.text(period.label()), .empty], [],
            [.text("G1 Total sales (incl GST)"), .money(g.g1TotalSales)],
            [.text("1A GST on sales"), .money(g.a1GSTOnSales)],
            [.text("1B GST on purchases"), .money(g.b1GSTOnPurchases)],
            [.boldText(g.net >= 0 ? "GST payable" : "GST refund"), .money(abs(g.net))],
        ]

        var coded: [[C]] = [[.header("Date"), .header("Bank account"), .header("Company"), .header("Payee"), .header("Amount"),
                             .header("Account code"), .header("Account"), .header("Tax rate"), .header("GST"),
                             .header("Reconciled"), .header("Receipt"), .header("Bank description")]]
        for t in txns.sorted(by: { $0.date < $1.date }) {
            let c = book.coding(for: t)
            coded.append([.date(t.date), .text(t.account?.name ?? ""), .text(t.company?.name ?? ""), .text(t.merchantName),
                          .money(t.amount), .text(c.code), .text(c.account?.name ?? ""), .text(c.tax.name), .money(c.gst),
                          .text(t.isReconciled ? "Yes" : "No"), .text(t.receipt == nil ? "" : "Yes"), .text(t.details)])
        }

        var journal: [[C]] = [[.header("Date"), .header("Company"), .header("Account code"), .header("Account"),
                               .header("Debit"), .header("Credit"), .header("Tax rate"), .header("GST")]]
        for p in postings.sorted(by: { ($0.date, $0.sourceID.uuidString) < ($1.date, $1.sourceID.uuidString) }) {
            let name = book.account(p.code, company: p.company)?.name ?? p.name
            journal.append([.date(p.date), .text(p.company), .text(p.code), .text(name),
                            p.amount > 0 ? .money(p.amount) : .empty, p.amount < 0 ? .money(-p.amount) : .empty,
                            .text(p.taxType?.name ?? ""), p.tax != 0 ? .money(p.tax) : .empty])
        }

        return XLSXWriter.makeWorkbook([
            .init(name: "Profit & Loss", columnWidths: [36, 16], rows: plRows, freezeHeader: false),
            .init(name: "GST", columnWidths: [36, 16], rows: gstRows, freezeHeader: false),
            .init(name: "Coded transactions", columnWidths: [12, 22, 20, 26, 12, 10, 26, 18, 10, 10, 9, 50], rows: coded),
            .init(name: "Journal", columnWidths: [12, 20, 10, 28, 12, 12, 18, 10], rows: journal),
        ])
    }
}
