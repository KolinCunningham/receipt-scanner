import Foundation
import Vision
import ImageIO
import FoundationModels

/// What we pull out of a receipt image.
struct ReceiptAnalysis: Sendable {
    var text: String = ""
    var merchant: String = ""
    var date: Date?
    var total: Double = 0
    var gst: Double = 0
    var currency: String = "AUD"
    var category: ReceiptCategory = .other
    var classifiedBy: String = "Text rules"
}

/// Structured output the on-device Apple Intelligence model fills in.
@Generable
struct ReceiptExtraction {
    @Guide(description: "Business name of the shop or supplier that issued the receipt, in title case")
    var merchant: String
    @Guide(description: "Purchase date as yyyy-MM-dd. Receipts are Australian so 03/04/2026 means 3 April 2026. Empty string if there is no date.")
    var date: String
    @Guide(description: "Final total amount paid including GST, as a plain number")
    var total: Double
    @Guide(description: "GST or tax amount shown on the receipt, 0 if none is shown")
    var gst: Double
    @Guide(description: "Three letter currency code, AUD unless another currency is clearly shown")
    var currency: String
    @Guide(description: "The expense category that best fits what was bought", .anyOf(ReceiptCategory.expenseCases.map(\.rawValue)))
    var category: String
}

enum ReceiptAnalyzer {

    /// OCR the image, then classify with Apple Intelligence, falling back to text rules.
    static func analyze(imageData: Data) async -> ReceiptAnalysis {
        let text = (try? await recognizeText(in: imageData)) ?? ""
        var result = heuristics(for: text)

        if case .available = SystemLanguageModel.default.availability, !text.isEmpty {
            if let ai = try? await extractWithModel(text: text) {
                if !ai.merchant.trimmingCharacters(in: .whitespaces).isEmpty { result.merchant = ai.merchant }
                if let d = parseISODate(ai.date) { result.date = d }
                if ai.total > 0 { result.total = ai.total }
                if ai.gst > 0 && ai.gst < result.total { result.gst = ai.gst }
                if ai.currency.count == 3 { result.currency = ai.currency.uppercased() }
                if let c = ReceiptCategory(rawValue: ai.category) {
                    result.category = c
                    result.classifiedBy = "Apple Intelligence"
                }
            }
        }
        // Receipts print names in capitals; "HARBOURSIDE STATIONERY" reads better as "Harbourside Stationery".
        if result.merchant == result.merchant.uppercased() && result.merchant.contains(where: \.isLetter) {
            result.merchant = result.merchant.capitalized
        }
        return result
    }

    // MARK: OCR

    static func recognizeText(in imageData: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }

        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-AU", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    // MARK: Apple Intelligence

    static func extractWithModel(text: String) async throws -> ReceiptExtraction {
        let session = LanguageModelSession(instructions: """
            You read the OCR text of a single purchase receipt for an Australian small business \
            and extract bookkeeping fields. Use only information in the text. The total is the \
            final amount paid, not a subtotal, change or tendered amount.
            """)
        let clipped = String(text.prefix(3500))
        let response = try await session.respond(
            to: "Receipt text:\n\(clipped)",
            generating: ReceiptExtraction.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return response.content
    }

    // MARK: Text rules fallback

    static func heuristics(for text: String) -> ReceiptAnalysis {
        var r = ReceiptAnalysis(text: text)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Merchant: first line with letters that is not an obvious header word.
        let skip = ["tax invoice", "receipt", "invoice", "welcome", "abn"]
        r.merchant = lines.first { line in
            line.rangeOfCharacter(from: .letters) != nil &&
            !skip.contains { line.lowercased().hasPrefix($0) }
        }?.capitalized ?? ""

        // Total: last line mentioning "total" (but not subtotal), else the biggest amount.
        let totalLine = lines.last { l in
            let low = l.lowercased()
            return low.contains("total") && !low.contains("sub") && !amounts(in: l).isEmpty
        }
        if let line = totalLine, let amount = amounts(in: line).last {
            r.total = amount
        } else {
            r.total = lines.flatMap(amounts(in:)).max() ?? 0
        }

        if let gstLine = lines.first(where: { $0.lowercased().contains("gst") && !amounts(in: $0).isEmpty }),
           let g = amounts(in: gstLine).last, g < r.total {
            r.gst = g
        }

        r.date = lines.lazy.compactMap(parseLooseDate).first
        r.category = keywordCategory(for: text)
        return r
    }

    static func amounts(in line: String) -> [Double] {
        let pattern = #"-?\$?\s?(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let whole = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            let cents = ns.substring(with: m.range(at: 2))
            return Double("\(whole).\(cents)")
        }
    }

    static func keywordCategory(for text: String) -> ReceiptCategory {
        let low = text.lowercased()
        let rules: [(ReceiptCategory, [String])] = [
            (.fuel, ["unleaded", "diesel", "petrol", "fuel", "ampol", "caltex", "bp ", "shell", "7-eleven", "united petroleum", "car wash", "parking"]),
            (.accommodation, ["hotel", "motel", "airbnb", "accommodation", "check-in", "nights", "resort"]),
            (.travel, ["qantas", "virgin", "jetstar", "uber", "didi", "taxi", "opal", "myki", "flight", "airport", "train", "toll"]),
            (.meals, ["cafe", "café", "coffee", "restaurant", "bar ", "pub", "bistro", "latte", "flat white", "dine", "takeaway", "kitchen", "pizza", "sushi"]),
            (.groceries, ["woolworths", "coles", "aldi", "iga", "harris farm", "grocer"]),
            (.software, ["subscription", "apple.com", "google", "microsoft", "adobe", "openai", "anthropic", "canva", "xero", "shopify", "saas"]),
            (.phoneInternet, ["telstra", "optus", "vodafone", "tpg", "aussie broadband", "nbn", "mobile plan"]),
            (.utilities, ["electricity", "energy", "agl", "origin", "water", "gas bill"]),
            (.equipment, ["jb hi-fi", "jb hifi", "harvey norman", "apple store", "bunnings", "officeworks tech", "laptop", "monitor"]),
            (.office, ["officeworks", "stationery", "printer", "paper", "toner", "post office", "australia post"]),
            (.marketing, ["meta", "facebook", "instagram", "ads", "advertising", "printing", "vistaprint"]),
            (.professional, ["legal", "accounting", "consulting", "lawyer", "accountant", "asic", "professional fee"]),
        ]
        for (category, words) in rules where words.contains(where: low.contains) {
            return category
        }
        return .other
    }

    // MARK: Is this a receipt?

    /// Rough likelihood that OCR text comes from a receipt or tax invoice, used to find receipts
    /// among ordinary photos. Receipts have money amounts plus words like total, GST or EFTPOS.
    static func receiptLikelihood(_ text: String) -> Double {
        let low = text.lowercased()
        let strong = ["tax invoice", "gst", "abn", "eftpos", "subtotal", "sub total", "amount due", "balance due", "total incl"]
        let weak = ["total", "receipt", "invoice", "change", "cash", "visa", "mastercard", "amex", "paid", "card", "qty", "approved", "purchase"]
        var score = 0.0
        for k in strong where low.contains(k) { score += 2 }
        for k in weak where low.contains(k) { score += 1 }
        let amounts = text.components(separatedBy: .newlines).flatMap(amounts(in:)).count
        guard amounts >= 2 else { return 0 }
        score += min(Double(amounts), 6) * 0.5
        return score
    }

    static let receiptThreshold = 3.5

    // MARK: Dates

    static func parseISODate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) else { return nil }
        // Reject obviously wrong years from misread text.
        let year = Calendar.current.component(.year, from: d)
        return (2000...2100).contains(year) ? d : nil
    }

    static func parseLooseDate(in line: String) -> Date? {
        let patterns: [(String, [String])] = [
            (#"\b\d{1,2}[/.-]\d{1,2}[/.-]\d{4}\b"#, ["d/M/yyyy", "d.M.yyyy", "d-M-yyyy"]),
            (#"\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2}\b"#, ["d/M/yy", "d.M.yy", "d-M-yy"]),
            (#"\b\d{4}-\d{2}-\d{2}\b"#, ["yyyy-MM-dd"]),
            (#"\b\d{1,2}\s?[A-Za-z]{3,9}\s?\d{2,4}\b"#, ["d MMM yyyy", "d MMMM yyyy", "dMMMyyyy", "d MMM yy", "dMMMyy"]),
        ]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU_POSIX")
        for (pattern, formats) in patterns {
            guard let range = line.range(of: pattern, options: .regularExpression) else { continue }
            let token = String(line[range])
            for format in formats {
                f.dateFormat = format
                if let d = f.date(from: token) {
                    let year = Calendar.current.component(.year, from: d)
                    if (2000...2100).contains(year) { return d }
                }
            }
        }
        return nil
    }
}
