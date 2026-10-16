import Foundation
import SwiftData

// Xero style bookkeeping on top of the bank transactions.
// Chart of accounts and tax codes follow Xero's standard Australian organisation, so codes and
// tax rate names match what an accountant sees in Xero. Tax type codes are Xero's own
// (see Reference/Xero-OpenAPI/xero_accounting.yaml, TaxType).

enum TaxType: String, CaseIterable, Identifiable, Codable {
    case gstOnIncome = "OUTPUT"
    case gstOnExpenses = "INPUT"
    case gstOnCapital = "CAPEXINPUT"
    case gstFreeIncome = "EXEMPTOUTPUT"
    case gstFreeExpenses = "EXEMPTEXPENSES"
    case gstFreeExports = "EXEMPTEXPORT"
    case inputTaxed = "INPUTTAXED"
    case basExcluded = "BASEXCLUDED"
    case gstOnImports = "GSTONIMPORTS"

    var id: String { rawValue }

    /// The name Xero shows for an Australian organisation.
    var name: String {
        switch self {
        case .gstOnIncome: "GST on Income"
        case .gstOnExpenses: "GST on Expenses"
        case .gstOnCapital: "GST on Capital"
        case .gstFreeIncome: "GST Free Income"
        case .gstFreeExpenses: "GST Free Expenses"
        case .gstFreeExports: "GST Free Exports"
        case .inputTaxed: "Input Taxed"
        case .basExcluded: "BAS Excluded"
        case .gstOnImports: "GST on Imports"
        }
    }

    /// GST claimable on purchases (BAS label 1B).
    var isPurchaseGST: Bool { [.gstOnExpenses, .gstOnCapital, .gstOnImports].contains(self) }
    /// GST collected on sales (BAS label 1A).
    var isSalesGST: Bool { self == .gstOnIncome }
    /// Counts toward total sales (BAS label G1).
    var countsAsSales: Bool { [.gstOnIncome, .gstFreeIncome, .gstFreeExports, .inputTaxed].contains(self) }
}

enum LedgerAccountType: String, CaseIterable, Identifiable, Codable {
    case revenue = "REVENUE"
    case otherIncome = "OTHERINCOME"
    case directCosts = "DIRECTCOSTS"
    case expense = "EXPENSE"
    case depreciation = "DEPRECIATN"
    case currentAsset = "CURRENT"
    case fixedAsset = "FIXED"
    case bank = "BANK"
    case currentLiability = "CURRLIAB"
    case liability = "LIABILITY"
    case equity = "EQUITY"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .revenue: "Revenue"
        case .otherIncome: "Other Income"
        case .directCosts: "Direct Costs"
        case .expense: "Expense"
        case .depreciation: "Depreciation"
        case .currentAsset: "Current Asset"
        case .fixedAsset: "Fixed Asset"
        case .bank: "Bank"
        case .currentLiability: "Current Liability"
        case .liability: "Liability"
        case .equity: "Equity"
        }
    }

    var isProfitAndLoss: Bool { [.revenue, .otherIncome, .directCosts, .expense, .depreciation].contains(self) }
    var isIncome: Bool { self == .revenue || self == .otherIncome }
}

@Model
final class LedgerAccount {
    var ledgerAccountID: UUID = UUID()
    var code: String = ""
    var name: String = ""
    var typeRaw: String = LedgerAccountType.expense.rawValue
    var taxTypeRaw: String = TaxType.gstOnExpenses.rawValue
    var isArchived: Bool = false
    var createdAt: Date = Date.now
    /// Set for a company's own chart (e.g. imported from its Xero file); nil for the standard chart.
    var company: Company?

    init(code: String, name: String, type: LedgerAccountType, tax: TaxType, company: Company? = nil) {
        self.code = code
        self.name = name
        self.typeRaw = type.rawValue
        self.taxTypeRaw = tax.rawValue
        self.company = company
        // Same id on every device for the same account.
        self.ledgerAccountID = StableID.make(company.map { "ledger:\($0.companyID.uuidString):\(code)" } ?? "ledger:" + code)
    }

    var type: LedgerAccountType {
        get { LedgerAccountType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    var taxType: TaxType {
        get { TaxType(rawValue: taxTypeRaw) ?? .basExcluded }
        set { taxTypeRaw = newValue.rawValue }
    }

    var label: String { "\(code) · \(name)" }
}

enum Chart {
    /// Xero's standard Australian chart, plus a transfers clearing account.
    static let standard: [(String, String, LedgerAccountType, TaxType)] = [
        ("200", "Sales", .revenue, .gstOnIncome),
        ("260", "Other Revenue", .revenue, .gstOnIncome),
        ("270", "Interest Income", .otherIncome, .inputTaxed),
        ("310", "Cost of Goods Sold", .directCosts, .gstOnExpenses),
        ("400", "Advertising", .expense, .gstOnExpenses),
        ("404", "Bank Fees", .expense, .gstFreeExpenses),
        ("408", "Cleaning", .expense, .gstOnExpenses),
        ("412", "Consulting & Accounting", .expense, .gstOnExpenses),
        ("416", "Depreciation", .depreciation, .basExcluded),
        ("420", "Entertainment", .expense, .gstOnExpenses),
        ("421", "Entertainment - Non Deductible", .expense, .basExcluded),
        ("425", "Freight & Courier", .expense, .gstOnExpenses),
        ("429", "General Expenses", .expense, .gstOnExpenses),
        ("433", "Insurance", .expense, .gstOnExpenses),
        ("437", "Interest Expense", .expense, .gstFreeExpenses),
        ("441", "Legal Expenses", .expense, .gstOnExpenses),
        ("445", "Light, Power, Heating", .expense, .gstOnExpenses),
        ("449", "Motor Vehicle Expenses", .expense, .gstOnExpenses),
        ("453", "Office Expenses", .expense, .gstOnExpenses),
        ("461", "Printing & Stationery", .expense, .gstOnExpenses),
        ("469", "Rent", .expense, .gstOnExpenses),
        ("473", "Repairs and Maintenance", .expense, .gstOnExpenses),
        ("477", "Wages and Salaries", .expense, .basExcluded),
        ("478", "Superannuation", .expense, .basExcluded),
        ("485", "Subscriptions", .expense, .gstOnExpenses),
        ("489", "Telephone & Internet", .expense, .gstOnExpenses),
        ("493", "Travel - National", .expense, .gstOnExpenses),
        ("494", "Travel - International", .expense, .gstFreeExpenses),
        ("610", "Accounts Receivable", .currentAsset, .basExcluded),
        ("710", "Office Equipment", .fixedAsset, .gstOnCapital),
        ("720", "Computer Equipment", .fixedAsset, .gstOnCapital),
        ("800", "Accounts Payable", .currentLiability, .basExcluded),
        ("820", "GST", .currentLiability, .basExcluded),
        ("825", "PAYG Withholdings Payable", .currentLiability, .basExcluded),
        ("830", "Income Tax Payable", .currentLiability, .basExcluded),
        ("850", "Suspense", .currentLiability, .basExcluded),
        ("855", "Transfers Between Accounts", .currentAsset, .basExcluded),
        ("880", "Owner Drawings", .equity, .basExcluded),
        ("881", "Owner Funds Introduced", .equity, .basExcluded),
        ("960", "Retained Earnings", .equity, .basExcluded),
        ("970", "Owner Share Capital", .equity, .basExcluded),
    ]

    static let gstCode = "820"
    static let suspenseCode = "850"

    /// Starting account for each category. You can change any of these per transaction.
    static func defaultCode(for category: ReceiptCategory, moneyIn: Bool) -> String {
        switch category {
        case .income: "200"
        case .transfer: "855"
        case .bankFees: moneyIn ? "270" : "404"
        case .tax: "830"
        case .meals: "420"
        case .travel, .accommodation: "493"
        case .fuel: "449"
        case .office: "453"
        case .software: "485"
        case .equipment: "453"
        case .phoneInternet: "489"
        case .utilities: "445"
        case .marketing: "400"
        case .professional: "412"
        case .groceries, .other: "429"
        }
    }

    /// Gives each bank account its own code (090, 091, ...) so the ledger keeps them apart.
    @MainActor
    static func assignBankCodes(_ context: ModelContext) {
        let accounts = ((try? context.fetch(FetchDescriptor<BankAccount>())) ?? []).sorted { $0.createdAt < $1.createdAt }
        var used = Set(accounts.map(\.ledgerCode).filter { !$0.isEmpty })
        var changed = false
        for a in accounts where a.ledgerCode.isEmpty {
            var n = 90
            while used.contains(String(format: "%03d", n)) { n += 1 }
            a.ledgerCode = String(format: "%03d", n)
            used.insert(a.ledgerCode)
            changed = true
        }
        if changed { try? context.save() }
    }

    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        let existing = Set(((try? context.fetch(FetchDescriptor<LedgerAccount>())) ?? []).filter { $0.company == nil }.map(\.code))
        let key = "ledger.seededChart"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for (code, name, type, tax) in standard where !existing.contains(code) {
            context.insert(LedgerAccount(code: code, name: name, type: type, tax: tax))
        }
        try? context.save()
    }
}

/// A manual or imported journal: lines that sum to zero. Lines are stored as JSON so the
/// journal syncs as one record.
@Model
final class LedgerJournal {
    var journalID: UUID = UUID()
    var date: Date = Date.now
    var narration: String = ""
    /// "Xero import", "Manual" or "Opening balances".
    var source: String = ""
    var reference: String = ""
    var linesJSON: String = "[]"
    var createdAt: Date = Date.now
    var company: Company?

    init() {}

    var lines: [JournalLine] {
        get { (try? JSONDecoder().decode([JournalLine].self, from: Data(linesJSON.utf8))) ?? [] }
        set { linesJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }
}

struct JournalLine: Codable, Hashable {
    var code: String
    var name: String
    /// Debit positive, credit negative.
    var amount: Double
    var taxType: String?
    /// GST on this line, same sign convention as amount.
    var tax: Double?
}

/// One line of the double entry. Debits positive, credits negative; each transaction's lines sum to zero.
struct Posting {
    let date: Date
    let company: String
    let code: String
    let amount: Double
    let sourceID: UUID
    var name: String = ""
    var taxType: TaxType? = nil
    /// GST attached to this line (same sign as amount), used for the BAS labels.
    var tax: Double = 0
}

/// How a bank transaction is (or would be) coded.
struct Coding {
    let account: LedgerAccount?
    let code: String
    let tax: TaxType
    /// GST magnitude, always zero or positive.
    let gst: Double
}

@MainActor
struct LedgerBook {
    /// Standard chart, by code.
    let standard: [String: LedgerAccount]
    /// Company charts: company name -> code -> account.
    let byCompany: [String: [String: LedgerAccount]]

    init(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<LedgerAccount>())) ?? []
        standard = Dictionary(all.filter { $0.company == nil }.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        var map: [String: [String: LedgerAccount]] = [:]
        for a in all { if let c = a.company?.name { map[c, default: [:]][a.code] = a } }
        byCompany = map
    }

    func hasOwnChart(_ company: String?) -> Bool {
        company.map { !(byCompany[$0] ?? [:]).isEmpty } ?? false
    }

    /// The company's own account when it has a chart, otherwise the standard one.
    func account(_ code: String, company: String?) -> LedgerAccount? {
        if let c = company, let chart = byCompany[c], !chart.isEmpty { return chart[code] }
        return standard[code]
    }

    func accounts(for company: String?) -> [LedgerAccount] {
        let chart = company.flatMap { byCompany[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? standard
        return chart.values.filter { !$0.isArchived && $0.type != .bank }.sorted { $0.code < $1.code }
    }

    func coding(for t: BankTransaction) -> Coding {
        let code = t.ledgerCode.isEmpty ? Chart.defaultCode(for: t.category, moneyIn: t.amount > 0) : t.ledgerCode
        let account = account(code, company: t.company?.name)
        let tax = TaxType(rawValue: t.taxTypeRaw) ?? account?.taxType ?? .basExcluded
        return Coding(account: account, code: code, tax: tax, gst: Self.gst(for: t, tax: tax))
    }

    static func gst(for t: BankTransaction, tax: TaxType) -> Double {
        let gross = abs(t.amount)
        switch tax {
        case .gstOnImports:
            return gross
        case .gstOnIncome, .gstOnExpenses, .gstOnCapital:
            // Use the GST printed on the matched receipt when it is for the same amount.
            if let r = t.receipt, r.gst > 0, r.gst < gross, abs(r.total - gross) < 0.02 { return r.gst }
            return (gross / 11 * 100).rounded() / 100
        default:
            return 0
        }
    }

    /// Bank, account and GST lines for one transaction.
    func postings(for t: BankTransaction) -> [Posting] {
        let c = coding(for: t)
        let company = t.company?.name ?? "No company"
        let signedGST = t.amount >= 0 ? c.gst : -c.gst
        let net = t.amount - signedGST
        let bankCode = t.account?.ledgerCode.isEmpty == false ? t.account!.ledgerCode : "090"
        var lines = [
            Posting(date: t.date, company: company, code: bankCode, amount: t.amount, sourceID: t.transactionID,
                    name: t.account?.name ?? "Bank"),
            Posting(date: t.date, company: company, code: c.code, amount: -net, sourceID: t.transactionID,
                    name: c.account?.name ?? "", taxType: c.tax, tax: -signedGST),
        ]
        if c.gst > 0 {
            lines.append(Posting(date: t.date, company: company, code: Chart.gstCode, amount: -signedGST,
                                 sourceID: t.transactionID, name: "GST"))
        }
        return lines
    }

    func postings(for j: LedgerJournal) -> [Posting] {
        let company = j.company?.name ?? "No company"
        return j.lines.map { l in
            Posting(date: j.date, company: company, code: l.code, amount: l.amount, sourceID: j.journalID, name: l.name,
                    taxType: l.taxType.flatMap(TaxType.init(rawValue:)), tax: l.tax ?? 0)
        }
    }

    /// Apply the suggested or chosen coding and mark the transaction reconciled.
    func reconcile(_ t: BankTransaction, context: ModelContext) {
        let c = coding(for: t)
        t.ledgerCode = c.code
        t.taxTypeRaw = c.tax.rawValue
        t.isReconciled = true
        if t.status == .needsReceipt && (c.account?.type.isProfitAndLoss == false) {
            // Transfers, tax payments and owner money do not need a receipt.
            t.status = .noReceiptNeeded
        }
        try? context.save()
    }
}

// MARK: Reports

enum ReportPeriod: String, CaseIterable, Identifiable {
    case thisMonth = "This month"
    case lastMonth = "Last month"
    case thisQuarter = "This quarter"
    case lastQuarter = "Last quarter"
    case thisFinancialYear = "This financial year"
    case lastFinancialYear = "Last financial year"
    case allTime = "All time"

    var id: String { rawValue }

    /// Start (inclusive) and end (exclusive). Australian financial year runs 1 July to 30 June.
    func range(now: Date = .now) -> (Date, Date) {
        let cal = Calendar.current
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        func date(_ y: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: 1))! }
        func add(_ d: Date, months: Int) -> Date { cal.date(byAdding: .month, value: months, to: d)! }
        let monthStart = date(y, m)
        let quarterStart = date(y, ((m - 1) / 3) * 3 + 1)
        let fyStart = m >= 7 ? date(y, 7) : date(y - 1, 7)
        switch self {
        case .thisMonth: return (monthStart, add(monthStart, months: 1))
        case .lastMonth: return (add(monthStart, months: -1), monthStart)
        case .thisQuarter: return (quarterStart, add(quarterStart, months: 3))
        case .lastQuarter: return (add(quarterStart, months: -3), quarterStart)
        case .thisFinancialYear: return (fyStart, add(fyStart, months: 12))
        case .lastFinancialYear: return (add(fyStart, months: -12), fyStart)
        case .allTime: return (Date.distantPast, Date.distantFuture)
        }
    }

    func label(now: Date = .now) -> String {
        let (s, e) = range(now: now)
        if self == .allTime { return rawValue }
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return "\(f.string(from: s)) to \(f.string(from: e.addingTimeInterval(-86400)))"
    }
}

struct ProfitAndLoss {
    struct Line: Identifiable {
        let code: String
        let name: String
        let amount: Double
        var id: String { code }
    }
    var income: [Line] = []
    var directCosts: [Line] = []
    var expenses: [Line] = []

    var totalIncome: Double { income.reduce(0) { $0 + $1.amount } }
    var totalDirectCosts: Double { directCosts.reduce(0) { $0 + $1.amount } }
    var grossProfit: Double { totalIncome - totalDirectCosts }
    var totalExpenses: Double { expenses.reduce(0) { $0 + $1.amount } }
    var netProfit: Double { grossProfit - totalExpenses }
}

/// Simpler BAS, cash basis (bank transactions are recorded when paid).
struct GSTSummary {
    var g1TotalSales: Double = 0
    var a1GSTOnSales: Double = 0
    var b1GSTOnPurchases: Double = 0
    var net: Double { a1GSTOnSales - b1GSTOnPurchases }
}

@MainActor
enum Reports {
    static func transactions(_ all: [BankTransaction], company: String?, period: ReportPeriod, includeUnreconciled: Bool) -> [BankTransaction] {
        let (start, end) = period.range()
        return all.filter { t in
            (includeUnreconciled || t.isReconciled)
                && t.date >= start && t.date < end
                && (company == nil || t.company?.name == company)
        }
    }

    /// Every ledger line in a date range: reconciled bank transactions plus journals.
    static func postings(transactions: [BankTransaction], journals: [LedgerJournal], company: String?,
                         from start: Date, to end: Date, includeUnreconciled: Bool, book: LedgerBook) -> [Posting] {
        var out: [Posting] = []
        for t in transactions where (includeUnreconciled || t.isReconciled) && t.date >= start && t.date < end
            && (company == nil || t.company?.name == company) {
            out += book.postings(for: t)
        }
        for j in journals where j.date >= start && j.date < end && (company == nil || j.company?.name == company) {
            out += book.postings(for: j)
        }
        return out
    }

    static func profitAndLoss(_ postings: [Posting], book: LedgerBook) -> ProfitAndLoss {
        struct Key: Hashable { let code: String; let name: String; let type: LedgerAccountType }
        var totals: [Key: Double] = [:]
        for p in postings {
            guard let a = book.account(p.code, company: p.company), a.type.isProfitAndLoss else { continue }
            totals[Key(code: a.code, name: a.name, type: a.type), default: 0] += p.amount
        }
        var pl = ProfitAndLoss()
        for (k, raw) in totals {
            let amount = (raw * 100).rounded() / 100
            guard abs(amount) >= 0.005 else { continue }
            switch k.type {
            case .revenue, .otherIncome: pl.income.append(.init(code: k.code, name: k.name, amount: -amount))
            case .directCosts: pl.directCosts.append(.init(code: k.code, name: k.name, amount: amount))
            default: pl.expenses.append(.init(code: k.code, name: k.name, amount: amount))
            }
        }
        pl.income.sort { ($0.code, $0.name) < ($1.code, $1.name) }
        pl.directCosts.sort { ($0.code, $0.name) < ($1.code, $1.name) }
        pl.expenses.sort { ($0.code, $0.name) < ($1.code, $1.name) }
        return pl
    }

    static func gst(_ postings: [Posting]) -> GSTSummary {
        var s = GSTSummary()
        for p in postings {
            guard let tt = p.taxType else { continue }
            if tt.isPurchaseGST { s.b1GSTOnPurchases += p.tax }
            if tt.isSalesGST { s.a1GSTOnSales -= p.tax }
            if tt.countsAsSales { s.g1TotalSales -= p.amount + p.tax }
        }
        s.g1TotalSales = (s.g1TotalSales * 100).rounded() / 100
        s.a1GSTOnSales = (s.a1GSTOnSales * 100).rounded() / 100
        s.b1GSTOnPurchases = (s.b1GSTOnPurchases * 100).rounded() / 100
        return s
    }
}
