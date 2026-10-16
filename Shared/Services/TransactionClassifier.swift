import Foundation
import SwiftData
import FoundationModels

@Generable
struct TransactionCategoryChoice {
    @Guide(description: "The bookkeeping category for this bank transaction", .anyOf(ReceiptCategory.allCases.map(\.rawValue)))
    var category: String
}

/// Sorts bank transactions into categories. Order of trust: your own corrections, the matched
/// receipt, simple rules, then Apple Intelligence (one question per distinct merchant).
@MainActor
enum TransactionClassifier {

    static func classify(_ transactions: [BankTransaction], context: ModelContext) async {
        let all = (try? context.fetch(FetchDescriptor<BankTransaction>())) ?? []
        var learned: [String: ReceiptCategory] = [:]
        for t in all where t.classifiedBy == "You" {
            learned[BankText.key(t.merchantName)] = t.category
        }

        var askAI: [String: [BankTransaction]] = [:]
        for t in transactions where t.classifiedBy != "You" {
            if let r = t.receipt {
                t.category = r.category
                t.classifiedBy = "Matched receipt"
            } else if let c = learned[BankText.key(t.merchantName)] {
                t.category = c
                t.classifiedBy = "Your earlier choices"
            } else if let c = rule(for: t) {
                t.category = c
                t.classifiedBy = "Text rules"
            } else {
                askAI[BankText.key(t.merchantName), default: []].append(t)
            }
        }
        try? context.save()

        guard case .available = SystemLanguageModel.default.availability else {
            for t in askAI.values.joined() {
                t.category = .other
                t.classifiedBy = "Text rules"
            }
            try? context.save()
            return
        }
        for group in askAI.values {
            guard let sample = group.first else { continue }
            let category = (try? await askModel(details: sample.details, amount: sample.amount)) ?? .other
            for t in group {
                t.category = category
                t.classifiedBy = "Apple Intelligence"
            }
            try? context.save()
        }
    }

    static func rule(for t: BankTransaction) -> ReceiptCategory? {
        let low = t.details.lowercased()
        if ["transfer to", "transfer from", "tfr ", "internal transfer", "own account", "linked acc"].contains(where: low.contains) {
            return .transfer
        }
        if ["account fee", "monthly fee", "interest charged", "overdrawn fee", "international transaction fee", "debit interest"].contains(where: low.contains) {
            return .bankFees
        }
        if ["ato ", "australian taxation", "tax office", "asic", "service nsw", "revenue nsw"].contains(where: low.contains) {
            return .tax
        }
        if t.amount > 0 {
            return ["interest", "refund", "reversal"].contains(where: low.contains) ? .other : .income
        }
        let byKeyword = ReceiptAnalyzer.keywordCategory(for: t.details)
        return byKeyword == .other ? nil : byKeyword
    }

    static func askModel(details: String, amount: Double) async throws -> ReceiptCategory {
        let session = LanguageModelSession(instructions: """
            You categorise Australian bank transactions for small business bookkeeping. \
            Negative amounts are money spent, positive amounts are money received.
            """)
        let response = try await session.respond(
            to: "Transaction: \(details)\nAmount: \(String(format: "%.2f", amount)) AUD",
            generating: TransactionCategoryChoice.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return ReceiptCategory(rawValue: response.content.category) ?? .other
    }
}

/// Saving imports and matches into the database.
@MainActor
enum Ledger {

    struct ImportSummary {
        var added: Int
        var duplicates: Int
        var autoMatched: Int
    }

    static func importTransactions(_ parsed: [ParsedTransaction], into account: BankAccount, context: ModelContext) async -> ImportSummary {
        let keys = BankImport.importKeys(for: parsed, accountName: "\(Int(account.createdAt.timeIntervalSince1970))")
        let existing = Set((account.transactions ?? []).map(\.importKey))
        var added: [BankTransaction] = []
        for (item, key) in zip(parsed, keys) where !existing.contains(key) {
            let t = BankTransaction()
            context.insert(t)
            t.date = item.date
            t.amount = item.amount
            t.details = item.details
            t.balance = item.balance
            t.importKey = key
            t.account = account
            t.company = account.company
            // Money in and transfers never need a receipt.
            if item.amount >= 0 { t.status = .noReceiptNeeded }
            added.append(t)
        }
        try? context.save()
        let matched = autoMatch(context: context)
        await TransactionClassifier.classify(added, context: context)
        for t in added where t.category == .transfer || t.category == .bankFees { t.status = .noReceiptNeeded }
        try? context.save()
        return ImportSummary(added: added.count, duplicates: parsed.count - added.count, autoMatched: matched)
    }

    /// All suggestions between unmatched receipts and transactions that still need one.
    static func suggestions(context: ModelContext) -> [Matcher.Pair] {
        let receipts = ((try? context.fetch(FetchDescriptor<Receipt>())) ?? [])
            .filter { $0.bankTransaction == nil && !$0.isProcessing }
        let transactions = ((try? context.fetch(FetchDescriptor<BankTransaction>())) ?? [])
            .filter { $0.status == .needsReceipt && $0.receipt == nil }
        return Matcher.suggest(
            receipts: receipts.map { .init(id: $0.receiptID, date: $0.date, total: $0.total, merchant: $0.merchant, currency: $0.currency) },
            transactions: transactions.map { .init(id: $0.transactionID, date: $0.date, amount: $0.amount, details: $0.details) }
        )
    }

    /// Links confident pairs straight away. Returns how many were linked.
    @discardableResult
    static func autoMatch(context: ModelContext) -> Int {
        let pairs = suggestions(context: context).filter(\.isConfident)
        for p in pairs { link(receiptID: p.receiptID, transactionID: p.transactionID, by: "Auto", context: context) }
        return pairs.count
    }

    static func link(receiptID: UUID, transactionID: UUID, by: String, context: ModelContext) {
        guard let r = try? context.fetch(FetchDescriptor<Receipt>(predicate: #Predicate { $0.receiptID == receiptID })).first,
              let t = try? context.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.transactionID == transactionID })).first
        else { return }
        link(r, t, by: by, context: context)
    }

    static func link(_ r: Receipt, _ t: BankTransaction, by: String, context: ModelContext) {
        t.receipt = r
        t.status = .matched
        t.matchedBy = by
        if t.classifiedBy != "You" {
            t.category = r.category
            t.classifiedBy = "Matched receipt"
        }
        if t.company == nil { t.company = r.company }
        try? context.save()
    }

    static func unlink(_ t: BankTransaction, context: ModelContext) {
        t.receipt = nil
        t.status = .needsReceipt
        t.matchedBy = ""
        try? context.save()
    }
}
