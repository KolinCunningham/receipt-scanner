import Foundation
import SwiftData
import Observation

/// Plain copy of a receipt so the spreadsheet can be built off the main thread.
struct ReceiptRow: Sendable {
    let shortID: String
    let date: Date
    let company: String
    let merchant: String
    let category: String
    let total: Double
    let gst: Double
    let currency: String
    let notes: String
    let classifiedBy: String

    @MainActor
    init(_ r: Receipt) {
        shortID = r.shortID
        date = r.date
        company = r.company?.name ?? "No company"
        merchant = r.merchant
        category = r.category.rawValue
        total = r.total
        gst = r.gst
        currency = r.currency
        notes = r.notes
        classifiedBy = r.classifiedBy
    }

    /// Where the receipt photo lives inside the app's iCloud Drive folder.
    var imagePath: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let name = CloudDriveSync.safeFileName(merchant.isEmpty ? "Receipt" : merchant)
        return "Receipt Images/\(CloudDriveSync.safeFileName(company))/\(f.string(from: date)) \(name) [\(shortID)].jpg"
    }
}

/// Plain copy of a bank transaction for the spreadsheet.
struct BankRow: Sendable {
    let date: Date
    let account: String
    let company: String
    let merchant: String
    let details: String
    let amount: Double
    let category: String
    let status: String
    let receiptPhoto: String

    @MainActor
    init(_ t: BankTransaction) {
        date = t.date
        account = t.account?.name ?? ""
        company = t.company?.name ?? ""
        merchant = t.merchantName
        details = t.details
        amount = t.amount
        category = t.category.rawValue
        status = t.status.rawValue
        receiptPhoto = t.receipt.map { ReceiptRow($0).imagePath } ?? ""
    }
}

/// Keeps "iCloud Drive › Receipt Scanner" up to date with Receipts.xlsx and a folder of receipt photos per company.
@MainActor
@Observable
final class CloudDriveSync {
    static let shared = CloudDriveSync()

    nonisolated static let spreadsheetName = "Receipts.xlsx"

    var lastSynced: Date?
    var lastMessage = ""
    var isSyncing = false
    var usingICloudDrive = true
    private var pending = false

    func sync(context: ModelContext) async {
        if isSyncing { pending = true; return }
        isSyncing = true
        repeat {
            pending = false
            // Exchange changes with the other device first, so the spreadsheet includes them.
            await LibrarySync.shared.sync(context: context)
            await runOnce(context: context)
        } while pending
        isSyncing = false
    }

    /// Builds the workbook for sharing (AirDrop, Mail, Save to Files) without touching iCloud Drive.
    func makeShareableCopy(context: ModelContext) async throws -> URL {
        let (rows, names, bank) = snapshot(context: context)
        return try await Task.detached {
            let data = Self.buildWorkbook(rows: rows, companyNames: names, bank: bank)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let url = FileManager.default.temporaryDirectory.appending(path: "Receipts \(f.string(from: .now)).xlsx")
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    private func allReceiptIDs(context: ModelContext) -> Set<String> {
        Set(((try? context.fetch(FetchDescriptor<Receipt>())) ?? []).map(\.shortID))
    }

    private func snapshot(context: ModelContext) -> ([ReceiptRow], [String], [BankRow]) {
        let receipts = (try? context.fetch(FetchDescriptor<Receipt>(sortBy: [SortDescriptor(\.date)]))) ?? []
        let companies = (try? context.fetch(FetchDescriptor<Company>(sortBy: [SortDescriptor(\.name)]))) ?? []
        let bank = (try? context.fetch(FetchDescriptor<BankTransaction>(sortBy: [SortDescriptor(\.date)]))) ?? []
        return (receipts.filter { !$0.isProcessing }.map(ReceiptRow.init), companies.map(\.name), bank.map(BankRow.init))
    }

    private func runOnce(context: ModelContext) async {
        // An unopened database looks empty; never tidy files against it.
        guard StoreInfo.loadError == nil else {
            lastMessage = "Your saved receipts could not be opened, so nothing was changed."
            return
        }
        let (rows, names, bank) = snapshot(context: context)
        let knownIDs = allReceiptIDs(context: context)
        do {
            let (root, isICloud) = await Self.rootFolder()
            usingICloudDrive = isICloud
            #if os(macOS)
            // Without iCloud the Mac copy would be hidden inside the app sandbox; use Export instead.
            guard isICloud else {
                lastMessage = "Use Export Spreadsheet to save a copy."
                return
            }
            #endif

            // Pass 1: spreadsheet, tidy old photos, report which photos are missing.
            let missing = try await Task.detached {
                try Self.writeSpreadsheetAndPrune(rows: rows, companyNames: names, bank: bank, knownIDs: knownIDs, root: root)
            }.value

            // Pass 2: only load full images for photos not already in the folder.
            if !missing.isEmpty {
                let receipts = (try? context.fetch(FetchDescriptor<Receipt>())) ?? []
                let byID = Dictionary(receipts.map { ($0.shortID, $0) }, uniquingKeysWith: { a, _ in a })
                var files: [PendingImage] = []
                for item in missing {
                    if let data = byID[item.shortID]?.imageData {
                        files.append(PendingImage(path: item.path, data: data))
                    }
                }
                try await Task.detached { try Self.writeImages(files, root: root) }.value
            }

            lastSynced = .now
            lastMessage = isICloud
                ? "Saved to iCloud Drive › Receipt Scanner"
                : "Spreadsheet saved in Files › On My iPhone › Receipt Scanner"
        } catch {
            lastMessage = "Could not save spreadsheet: \(error.localizedDescription)"
        }
    }

    // MARK: File work (off the main actor)

    struct MissingImage: Sendable { let shortID: String; let path: String }
    struct PendingImage: Sendable { let path: String; let data: Data }

    nonisolated static func rootFolder() async -> (URL, Bool) {
        await Task.detached {
            let fm = FileManager.default
            if let container = fm.url(forUbiquityContainerIdentifier: nil) {
                let docs = container.appending(path: "Documents")
                try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
                return (docs, true)
            }
            return (URL.documentsDirectory, false)
        }.value
    }

    nonisolated static func writeSpreadsheetAndPrune(rows: [ReceiptRow], companyNames: [String], bank: [BankRow], knownIDs: Set<String>, root: URL) throws -> [MissingImage] {
        let fm = FileManager.default
        let workbook = buildWorkbook(rows: rows, companyNames: companyNames, bank: bank)
        try coordinatedWrite(workbook, to: root.appending(path: spreadsheetName))

        let expected = Dictionary(rows.map { ($0.imagePath, $0.shortID) }, uniquingKeysWith: { a, _ in a })

        // Tidy photo copies, never losing one. A copy left behind by a renamed or moved receipt is
        // removed only once its new copy exists. A copy whose receipt is gone from the database is
        // moved to "Deleted Receipt Images", not deleted. With no receipts loaded at all, touch nothing.
        let imagesRoot = root.appending(path: "Receipt Images")
        let deletedRoot = root.appending(path: "Deleted Receipt Images")
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        // Includes receipts still being read, which are not in the spreadsheet rows yet.
        let liveIDs = knownIDs
        let pathByID = Dictionary(rows.map { ($0.shortID, $0.imagePath) }, uniquingKeysWith: { a, _ in a })
        if !liveIDs.isEmpty, let walker = fm.enumerator(at: imagesRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension.lowercased() == "jpg" {
                let name = url.lastPathComponent
                guard let tag = name.range(of: #"\[[0-9A-F]{8}\]\.jpg$"#, options: .regularExpression) else { continue }
                let full = url.standardizedFileURL.path(percentEncoded: false)
                let relative = String(full.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard expected[relative] == nil else { continue }
                let id = String(name[tag].dropFirst().prefix(8))
                if liveIDs.contains(id) {
                    if let newPath = pathByID[id], fm.fileExists(atPath: root.appending(path: newPath).path(percentEncoded: false)) {
                        try? fm.removeItem(at: url)
                    }
                } else {
                    try? fm.createDirectory(at: deletedRoot, withIntermediateDirectories: true)
                    let target = deletedRoot.appending(path: name)
                    if !fm.fileExists(atPath: target.path(percentEncoded: false)) {
                        try? fm.moveItem(at: url, to: target)
                    }
                }
            }
        }
        if let folders = try? fm.contentsOfDirectory(at: imagesRoot, includingPropertiesForKeys: nil) {
            for folder in folders where (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty == true {
                try? fm.removeItem(at: folder)
            }
        }

        return expected.compactMap { path, id in
            fm.fileExists(atPath: root.appending(path: path).path(percentEncoded: false)) ? nil : MissingImage(shortID: id, path: path)
        }
    }

    nonisolated static func writeImages(_ files: [PendingImage], root: URL) throws {
        let fm = FileManager.default
        for file in files {
            let url = root.appending(path: file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinatedWrite(file.data, to: url)
        }
    }

    nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let e = coordinationError ?? writeError { throw e }
    }

    nonisolated static func safeFileName(_ s: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:?*\"<>|[]").union(.controlCharacters)
        let cleaned = String(s.unicodeScalars.map { banned.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(60))
    }

    // MARK: Workbook layout

    nonisolated static func buildWorkbook(rows: [ReceiptRow], companyNames: [String], bank: [BankRow] = []) -> Data {
        typealias C = XLSXWriter.Cell
        var sheets: [XLSXWriter.Sheet] = []

        // Summary: totals by company and category.
        var summary: [[C]] = [[.header("Company"), .header("Category"), .header("Receipts"), .header("Total"), .header("GST")]]
        let byCompany = Dictionary(grouping: rows, by: \.company)
        for company in byCompany.keys.sorted() {
            let byCategory = Dictionary(grouping: byCompany[company]!, by: \.category)
            for category in byCategory.keys.sorted() {
                let items = byCategory[category]!
                summary.append([.text(company), .text(category), .number(Double(items.count)),
                                .money(items.reduce(0) { $0 + $1.total }), .money(items.reduce(0) { $0 + $1.gst })])
            }
        }
        let lastSummaryRow = summary.count
        summary.append([])
        summary.append([.boldText("Total"), .empty, .empty,
                        .sumFormula(column: 3, fromRow: 2, toRow: lastSummaryRow),
                        .sumFormula(column: 4, fromRow: 2, toRow: lastSummaryRow)])
        sheets.append(.init(name: "Summary", columnWidths: [28, 26, 10, 14, 12], rows: summary))

        sheets.append(receiptSheet(name: "All Receipts", rows: rows, includeCompany: true))
        if !bank.isEmpty {
            sheets.append(bankSheet(name: "Bank Transactions", rows: bank))
            sheets.append(bankSheet(name: "Missing Receipts", rows: bank.filter { $0.status == MatchStatus.needsReceipt.rawValue }))
        }
        for name in companyNames {
            sheets.append(receiptSheet(name: name, rows: rows.filter { $0.company == name }, includeCompany: false))
        }
        return XLSXWriter.makeWorkbook(sheets)
    }

    nonisolated private static func bankSheet(name: String, rows: [BankRow]) -> XLSXWriter.Sheet {
        typealias C = XLSXWriter.Cell
        var out: [[C]] = [[.header("Date"), .header("Account"), .header("Company"), .header("Merchant"),
                           .header("Amount"), .header("Category"), .header("Receipt"), .header("Receipt photo"),
                           .header("Bank description")]]
        for r in rows {
            out.append([.date(r.date), .text(r.account), .text(r.company), .text(r.merchant), .money(r.amount),
                        .text(r.category), .text(r.status), .text(r.receiptPhoto), .text(r.details)])
        }
        let last = out.count
        out.append([])
        out.append([.boldText("Total"), .empty, .empty, .empty, .sumFormula(column: 4, fromRow: 2, toRow: last)])
        return .init(name: name, columnWidths: [12, 22, 22, 28, 12, 24, 16, 50, 50], rows: out)
    }

    nonisolated private static func receiptSheet(name: String, rows: [ReceiptRow], includeCompany: Bool) -> XLSXWriter.Sheet {
        typealias C = XLSXWriter.Cell
        var header: [C] = [.header("Date")]
        var widths: [Double] = [12]
        if includeCompany { header.append(.header("Company")); widths.append(24) }
        header += [.header("Merchant"), .header("Category"), .header("Total"), .header("GST"),
                   .header("Currency"), .header("Notes"), .header("Classified by"), .header("Photo")]
        widths += [28, 24, 12, 10, 9, 30, 20, 56]
        let totalColumn = includeCompany ? 4 : 3

        var out: [[C]] = [header]
        for r in rows {
            var line: [C] = [.date(r.date)]
            if includeCompany { line.append(.text(r.company)) }
            line += [.text(r.merchant), .text(r.category), .money(r.total), .money(r.gst),
                     .text(r.currency), .text(r.notes), .text(r.classifiedBy), .text(r.imagePath)]
            out.append(line)
        }
        let last = out.count
        out.append([])
        var totals: [C] = Array(repeating: .empty, count: totalColumn + 2)
        totals[0] = .boldText("Total")
        totals[totalColumn] = .sumFormula(column: totalColumn, fromRow: 2, toRow: last)
        totals[totalColumn + 1] = .sumFormula(column: totalColumn + 1, fromRow: 2, toRow: last)
        out.append(totals)
        return .init(name: name, columnWidths: widths, rows: out)
    }
}
