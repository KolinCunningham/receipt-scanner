import Foundation

/// One line from a bank statement, before it is saved.
struct ParsedTransaction: Equatable, Sendable {
    var date: Date
    var amount: Double
    var details: String
    var balance: Double?
    /// Bank supplied unique id (OFX FITID) when there is one.
    var bankID: String?
}

enum BankImportError: LocalizedError {
    case unreadable
    case noTransactions

    var errorDescription: String? {
        switch self {
        case .unreadable: "The file could not be read as text."
        case .noTransactions: "No transactions were found. Export a CSV or OFX/QFX file from your internet banking."
        }
    }
}

/// Reads statement exports from Australian banks: CSV (CommBank, Westpac, NAB, ANZ, Macquarie,
/// ING, Up and most others, with or without a header row) and OFX/QFX.
enum BankImport {

    static func parse(data: Data, fileName: String) throws -> [ParsedTransaction] {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { throw BankImportError.unreadable }
        let lower = fileName.lowercased()
        let result: [ParsedTransaction]
        if lower.hasSuffix(".ofx") || lower.hasSuffix(".qfx") || text.contains("<STMTTRN>") {
            result = parseOFX(text)
        } else {
            result = parseCSV(text)
        }
        guard !result.isEmpty else { throw BankImportError.noTransactions }
        return result
    }

    /// Stable key for spotting the same transaction in two overlapping imports.
    static func importKeys(for items: [ParsedTransaction], accountName: String) -> [String] {
        var seen: [String: Int] = [:]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU_POSIX")
        f.dateFormat = "yyyyMMdd"
        return items.map { t in
            if let id = t.bankID, !id.isEmpty { return "\(accountName)|fit|\(id)" }
            let base = "\(accountName)|\(f.string(from: t.date))|\(String(format: "%.2f", t.amount))|\(t.details.uppercased().filter { !$0.isWhitespace })"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return "\(base)|\(n)"
        }
    }

    // MARK: OFX / QFX

    static func parseOFX(_ text: String) -> [ParsedTransaction] {
        var out: [ParsedTransaction] = []
        let blocks = text.components(separatedBy: "<STMTTRN>").dropFirst()
        for raw in blocks {
            let block = raw.components(separatedBy: "</STMTTRN>").first ?? raw
            guard let dateText = tag("DTPOSTED", in: block), let date = ofxDate(dateText),
                  let amountText = tag("TRNAMT", in: block), let amount = parseAmount(amountText) else { continue }
            let name = tag("NAME", in: block) ?? ""
            let memo = tag("MEMO", in: block) ?? ""
            let details = [name, memo].filter { !$0.isEmpty }.reduce(into: [String]()) { parts, p in
                if !parts.contains(where: { $0.localizedCaseInsensitiveContains(p) || p.localizedCaseInsensitiveContains($0) }) {
                    parts.append(p)
                } else if let i = parts.firstIndex(where: { p.localizedCaseInsensitiveContains($0) }), p.count > parts[i].count {
                    parts[i] = p
                }
            }.joined(separator: " ")
            out.append(ParsedTransaction(date: date, amount: amount, details: decodeEntities(details),
                                         balance: nil, bankID: tag("FITID", in: block)))
        }
        return out
    }

    /// OFX is SGML, so closing tags are optional. Value runs to the next "<" or end of line.
    private static func tag(_ name: String, in block: String) -> String? {
        guard let start = block.range(of: "<\(name)>", options: .caseInsensitive) else { return nil }
        let rest = block[start.upperBound...]
        let end = rest.firstIndex(where: { $0 == "<" || $0 == "\n" || $0 == "\r" }) ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func ofxDate(_ s: String) -> Date? {
        let digits = String(s.prefix(8))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.date(from: digits)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: CSV

    static func parseCSV(_ text: String) -> [ParsedTransaction] {
        let rows = csvRows(text).filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !rows.isEmpty else { return [] }

        // Find a header row: one with "date" and no parseable date in it.
        if let headerIndex = rows.prefix(15).firstIndex(where: { row in
            row.contains { $0.lowercased().contains("date") } && !row.contains { parseDate($0) != nil }
        }) {
            let header = rows[headerIndex].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            let mapped = parseWithHeader(header, rows: Array(rows[(headerIndex + 1)...]))
            if !mapped.isEmpty { return mapped }
        }
        return parseByShape(rows)
    }

    private static func parseWithHeader(_ header: [String], rows: [[String]]) -> [ParsedTransaction] {
        func col(_ names: [String], excluding: [String] = []) -> Int? {
            for name in names {
                if let i = header.firstIndex(where: { h in h == name }) { return i }
            }
            for name in names {
                if let i = header.firstIndex(where: { h in h.contains(name) && !excluding.contains(where: h.contains) }) { return i }
            }
            return nil
        }
        guard let dateCol = col(["date", "transaction date", "posted date", "effective date"], excluding: ["value date"]) else { return [] }
        let amountCol = col(["amount", "transaction amount"], excluding: ["debit", "credit"])
        let debitCol = col(["debit amount", "debit", "withdrawal", "money out", "paid out"])
        let creditCol = col(["credit amount", "credit", "deposit", "money in", "paid in"])
        let balanceCol = col(["balance", "running balance"])
        let detailCols = ["description", "narrative", "transaction details", "details", "merchant name", "payee", "memo", "reference", "particulars"]
            .compactMap { name in header.firstIndex(of: name) ?? header.firstIndex(where: { $0.contains(name) }) }
        var seenCols = Set<Int>()
        let uniqueDetailCols = detailCols.filter { seenCols.insert($0).inserted }

        guard amountCol != nil || debitCol != nil || creditCol != nil else { return [] }

        return rows.compactMap { row in
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            guard let date = parseDate(cell(dateCol)) else { return nil }
            var amount: Double?
            if let a = amountCol, let v = parseAmount(cell(a)) {
                amount = v
            } else {
                let debit = parseAmount(cell(debitCol)).map { -abs($0) }
                let credit = parseAmount(cell(creditCol)).map { abs($0) }
                amount = (debit ?? 0) + (credit ?? 0)
                if debit == nil && credit == nil { amount = nil }
            }
            guard let value = amount else { return nil }
            var parts: [String] = []
            for c in uniqueDetailCols {
                let v = cell(c).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty && !parts.contains(where: { $0.localizedCaseInsensitiveContains(v) }) { parts.append(v) }
            }
            return ParsedTransaction(date: date, amount: value, details: parts.joined(separator: " "),
                                     balance: balanceCol.flatMap { parseAmount(cell($0)) }, bankID: nil)
        }
    }

    /// No header (CommBank and ANZ): find the date, amount, text and balance columns by content.
    private static func parseByShape(_ rows: [[String]]) -> [ParsedTransaction] {
        let width = rows.map(\.count).max() ?? 0
        guard width >= 2 else { return [] }
        let sample = Array(rows.prefix(50))
        func share(_ col: Int, _ test: (String) -> Bool) -> Double {
            let hits = sample.filter { col < $0.count && test($0[col]) }.count
            return Double(hits) / Double(max(sample.count, 1))
        }
        guard let dateCol = (0..<width).first(where: { share($0) { parseDate($0) != nil } > 0.6 }) else { return [] }
        let numeric = (0..<width).filter { $0 != dateCol && share($0) { parseAmount($0) != nil } > 0.6 }
        guard let amountCol = numeric.first else { return [] }
        let balanceCol = numeric.dropFirst().first
        let textCol = (0..<width)
            .filter { $0 != dateCol && !numeric.contains($0) }
            .max { a, b in
                sample.map { a < $0.count ? $0[a].count : 0 }.reduce(0, +) < sample.map { b < $0.count ? $0[b].count : 0 }.reduce(0, +)
            }

        return rows.compactMap { row in
            guard dateCol < row.count, amountCol < row.count,
                  let date = parseDate(row[dateCol]), let amount = parseAmount(row[amountCol]) else { return nil }
            let details = textCol.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
            let balance = balanceCol.flatMap { $0 < row.count ? parseAmount(row[$0]) : nil }
            return ParsedTransaction(date: date, amount: amount, details: details.trimmingCharacters(in: .whitespaces),
                                     balance: balance, bankID: nil)
        }
    }

    /// RFC 4180 style CSV: quoted fields, doubled quotes, commas and newlines inside quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: Values

    static func parseAmount(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        if s.hasSuffix("DR") { negative = true; s = String(s.dropLast(2)) }
        if s.hasSuffix("CR") { s = String(s.dropLast(2)) }
        s = s.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "AUD", with: "")
            .trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("-") { negative.toggle(); s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber || $0 == "." }), s.contains(where: \.isNumber),
              let v = Double(s) else { return nil }
        return negative ? -v : v
    }

    private static let dateFormats = [
        "dd/MM/yyyy", "d/M/yyyy", "dd/MM/yy", "d/M/yy", "yyyy-MM-dd", "dd-MM-yyyy", "d-M-yyyy",
        "dd MMM yyyy", "d MMM yyyy", "dd MMM yy", "d MMM yy", "dd-MMM-yyyy", "d-MMM-yy", "dd-MMM-yy", "yyyy/MM/dd",
        "dd.MM.yyyy",
    ]

    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 6, s.first?.isNumber == true else { return nil }
        // Also try without a time part, as in "14/10/2026 09:41", "2026-10-14T00:00:00" or "14 Oct 2026 09:41".
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "T" }).map(String.init)
        let candidates = [s, tokens.first ?? s, tokens.prefix(3).joined(separator: " ")]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU_POSIX")
        f.isLenient = false
        for candidate in candidates {
            for format in dateFormats {
                f.dateFormat = format
                if let d = f.date(from: candidate) {
                    let year = Calendar.current.component(.year, from: d)
                    if (1990...2100).contains(year) { return d }
                }
            }
        }
        return nil
    }
}
