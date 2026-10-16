import Foundation

/// Cleans bank descriptions down to the merchant name and compares names.
enum BankText {

    private static let noisePrefixes = [
        "VISA DEBIT PURCHASE CARD", "VISA PURCHASE", "VISA DEBIT", "DEBIT CARD PURCHASE", "EFTPOS PURCHASE",
        "EFTPOS", "CARD PURCHASE", "PURCHASE AUTHORISATION", "PURCHASE", "POS AUTHORISATION", "POS ",
        "DIRECT DEBIT", "RECURRING PAYMENT", "PAYMENT TO", "PAYMENT BY AUTHORITY TO", "INTERNET PAYMENT",
        "OSKO PAYMENT TO", "OSKO PAYMENT", "TRANSFER TO", "TRANSFER FROM", "BPAY", "SQ *", "SQ*", "SP *", "SP*",
        "PAYPAL *", "PAYPAL*", "ZLR*", "LS ", "TST* ", "TST*", "IZ *", "IZ*", "WWW.", "APPLE PAY",
    ]

    private static let noiseWords: Set<String> = [
        "AU", "AUS", "AUSTRALIA", "NSW", "VIC", "QLD", "WA", "SA", "TAS", "ACT", "NT", "PTY", "LTD", "THE",
        "CARD", "VALUE", "DATE", "REF", "RECEIPT", "TAP", "CONTACTLESS", "INC", "CO", "COM", "AUD", "FOREIGN",
        "CURRENCY", "AMOUNT", "INCL", "FEE",
    ]

    /// "SQ *GROUNDS CAFE SYDNEY AU Card xx1234 Value Date: 12/10/2026" -> "Grounds Cafe Sydney"
    static func cleanMerchant(_ raw: String) -> String {
        var s = raw.uppercased()
        for _ in 0..<3 {
            for p in noisePrefixes where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // Cut trailing card numbers, value dates and reference numbers.
        for marker in [" CARD XX", " CARD ", " VALUE DATE", " XX", " REF ", " RECEIPT "] {
            if let r = s.range(of: marker) { s = String(s[..<r.lowerBound]) }
        }
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "&" && $0 != "'" })
            .map(String.init)
            .filter { w in !noiseWords.contains(w) && !(w.count >= 4 && w.allSatisfy(\.isNumber)) }
        // Drop repeated words, e.g. "AMPOL BONDI 1234 BONDI" -> "Ampol Bondi".
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0).inserted }
        let cleaned = unique.prefix(5).joined(separator: " ").capitalized
        return cleaned.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : cleaned
    }

    static func key(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !noiseWords.contains($0.uppercased()) })
    }

    /// 0...1 likeness of a receipt merchant and a bank description.
    static func similarity(_ a: String, _ b: String) -> Double {
        let ka = key(a), kb = key(cleanMerchant(b))
        guard !ka.isEmpty, !kb.isEmpty else { return 0 }
        if ka == kb { return 1 }
        if ka.count >= 4 && kb.count >= 4 && (ka.contains(kb) || kb.contains(ka)) { return 0.9 }
        let ta = tokens(a), tb = tokens(cleanMerchant(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        var hits = Double(ta.intersection(tb).count)
        // Partial word matches, e.g. "woolworths" vs "woolworth".
        for x in ta where !tb.contains(x) {
            if tb.contains(where: { y in x.count >= 5 && y.count >= 5 && (x.hasPrefix(y) || y.hasPrefix(x)) }) { hits += 0.7 }
        }
        return min(1, hits / Double(min(ta.count, tb.count)))
    }
}

/// Pairs bank transactions with receipts by amount, date and merchant name.
enum Matcher {

    struct ReceiptInfo: Sendable {
        let id: UUID
        let date: Date
        let total: Double
        let merchant: String
        let currency: String
    }

    struct TransactionInfo: Sendable {
        let id: UUID
        let date: Date
        let amount: Double
        let details: String
    }

    struct Pair: Sendable, Identifiable {
        let receiptID: UUID
        let transactionID: UUID
        let score: Double
        let reason: String
        var id: String { "\(receiptID)-\(transactionID)" }
        /// Safe to match without asking.
        var isConfident: Bool { score >= 0.85 }
    }

    /// Score for one receipt against one transaction, nil when they cannot be the same purchase.
    static func score(_ r: ReceiptInfo, _ t: TransactionInfo, accountCurrency: String = "AUD") -> (Double, String)? {
        guard t.amount < 0, r.total > 0 else { return nil }
        let paid = -t.amount
        let sameCurrency = r.currency.uppercased() == accountCurrency.uppercased()
        let amountGap = abs(paid - r.total)
        // Exact amount in the same currency; foreign receipts get 5% for conversion and fees.
        let amountOK = sameCurrency ? amountGap <= 0.01 : amountGap <= r.total * 0.05
        guard amountOK else { return nil }

        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: r.date),
                                                   to: Calendar.current.startOfDay(for: t.date)).day ?? 99
        // Card payments post on the day or a few days later; allow one day early for time zones.
        guard (-1...7).contains(days) else { return nil }

        let name = BankText.similarity(r.merchant, t.details)
        var score = sameCurrency ? 0.55 : 0.4
        score += days <= 3 ? 0.2 : 0.1
        score += 0.3 * name
        let when = days == 0 ? "same day" : days == 1 ? "1 day later" : days < 0 ? "1 day earlier" : "\(days) days later"
        let reason = "Same amount, \(when)" + (name >= 0.6 ? ", name matches" : name > 0 ? ", name partly matches" : "")
        return (min(score, 1), reason)
    }

    /// Best one to one pairing: highest scores first, each receipt and transaction used once.
    static func suggest(receipts: [ReceiptInfo], transactions: [TransactionInfo]) -> [Pair] {
        var candidates: [Pair] = []
        for r in receipts {
            for t in transactions {
                if let (s, why) = score(r, t) {
                    candidates.append(Pair(receiptID: r.id, transactionID: t.id, score: s, reason: why))
                }
            }
        }
        // A pair is only confident when neither side has a near tie elsewhere.
        let perReceipt = Dictionary(grouping: candidates, by: \.receiptID)
        let perTransaction = Dictionary(grouping: candidates, by: \.transactionID)

        var usedR = Set<UUID>(), usedT = Set<UUID>()
        var out: [Pair] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            guard !usedR.contains(c.receiptID), !usedT.contains(c.transactionID) else { continue }
            usedR.insert(c.receiptID)
            usedT.insert(c.transactionID)
            let rivals = (perReceipt[c.receiptID] ?? []) + (perTransaction[c.transactionID] ?? [])
            let tied = rivals.contains { $0.id != c.id && $0.score >= c.score - 0.1 }
            out.append(tied ? Pair(receiptID: c.receiptID, transactionID: c.transactionID,
                                   score: min(c.score, 0.8), reason: c.reason + " (other close options)") : c)
        }
        return out
    }
}
