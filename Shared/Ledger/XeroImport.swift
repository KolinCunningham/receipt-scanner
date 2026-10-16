import Foundation
import SwiftData

/// Brings a company's history in from a folder of Xero report exports:
///   - "...Chart of Accounts....csv"            the company's own chart and bank accounts
///   - "...Journal Report....xlsx"              every journal, line by line (double entry)
///   - "...General Ledger Detail with tax rates....xlsx"  (optional) tax rate and GST per line
///   - "Files library/"                         (optional) receipts and invoices from Xero Files
/// Safe to run again: everything gets a stable id, so a second run updates rather than duplicates.
@MainActor
enum XeroImport {

    struct Summary {
        var company = ""
        var accounts = 0
        var bankAccounts = 0
        var journals = 0
        var linesWithTax = 0
        var receipts = 0
        var warnings: [String] = []
    }

    enum ImportError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self {
            case .missing(let what): "Could not find \(what) in that folder. Choose the folder holding the Xero exports."
            }
        }
    }

    static func run(folder: URL, context: ModelContext) async throws -> Summary {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        func find(_ contains: String, _ ext: String) -> URL? {
            files.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(contains) && $0.pathExtension.lowercased() == ext }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.last
        }
        guard let journalFile = find("Journal Report", "xlsx") else { throw ImportError.missing("a Xero Journal Report (.xlsx)") }
        let chartFile = find("Chart of Accounts", "csv")
        let taxFile = find("General Ledger Detail with tax", "xlsx")

        var summary = Summary()
        let journalRows = try XLSXReader.rows(of: journalFile)
        // Row 2 of every Xero report is the organisation name.
        let companyName = journalRows.dropFirst().first?.first?.string.trimmingCharacters(in: .whitespaces) ?? ""
        guard !companyName.isEmpty else { throw ImportError.missing("the organisation name in the Journal Report") }
        summary.company = companyName

        let company = companyFor(companyName, context: context)
        let companyKey = company.companyID.uuidString

        // Chart of accounts and bank accounts.
        var bankCodeByName: [String: String] = [:]
        if let chartFile, let text = try? String(contentsOf: chartFile, encoding: .utf8) {
            let rows = BankImport.csvRows(text)
            let header = rows.first?.map { $0.lowercased().replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) } ?? []
            func col(_ name: String) -> Int? { header.firstIndex(of: name) }
            let existing = (try? context.fetch(FetchDescriptor<LedgerAccount>())) ?? []
            for row in rows.dropFirst() {
                func cell(_ name: String) -> String {
                    guard let i = col(name), i < row.count else { return "" }
                    return row[i].trimmingCharacters(in: .whitespaces)
                }
                let code = cell("code"), name = cell("name"), type = cell("type"), taxName = cell("tax code")
                guard !name.isEmpty else { continue }
                if type.lowercased() == "bank" {
                    let account = bankAccount(named: name, company: company, context: context)
                    bankCodeByName[name.lowercased()] = account.ledgerCode
                    summary.bankAccounts += 1
                    continue
                }
                guard !code.isEmpty else { continue }
                let id = StableID.make("ledger:\(companyKey):\(code)")
                let a = existing.first { $0.ledgerAccountID == id } ?? {
                    let n = LedgerAccount(code: code, name: name, type: .expense, tax: .basExcluded, company: company)
                    context.insert(n)
                    n.company = company
                    return n
                }()
                a.name = name
                a.type = accountType(type)
                a.taxType = TaxType.allCases.first { $0.name.lowercased() == taxName.lowercased() } ?? .basExcluded
                summary.accounts += 1
            }
        } else {
            summary.warnings.append("No Chart of Accounts CSV found, so the standard chart is used for \(companyName).")
        }

        // Tax rate and GST for each line, keyed by date, account and net amount.
        var taxByLine: [String: [(TaxType, Double)]] = [:]
        if let taxFile, let rows = try? XLSXReader.rows(of: taxFile) {
            let headerIndex = rows.firstIndex { $0.first?.string == "Account Code" } ?? 0
            let header = rows[headerIndex].map { $0.string.lowercased() }
            let iCode = header.firstIndex(of: "account code"), iDate = header.firstIndex(of: "date"),
                iNet = header.firstIndex(of: "net"), iGST = header.firstIndex(of: "gst"), iRate = header.firstIndex(of: "gst rate name")
            for r in rows.dropFirst(headerIndex + 1) {
                guard let iCode, let iDate, let iNet, let iGST, let iRate, r.count > max(iCode, iDate, iNet, iGST, iRate),
                      let date = r[iDate].date, let net = r[iNet].double else { continue }
                let rate = TaxType.allCases.first { $0.name.lowercased() == r[iRate].string.lowercased() } ?? .basExcluded
                taxByLine[lineKey(date, r[iCode].string, net), default: []].append((rate, r[iGST].double ?? 0))
            }
        }

        // Journals.
        let existingJournals = Dictionary(((try? context.fetch(FetchDescriptor<LedgerJournal>())) ?? []).map { ($0.journalID, $0) },
                                          uniquingKeysWith: { a, _ in a })
        let codes = Set(((try? context.fetch(FetchDescriptor<LedgerAccount>())) ?? []).filter { $0.company?.persistentModelID == company.persistentModelID }.map(\.code))
        var number = "", narration = "", date: Date?, lines: [JournalLine] = []

        func finish() {
            guard !number.isEmpty, let d = date, !lines.isEmpty else { return }
            let total = lines.reduce(0) { $0 + $1.amount }
            if abs(total) > 0.005 { summary.warnings.append("Journal \(number) does not balance by \(String(format: "%.2f", total)).") }
            let id = StableID.make("journal:\(companyKey):\(number)")
            let j = existingJournals[id] ?? {
                let n = LedgerJournal()
                context.insert(n)
                n.journalID = id
                return n
            }()
            j.date = d
            j.narration = narration
            j.source = "Xero import"
            j.reference = "Xero journal \(number)"
            j.company = company
            j.lines = lines
            summary.journals += 1
        }

        for row in journalRows {
            let first = row.first?.string ?? ""
            if first.hasPrefix("ID "), row.dropFirst().allSatisfy({ $0 == .empty }) {
                finish()
                let rest = first.dropFirst(3)
                number = String(rest.prefix { $0.isNumber })
                narration = rest.drop { $0.isNumber }.trimmingCharacters(in: .whitespaces)
                date = nil
                lines = []
                continue
            }
            guard row.count >= 6, let d = row[0].date else { continue }
            date = d
            let rawCode = row[2].string.trimmingCharacters(in: .whitespaces)
            let name = row[3].string.trimmingCharacters(in: .whitespaces)
            let value = (((row[4].double ?? 0) - (row[5].double ?? 0)) * 100).rounded() / 100
            var code = rawCode
            if !codes.contains(rawCode) {
                // Bank lines carry the bank account's name instead of a code.
                if let bank = bankCodeByName[rawCode.lowercased()] ?? bankCodeByName[name.lowercased()] {
                    code = bank
                } else if rawCode.contains(where: \.isLetter) {
                    let account = bankAccount(named: rawCode, company: company, context: context)
                    bankCodeByName[rawCode.lowercased()] = account.ledgerCode
                    code = account.ledgerCode
                    summary.bankAccounts += 1
                }
            }
            var line = JournalLine(code: code, name: name.isEmpty ? rawCode : name, amount: value)
            let k = lineKey(d, rawCode, value)
            if var list = taxByLine[k], !list.isEmpty {
                let (rate, gst) = list.removeFirst()
                taxByLine[k] = list
                line.taxType = rate.rawValue
                line.tax = gst
                summary.linesWithTax += 1
            }
            lines.append(line)
        }
        finish()

        // Receipts and invoices from Xero Files.
        let library = folder.appending(path: "Files library")
        if let items = try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil) {
            let already = Set(((try? context.fetch(FetchDescriptor<Receipt>())) ?? []).map(\.sourcePhotoID))
            var datas: [Data] = [], ids: [String] = []
            for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let ext = url.pathExtension.lowercased()
                guard ["jpg", "jpeg", "png", "heic", "pdf"].contains(ext) else { continue }
                let sourceID = "xero-file:\(companyKey):\(url.lastPathComponent)"
                guard !already.contains(sourceID) else { continue }
                // First page is the receipt; later pages of invoices are terms and detail.
                guard let first = PDFPages.receiptImages(from: url).first else { continue }
                datas.append(first)
                ids.append(sourceID)
            }
            if !datas.isEmpty {
                ReceiptIntake.add(imageData: datas, photoIDs: ids, to: company, context: context)
                summary.receipts = datas.count
            }
        }

        try context.save()
        Chart.assignBankCodes(context)
        return summary
    }

    private static func lineKey(_ date: Date, _ code: String, _ amount: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: date))|\(code.trimmingCharacters(in: .whitespaces))|\(String(format: "%.2f", amount))"
    }

    private static func companyFor(_ name: String, context: ModelContext) -> Company {
        let all = (try? context.fetch(FetchDescriptor<Company>())) ?? []
        let simple = { (s: String) in s.lowercased().replacingOccurrences(of: " pty ltd", with: "").replacingOccurrences(of: " pty. ltd.", with: "") }
        if let c = all.first(where: { simple($0.name) == simple(name) }) { return c }
        let c = Company(name: name)
        context.insert(c)
        return c
    }

    private static func bankAccount(named name: String, company: Company, context: ModelContext) -> BankAccount {
        let all = (try? context.fetch(FetchDescriptor<BankAccount>())) ?? []
        if let a = all.first(where: { $0.name.lowercased() == name.lowercased() && $0.company?.persistentModelID == company.persistentModelID }) {
            return a
        }
        let a = BankAccount(name: name, institution: name.split(separator: " ").first.map(String.init) ?? "", kind: "Business")
        context.insert(a)
        a.company = company
        a.accountID = StableID.make("bank:\(company.companyID.uuidString):\(name.lowercased())")
        try? context.save()
        Chart.assignBankCodes(context)
        return a
    }

    private static func accountType(_ xero: String) -> LedgerAccountType {
        switch xero.lowercased() {
        case "revenue", "sales": .revenue
        case "other income": .otherIncome
        case "direct costs": .directCosts
        case "depreciation": .depreciation
        case "current asset", "prepayment", "inventory", "accounts receivable": .currentAsset
        case "fixed asset", "non-current asset": .fixedAsset
        case "bank": .bank
        case "current liability", "gst", "accounts payable", "historical", "rounding", "tracking",
             "unpaid expense claims", "wages payable": .currentLiability
        case "liability", "non-current liability", "term liability": .liability
        case "equity", "retained earnings": .equity
        default: .expense   // Expense, Overhead
        }
    }
}
