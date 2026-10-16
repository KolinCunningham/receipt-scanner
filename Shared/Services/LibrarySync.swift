import Foundation
import SwiftData
import CryptoKit
import Observation

// Two way sync through a folder the person picks, normally "iCloud Drive › Receipts Library".
// Works without a paid developer team: the app only needs the folder permission the picker grants.
//
// Layout:  companies/<id>.json  accounts/<id>.json  receipts/<id>.json  transactions/<id>.json
//          receipt-images/<id>.jpg   deleted-images/<id>.jpg
//
// Each record file holds the record or a deletion marker. A three way compare against the state
// at the last sync decides who changed what. Safety rules, because the scans must never be lost:
//   - A missing or not yet downloaded file never counts as a deletion.
//   - When both sides changed, nothing is deleted: an edit beats a delete.
//   - Photos are never removed from the folder; a deleted receipt's photo moves to deleted-images.
//   - A run that would delete more than a few records, or most of them, stops and asks first.
//   - Nothing runs when the local database failed to open.

struct CompanyRecord: Codable {
    var name: String
    var createdAt: Date
}

struct AccountRecord: Codable {
    var name: String
    var institution: String
    var kind: String
    var currency: String
    var createdAt: Date
    var companyID: UUID?
    var ledgerCode: String?
}

struct LedgerAccountRecord: Codable {
    var code: String
    var name: String
    var type: String
    var taxType: String
    var isArchived: Bool
    var createdAt: Date
    var companyID: UUID?
}

struct JournalRecord: Codable {
    var date: Date
    var narration: String
    var source: String
    var reference: String
    var lines: String
    var createdAt: Date
    var companyID: UUID?
}

struct ReceiptRecord: Codable {
    var merchant: String
    var date: Date
    var total: Double
    var gst: Double
    var currency: String
    var category: String
    var notes: String
    var ocrText: String
    var classifiedBy: String
    var createdAt: Date
    var companyID: UUID?
    /// Optional so older files still read, and omitted when empty so existing records keep their hash.
    var sourcePhotoID: String?
}

struct TransactionRecord: Codable {
    var date: Date
    var amount: Double
    var details: String
    var balance: Double?
    var importKey: String
    var category: String
    var classifiedBy: String
    var status: String
    var matchedBy: String
    var notes: String
    var importedAt: Date
    var accountID: UUID?
    var companyID: UUID?
    var receiptID: UUID?
    // Ledger fields are optional and left out until used, so older records keep their hash.
    var ledgerCode: String?
    var taxType: String?
    var isReconciled: Bool?
}

enum SyncKind: String, CaseIterable {
    // Order matters: references point to kinds earlier in the list.
    case companies, accounts
    case ledgerAccounts = "ledger-accounts"
    case journals
    case receipts, transactions
}

@MainActor
@Observable
final class LibrarySync {
    static let shared = LibrarySync()

    var folderName: String?
    var status = ""
    var lastSync: Date?
    var isSyncing = false
    /// Set when a run stopped because it would delete many records.
    var pendingDeletionWarning: String?
    private var allowLargeDeletesOnce = false

    private static let bookmarkKey = "library.bookmark"
    private static let deleteLimit = 5

    private init() {
        #if DEBUG
        // Testing: launch with -syncFolder /path to sync with a plain folder.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-syncFolder"), i + 1 < args.count,
           UserDefaults.standard.data(forKey: Self.bookmarkKey) == nil {
            let url = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            }
        }
        #endif
        folderName = resolveFolder()?.lastPathComponent
    }

    // MARK: Folder

    /// Names of the folders sync creates inside the library folder.
    nonisolated static let innerFolderNames: Set<String> = Set(SyncKind.allCases.map(\.rawValue)).union(["receipt-images", "deleted-images"])

    /// Why a folder cannot be the library, or nil when it is fine.
    nonisolated static func problem(with url: URL) -> String? {
        let name = url.lastPathComponent
        if innerFolderNames.contains(name.lowercased()) {
            let parent = url.deletingLastPathComponent().lastPathComponent
            return "You picked the \"\(name)\" folder inside \(parent). Go back one level and choose \(parent) itself (open it, then tap Open)."
        }
        #if os(iOS)
        // A folder on this iPhone (including inside this app) is invisible to the Mac and other apps.
        let isICloud = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
        if !isICloud {
            return "That folder is only on this iPhone, so the Mac and the other app cannot see it. Choose your folder in iCloud Drive instead (Browse › iCloud Drive)."
        }
        #endif
        return nil
    }

    /// Returns false (with the reason in `status`) when the folder cannot work for syncing.
    @discardableResult
    func setFolder(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let isICloud = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
        if let problem = Self.problem(with: url) {
            status = problem
            return false
        }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        guard let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            status = "Could not keep permission for that folder."
            return false
        }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        // A different folder has a different history.
        Self.saveBase([:])
        folderName = url.lastPathComponent
        status = isICloud ? "Folder chosen." : "Folder chosen. It is not in iCloud Drive, so your iPhone cannot reach it."
        return true
    }

    /// Forget the folder. The folder and its files are left untouched.
    func stopSyncing() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        Self.saveBase([:])
        folderName = nil
        status = "Not syncing. Your receipts on this device and in the folder are untouched."
    }

    func confirmLargeDeletes() {
        allowLargeDeletesOnce = true
        pendingDeletionWarning = nil
    }

    private func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }

    // MARK: Sync

    func sync(context: ModelContext) async {
        guard !isSyncing, let folder = resolveFolder() else { return }
        guard StoreInfo.loadError == nil else {
            status = "Not syncing: this device's receipts could not be opened."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        #if !DEBUG
        // A folder chosen before these checks existed may be the wrong one: say so instead of syncing.
        if let problem = Self.problem(with: folder) {
            status = problem + " Tap Choose a different folder."
            return
        }
        #endif

        do {
            let remote = try await Task.detached { try Self.readFolder(folder) }.value
            let outcome = try apply(remote: remote, context: context)
            try await Task.detached { try Self.write(outcome.writes, images: outcome.images, retire: outcome.retireImages, to: folder) }.value
            var base = Self.loadBase()
            for (key, hash) in outcome.newBase { base[key] = hash }
            Self.saveBase(base)

            // Fill in photos for receipts that arrived without one.
            let needPhotos = ((try? context.fetch(FetchDescriptor<Receipt>())) ?? [])
                .filter { $0.imageData == nil && remote.imageIDs.contains($0.receiptID) }
                .map(\.receiptID)
            if !needPhotos.isEmpty {
                let photos = await Task.detached { Self.readImages(needPhotos, in: folder) }.value
                let receipts = (try? context.fetch(FetchDescriptor<Receipt>())) ?? []
                for r in receipts {
                    guard let data = photos[r.receiptID] else { continue }
                    r.imageData = data
                    r.thumbnailData = ImagePrep.prepare(data)?.thumbnail
                }
                try? context.save()
            }

            lastSync = .now
            var parts: [String] = []
            if outcome.pulled > 0 { parts.append("\(outcome.pulled) received") }
            if outcome.pushed > 0 { parts.append("\(outcome.pushed) sent") }
            if remote.pending > 0 { parts.append("\(remote.pending) still downloading from iCloud") }
            status = parts.isEmpty ? "Up to date." : parts.joined(separator: ", ") + "."
            #if DEBUG
            print("LibrarySync: \(status)")
            #endif
        } catch SyncStop.largeDeletion(let message) {
            pendingDeletionWarning = message
            status = "Paused: confirm the deletions below."
            #if DEBUG
            print("LibrarySync: PAUSED \(message)")
            #endif
        } catch {
            status = "Sync problem: \(error.localizedDescription)"
        }
    }

    enum SyncStop: Error { case largeDeletion(String) }

    struct Outcome {
        var writes: [String: Data] = [:]
        var images: [UUID: Data] = [:]
        var retireImages: [UUID] = []
        var newBase: [String: String] = [:]
        var pulled = 0
        var pushed = 0
    }

    // MARK: Three way compare

    private func apply(remote: RemoteFolder, context: ModelContext) throws -> Outcome {
        let base = Self.loadBase()
        let companies = (try? context.fetch(FetchDescriptor<Company>())) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<BankAccount>())) ?? []
        let receipts = ((try? context.fetch(FetchDescriptor<Receipt>())) ?? []).filter { !$0.isProcessing }
        let transactions = (try? context.fetch(FetchDescriptor<BankTransaction>())) ?? []
        let ledgerAccounts = (try? context.fetch(FetchDescriptor<LedgerAccount>())) ?? []
        var ledgerByID = Dictionary(ledgerAccounts.map { ($0.ledgerAccountID, $0) }, uniquingKeysWith: { a, _ in a })
        let journals = (try? context.fetch(FetchDescriptor<LedgerJournal>())) ?? []
        var journalByID = Dictionary(journals.map { ($0.journalID, $0) }, uniquingKeysWith: { a, _ in a })
        let processingIDs = Set(((try? context.fetch(FetchDescriptor<Receipt>())) ?? []).filter(\.isProcessing).map(\.receiptID))

        var companyByID = Dictionary(companies.map { ($0.companyID, $0) }, uniquingKeysWith: { a, _ in a })
        var accountByID = Dictionary(accounts.map { ($0.accountID, $0) }, uniquingKeysWith: { a, _ in a })
        var receiptByID = Dictionary(receipts.map { ($0.receiptID, $0) }, uniquingKeysWith: { a, _ in a })
        let transactionByID = Dictionary(transactions.map { ($0.transactionID, $0) }, uniquingKeysWith: { a, _ in a })

        // Local state as encoded records.
        var local: [String: Data] = [:]
        for c in companies { local[key(.companies, c.companyID)] = Self.encode(Self.record(c)) }
        for a in accounts { local[key(.accounts, a.accountID)] = Self.encode(Self.record(a)) }
        for l in ledgerAccounts { local[key(.ledgerAccounts, l.ledgerAccountID)] = Self.encode(Self.record(l)) }
        for j in journals { local[key(.journals, j.journalID)] = Self.encode(Self.record(j)) }
        for r in receipts { local[key(.receipts, r.receiptID)] = Self.encode(Self.record(r)) }
        for t in transactions { local[key(.transactions, t.transactionID)] = Self.encode(Self.record(t)) }

        // Plan every key first, then check the deletion limits, then act.
        enum Action { case push, tombstone, pull, deleteLocal, settle(String) }
        var plan: [(String, Action)] = []
        let keys = Set(local.keys).union(remote.files.keys).union(base.keys)
        for k in keys {
            if remote.pendingKeys.contains(k) { continue }
            if let id = UUID(uuidString: String(k.split(separator: "/").last ?? "")), processingIDs.contains(id) { continue }
            let L = local[k].map(Self.hash)
            let B = base[k]
            let R: String?
            if let file = remote.files[k] {
                R = file.deleted ? "deleted" : file.recordHash
            } else {
                R = nil
            }

            switch (L, R) {
            case (nil, nil):
                // Gone here and not in the folder: write a deletion marker only if we had synced it.
                if let b = B, b != "deleted" { plan.append((k, .tombstone)) }
            case (.some, nil):
                plan.append((k, .push))
            case (let l?, "deleted"?):
                // A default company recreated on a fresh install follows the folder's deletion;
                // anything else edited here since is kept and sent back.
                if l == B || (B == nil && k.hasPrefix(SyncKind.companies.rawValue + "/")) {
                    plan.append((k, .deleteLocal))
                } else {
                    plan.append((k, .push))
                }
            case (nil, "deleted"?):
                plan.append((k, .settle("deleted")))
            case (let l?, let r?):
                if l == r { plan.append((k, .settle(l))) }
                else if l == B || B == nil { plan.append((k, .pull)) }  // only the folder changed, or first sync: folder wins
                else { plan.append((k, .push)) }                        // only we changed, or both did: keep ours
            case (nil, let r?):
                if B != nil && B == r { plan.append((k, .tombstone)) }  // we deleted it, folder unchanged
                else { plan.append((k, .pull)) }                      // new elsewhere, or edited after our delete
            }
        }

        let deletes = plan.filter { if case .deleteLocal = $0.1 { true } else { false } }.count
        let tombstones = plan.filter { if case .tombstone = $0.1 { true } else { false } }.count
        for (count, direction) in [(deletes, "remove \(deletes) records from this device"), (tombstones, "mark \(tombstones) records as deleted in the folder")]
        where count > Self.deleteLimit && !allowLargeDeletesOnce {
            throw SyncStop.largeDeletion("This sync would \(direction). If you deleted them on purpose, confirm below. Otherwise do nothing; your data is unchanged.")
        }
        allowLargeDeletesOnce = false

        var out = Outcome()
        let device = Self.deviceName

        // Pulls in reference order so companies exist before receipts point at them.
        for kind in SyncKind.allCases {
            for (k, action) in plan where k.hasPrefix(kind.rawValue + "/") {
                guard let id = UUID(uuidString: String(k.split(separator: "/").last ?? "")) else { continue }
                switch action {
                case .settle(let h):
                    out.newBase[k] = h
                case .push:
                    guard let data = local[k] else { continue }
                    out.writes[k] = Self.wrap(kind, recordData: data, deleted: false, device: device)
                    out.newBase[k] = Self.hash(data)
                    out.pushed += 1
                    if kind == .receipts, !remote.imageIDs.contains(id), let image = receiptByID[id]?.imageData {
                        out.images[id] = image
                    }
                case .tombstone:
                    out.writes[k] = Self.wrap(kind, recordData: nil, deleted: true, device: device)
                    out.newBase[k] = "deleted"
                    out.pushed += 1
                    if kind == .receipts { out.retireImages.append(id) }
                case .deleteLocal:
                    switch kind {
                    case .companies:
                        // Never let a company deletion cascade away receipts that are still live elsewhere;
                        // receipts get their own deletion markers.
                        if let c = companyByID[id] {
                            for r in c.receipts ?? [] { r.company = nil }
                            context.delete(c)
                            companyByID[id] = nil
                        }
                    case .accounts:
                        if let a = accountByID[id] {
                            for t in a.transactions ?? [] { t.account = nil }
                            context.delete(a)
                            accountByID[id] = nil
                        }
                    case .ledgerAccounts:
                        if let l = ledgerByID[id] { context.delete(l); ledgerByID[id] = nil }
                    case .journals:
                        if let j = journalByID[id] { context.delete(j); journalByID[id] = nil }
                    case .receipts:
                        if let r = receiptByID[id] { context.delete(r); receiptByID[id] = nil }
                    case .transactions:
                        if let t = transactionByID[id] { context.delete(t) }
                    }
                    out.newBase[k] = "deleted"
                    out.pulled += 1
                case .pull:
                    guard let file = remote.files[k], let recordData = file.recordData else { continue }
                    let applied: Bool
                    switch kind {
                    case .companies:
                        guard let rec = try? Self.decoder.decode(CompanyRecord.self, from: recordData) else { continue }
                        let c: Company
                        if let existing = companyByID[id] { c = existing } else {
                            c = Company(name: rec.name)
                            context.insert(c)
                            c.companyID = id
                            companyByID[id] = c
                        }
                        c.name = rec.name
                        c.createdAt = rec.createdAt
                        applied = true
                    case .accounts:
                        guard let rec = try? Self.decoder.decode(AccountRecord.self, from: recordData) else { continue }
                        if let cid = rec.companyID, companyByID[cid] == nil { applied = false; break }
                        let a: BankAccount
                        if let existing = accountByID[id] { a = existing } else {
                            a = BankAccount(name: rec.name)
                            context.insert(a)
                            a.accountID = id
                            accountByID[id] = a
                        }
                        a.name = rec.name
                        a.institution = rec.institution
                        a.kind = rec.kind
                        a.currency = rec.currency
                        a.createdAt = rec.createdAt
                        a.company = rec.companyID.flatMap { companyByID[$0] }
                        a.ledgerCode = rec.ledgerCode ?? ""
                        applied = true
                    case .ledgerAccounts:
                        guard let rec = try? Self.decoder.decode(LedgerAccountRecord.self, from: recordData) else { continue }
                        let l: LedgerAccount
                        if let existing = ledgerByID[id] { l = existing } else {
                            l = LedgerAccount(code: rec.code, name: rec.name, type: .expense, tax: .basExcluded)
                            context.insert(l)
                            l.ledgerAccountID = id
                            ledgerByID[id] = l
                        }
                        l.code = rec.code
                        l.name = rec.name
                        l.typeRaw = rec.type
                        l.taxTypeRaw = rec.taxType
                        if let cid = rec.companyID, companyByID[cid] == nil { applied = false; break }
                        l.isArchived = rec.isArchived
                        l.createdAt = rec.createdAt
                        l.company = rec.companyID.flatMap { companyByID[$0] }
                        applied = true
                    case .journals:
                        guard let rec = try? Self.decoder.decode(JournalRecord.self, from: recordData) else { continue }
                        if let cid = rec.companyID, companyByID[cid] == nil { applied = false; break }
                        let j: LedgerJournal
                        if let existing = journalByID[id] { j = existing } else {
                            j = LedgerJournal()
                            context.insert(j)
                            j.journalID = id
                            journalByID[id] = j
                        }
                        j.date = rec.date
                        j.narration = rec.narration
                        j.source = rec.source
                        j.reference = rec.reference
                        j.linesJSON = rec.lines
                        j.createdAt = rec.createdAt
                        j.company = rec.companyID.flatMap { companyByID[$0] }
                        applied = true
                    case .receipts:
                        guard let rec = try? Self.decoder.decode(ReceiptRecord.self, from: recordData) else { continue }
                        if let cid = rec.companyID, companyByID[cid] == nil { applied = false; break }
                        let r: Receipt
                        if let existing = receiptByID[id] { r = existing } else {
                            r = Receipt()
                            context.insert(r)
                            r.receiptID = id
                            receiptByID[id] = r
                        }
                        r.merchant = rec.merchant
                        r.date = rec.date
                        r.total = rec.total
                        r.gst = rec.gst
                        r.currency = rec.currency
                        r.categoryRaw = rec.category
                        r.notes = rec.notes
                        r.ocrText = rec.ocrText
                        r.classifiedBy = rec.classifiedBy
                        r.createdAt = rec.createdAt
                        r.company = rec.companyID.flatMap { companyByID[$0] }
                        r.sourcePhotoID = rec.sourcePhotoID ?? ""
                        applied = true
                    case .transactions:
                        guard let rec = try? Self.decoder.decode(TransactionRecord.self, from: recordData) else { continue }
                        if let aid = rec.accountID, accountByID[aid] == nil { applied = false; break }
                        if let cid = rec.companyID, companyByID[cid] == nil { applied = false; break }
                        if let rid = rec.receiptID, receiptByID[rid] == nil { applied = false; break }
                        let t: BankTransaction
                        if let existing = transactionByID[id] { t = existing } else {
                            t = BankTransaction()
                            context.insert(t)
                            t.transactionID = id
                        }
                        t.date = rec.date
                        t.amount = rec.amount
                        t.details = rec.details
                        t.balance = rec.balance
                        t.importKey = rec.importKey
                        t.categoryRaw = rec.category
                        t.classifiedBy = rec.classifiedBy
                        t.statusRaw = rec.status
                        t.matchedBy = rec.matchedBy
                        t.notes = rec.notes
                        t.importedAt = rec.importedAt
                        t.account = rec.accountID.flatMap { accountByID[$0] }
                        t.company = rec.companyID.flatMap { companyByID[$0] }
                        t.receipt = rec.receiptID.flatMap { receiptByID[$0] }
                        t.ledgerCode = rec.ledgerCode ?? ""
                        t.taxTypeRaw = rec.taxType ?? ""
                        t.isReconciled = rec.isReconciled ?? false
                        applied = true
                    }
                    // Left for a later run when what it points to has not arrived yet.
                    if applied, let h = file.recordHash {
                        out.newBase[k] = h
                        out.pulled += 1
                    }
                }
            }
        }
        try context.save()
        return out
    }

    private func key(_ kind: SyncKind, _ id: UUID) -> String { "\(kind.rawValue)/\(id.uuidString)" }

    // MARK: Records

    static func record(_ c: Company) -> CompanyRecord { .init(name: c.name, createdAt: c.createdAt) }
    static func record(_ a: BankAccount) -> AccountRecord {
        .init(name: a.name, institution: a.institution, kind: a.kind, currency: a.currency,
              createdAt: a.createdAt, companyID: a.company?.companyID,
              ledgerCode: a.ledgerCode.isEmpty ? nil : a.ledgerCode)
    }
    static func record(_ l: LedgerAccount) -> LedgerAccountRecord {
        .init(code: l.code, name: l.name, type: l.typeRaw, taxType: l.taxTypeRaw, isArchived: l.isArchived,
              createdAt: l.createdAt, companyID: l.company?.companyID)
    }
    static func record(_ j: LedgerJournal) -> JournalRecord {
        .init(date: j.date, narration: j.narration, source: j.source, reference: j.reference, lines: j.linesJSON,
              createdAt: j.createdAt, companyID: j.company?.companyID)
    }
    static func record(_ r: Receipt) -> ReceiptRecord {
        .init(merchant: r.merchant, date: r.date, total: r.total, gst: r.gst, currency: r.currency,
              category: r.categoryRaw, notes: r.notes, ocrText: r.ocrText, classifiedBy: r.classifiedBy,
              createdAt: r.createdAt, companyID: r.company?.companyID,
              sourcePhotoID: r.sourcePhotoID.isEmpty ? nil : r.sourcePhotoID)
    }
    static func record(_ t: BankTransaction) -> TransactionRecord {
        .init(date: t.date, amount: t.amount, details: t.details, balance: t.balance, importKey: t.importKey,
              category: t.categoryRaw, classifiedBy: t.classifiedBy, status: t.statusRaw, matchedBy: t.matchedBy,
              notes: t.notes, importedAt: t.importedAt, accountID: t.account?.accountID,
              companyID: t.company?.companyID, receiptID: t.receipt?.receiptID,
              ledgerCode: t.ledgerCode.isEmpty ? nil : t.ledgerCode,
              taxType: t.taxTypeRaw.isEmpty ? nil : t.taxTypeRaw,
              isReconciled: t.isReconciled ? true : nil)
    }

    // Dates travel as whole milliseconds so a round trip through the database never drifts,
    // which would make both devices keep re-sending the same record.
    nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return e
    }()

    nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let ms = try dec.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        return d
    }()

    nonisolated static func encode<T: Encodable>(_ value: T) -> Data { (try? encoder.encode(value)) ?? Data() }

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Envelope JSON with the record bytes embedded exactly as encoded.
    nonisolated static func wrap(_ kind: SyncKind, recordData: Data?, deleted: Bool, device: String) -> Data {
        let record = recordData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let savedAt = Int64(Date.now.timeIntervalSince1970 * 1000)
        let text = "{\n\"deleted\" : \(deleted),\n\"device\" : \"\(device)\",\n\"kind\" : \"\(kind.rawValue)\",\n\"savedAt\" : \(savedAt),\n\"record\" : \(record)\n}\n"
        return Data(text.utf8)
    }

    private struct Header: Decodable { let deleted: Bool }
    private struct Body<T: Decodable>: Decodable { let record: T }

    nonisolated static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    // MARK: Sync state (the "base")

    nonisolated private static var baseURL: URL {
        URL.applicationSupportDirectory.appending(path: "LibrarySyncState.json")
    }

    nonisolated static func loadBase() -> [String: String] {
        guard let data = try? Data(contentsOf: baseURL),
              let base = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return base
    }

    nonisolated static func saveBase(_ base: [String: String]) {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(base).write(to: baseURL, options: .atomic)
    }

    // MARK: Folder IO (off the main actor)

    struct RemoteFile: Sendable {
        let deleted: Bool
        /// The record re-encoded the same way local records are, so hashes compare.
        let recordData: Data?
        var recordHash: String? { recordData.map(LibrarySync.hash) }
    }

    struct RemoteFolder: Sendable {
        var files: [String: RemoteFile] = [:]
        var pendingKeys: Set<String> = []
        var imageIDs: Set<UUID> = []
        var pending: Int { pendingKeys.count }
    }

    nonisolated static func readFolder(_ folder: URL) throws -> RemoteFolder {
        let fm = FileManager.default
        var out = RemoteFolder()
        for kind in SyncKind.allCases {
            let dir = folder.appending(path: kind.rawValue)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])) ?? [] {
                // Not yet downloaded files show as ".<name>.icloud" or with a non-current status.
                var name = url.lastPathComponent
                var placeholder = false
                if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(".icloud".count))
                    placeholder = true
                }
                guard name.hasSuffix(".json") else { continue }
                let k = "\(kind.rawValue)/\(name.dropLast(5))"
                let statusValue = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
                if placeholder || (statusValue != nil && statusValue != .current) {
                    try? fm.startDownloadingUbiquitousItem(at: placeholder ? dir.appending(path: name) : url)
                    out.pendingKeys.insert(k)
                    continue
                }
                // Unreadable or half written files are skipped this round, never treated as deleted.
                guard let data = coordinatedRead(url), let header = try? decoder.decode(Header.self, from: data) else {
                    out.pendingKeys.insert(k)
                    continue
                }
                let deleted = header.deleted
                var recordData: Data?
                if !deleted {
                    recordData = normalise(kind, data)
                    if recordData == nil { out.pendingKeys.insert(k); continue }
                }
                out.files[k] = RemoteFile(deleted: deleted, recordData: recordData)
            }
        }
        let images = folder.appending(path: "receipt-images")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        for url in (try? fm.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? [] {
            var name = url.lastPathComponent
            if name.hasPrefix(".") && name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(".icloud".count)) }
            if name.hasSuffix(".jpg"), let id = UUID(uuidString: String(name.dropLast(4))) { out.imageIDs.insert(id) }
        }
        return out
    }

    /// Decode the envelope's typed record and re-encode it, so the bytes match local encoding exactly.
    nonisolated static func normalise(_ kind: SyncKind, _ envelope: Data) -> Data? {
        switch kind {
        case .companies: (try? decoder.decode(Body<CompanyRecord>.self, from: envelope)).map { encode($0.record) }
        case .accounts: (try? decoder.decode(Body<AccountRecord>.self, from: envelope)).map { encode($0.record) }
        case .ledgerAccounts: (try? decoder.decode(Body<LedgerAccountRecord>.self, from: envelope)).map { encode($0.record) }
        case .journals: (try? decoder.decode(Body<JournalRecord>.self, from: envelope)).map { encode($0.record) }
        case .receipts: (try? decoder.decode(Body<ReceiptRecord>.self, from: envelope)).map { encode($0.record) }
        case .transactions: (try? decoder.decode(Body<TransactionRecord>.self, from: envelope)).map { encode($0.record) }
        }
    }

    nonisolated static func readImages(_ ids: [UUID], in folder: URL) -> [UUID: Data] {
        var out: [UUID: Data] = [:]
        for id in ids {
            let url = folder.appending(path: "receipt-images/\(id.uuidString).jpg")
            if let data = coordinatedRead(url) { out[id] = data } else { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        }
        return out
    }

    nonisolated static func write(_ files: [String: Data], images: [UUID: Data], retire: [UUID], to folder: URL) throws {
        let fm = FileManager.default
        for (id, data) in images {
            let url = folder.appending(path: "receipt-images/\(id.uuidString).jpg")
            if !fm.fileExists(atPath: url.path(percentEncoded: false)) { try coordinatedWrite(data, to: url) }
        }
        for (k, data) in files {
            try coordinatedWrite(data, to: folder.appending(path: "\(k).json"))
        }
        // Keep deleted receipts' photos, just out of the way.
        let deletedDir = folder.appending(path: "deleted-images")
        for id in retire {
            let from = folder.appending(path: "receipt-images/\(id.uuidString).jpg")
            guard fm.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            try? fm.createDirectory(at: deletedDir, withIntermediateDirectories: true)
            let to = deletedDir.appending(path: "\(id.uuidString).jpg")
            if fm.fileExists(atPath: to.path(percentEncoded: false)) { continue }
            var err: NSError?
            NSFileCoordinator().coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing, error: &err) { a, b in
                try? fm.moveItem(at: a, to: b)
            }
        }
    }

    nonisolated static func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        try CloudDriveSync.coordinatedWrite(data, to: url)
    }
}
