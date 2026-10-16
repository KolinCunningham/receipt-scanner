import Foundation
import SwiftData

@MainActor
enum ReceiptProcessor {

    /// Reads the receipt photo and fills in merchant, date, amounts and category.
    static func process(_ receipt: Receipt, context: ModelContext) async {
        guard let data = receipt.imageData else {
            receipt.isProcessing = false
            return
        }
        receipt.isProcessing = true
        let a = await ReceiptAnalyzer.analyze(imageData: data)

        receipt.ocrText = a.text
        receipt.merchant = a.merchant
        if let date = a.date { receipt.date = date }
        receipt.total = a.total
        receipt.gst = a.gst
        receipt.currency = a.currency
        receipt.category = a.category
        receipt.classifiedBy = a.classifiedBy

        // If you have corrected this merchant's category before, follow your choice.
        if let learned = learnedCategory(for: a.merchant, excluding: receipt, context: context) {
            receipt.category = learned
            receipt.classifiedBy = "Your earlier receipts"
        }

        receipt.isProcessing = false
        try? context.save()
    }

    static func learnedCategory(for merchant: String, excluding receipt: Receipt, context: ModelContext) -> ReceiptCategory? {
        let key = normalise(merchant)
        guard !key.isEmpty else { return nil }
        let descriptor = FetchDescriptor<Receipt>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first {
            $0.persistentModelID != receipt.persistentModelID && $0.classifiedBy == "You" && normalise($0.merchant) == key
        }?.category
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum CompanyStore {
    /// Optional per-install settings in Shared/Config/CompanyDefaults.json (git-ignored, so a
    /// person's own company names stay off GitHub). Without the file the generic defaults apply.
    private struct Config: Decodable {
        var defaultNames: [String]?
        var required: [String]?
        var retired: [String]?
        var folded: [String: String]?
    }

    private static let config: Config? = {
        guard let url = Bundle.main.url(forResource: "CompanyDefaults", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }()

    /// Companies created on a fresh install.
    static let defaultNames = config?.defaultNames ?? ["Personal", "My Business"]

    /// Companies that must exist on every device, even ones set up before they were added.
    static let required = config?.required ?? []

    /// Companies no longer used. Removed wherever they exist, but only while empty,
    /// so a receipt filed under one is never lost.
    static let retired = config?.retired ?? []

    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        let key = "seededCompanies"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let count = (try? context.fetchCount(FetchDescriptor<Company>())) ?? 0
        guard count == 0 else { return }
        for name in defaultNames { context.insert(Company(name: name)) }
        try? context.save()
    }

    /// Companies that are really part of another one (lowercased old name to new name). Their
    /// receipts, transactions and accounts are moved across on every device and the old name removed.
    static let folded = config?.folded ?? [:]

    @MainActor
    static func applyFolds(_ context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Company>())) ?? []
        for (oldName, newName) in folded {
            for old in all where old.name.trimmingCharacters(in: .whitespaces).lowercased() == oldName {
                let target = all.first { $0.name.lowercased() == newName.lowercased() } ?? {
                    let c = Company(name: newName)
                    context.insert(c)
                    return c
                }()
                merge(old, into: target, context: context)
            }
        }
        for name in required where !all.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            context.insert(Company(name: name))
        }
        for c in all where retired.contains(c.name.trimmingCharacters(in: .whitespaces).lowercased()) {
            let empty = (c.receipts ?? []).isEmpty && (c.transactions ?? []).isEmpty && (c.bankAccounts ?? []).isEmpty
            if empty { context.delete(c) }
        }
        try? context.save()
    }

    /// Moves everything from one company to another, then removes the empty company.
    @MainActor
    static func merge(_ source: Company, into target: Company, context: ModelContext) {
        guard source.persistentModelID != target.persistentModelID else { return }
        for r in source.receipts ?? [] { r.company = target }
        for t in source.transactions ?? [] { t.company = target }
        for a in source.bankAccounts ?? [] { a.company = target }
        try? context.save()
        // Deleting a company cascades to its receipts, so only remove it once it is empty.
        if (source.receipts ?? []).isEmpty {
            context.delete(source)
            try? context.save()
        }
    }

    /// Records created before sync ids existed all got the same default id during migration.
    /// Give each a unique one: companies by name (matching other devices), accounts at random.
    @MainActor
    static func repairIDs(_ context: ModelContext) {
        var changed = false
        let companies = (try? context.fetch(FetchDescriptor<Company>())) ?? []
        let companyCounts = Dictionary(grouping: companies, by: \.companyID)
        for c in companies where (companyCounts[c.companyID]?.count ?? 0) > 1 {
            c.companyID = Company.stableID(for: c.name)
            changed = true
        }
        let accounts = (try? context.fetch(FetchDescriptor<BankAccount>())) ?? []
        let accountCounts = Dictionary(grouping: accounts, by: \.accountID)
        for a in accounts where (accountCounts[a.accountID]?.count ?? 0) > 1 {
            a.accountID = UUID()
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Sync can bring back a second copy of a company (for example after reinstalling).
    /// Merge same named companies into the oldest one, the same choice on every device.
    @MainActor
    static func mergeDuplicates(_ context: ModelContext) {
        let all = ((try? context.fetch(FetchDescriptor<Company>())) ?? [])
            .sorted { ($0.createdAt, $0.companyID.uuidString) < ($1.createdAt, $1.companyID.uuidString) }
        var keep: [String: Company] = [:]
        var duplicates: [Company] = []
        for c in all {
            let key = c.name.trimmingCharacters(in: .whitespaces).lowercased()
            if let first = keep[key] {
                for r in c.receipts ?? [] { r.company = first }
                duplicates.append(c)
            } else {
                keep[key] = c
            }
        }
        guard !duplicates.isEmpty else { return }
        try? context.save()
        // Deleting a company cascades to its receipts, so only remove ones that are now empty.
        for c in duplicates where (c.receipts ?? []).isEmpty { context.delete(c) }
        try? context.save()
    }
}
