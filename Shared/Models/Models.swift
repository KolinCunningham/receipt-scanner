import Foundation
import SwiftData
import CryptoKit

/// Expense categories the AI picks from. Raw values are what appear in the spreadsheet.
enum ReceiptCategory: String, CaseIterable, Codable, Identifiable {
    case meals = "Meals & Entertainment"
    case travel = "Travel & Transport"
    case fuel = "Fuel & Vehicle"
    case accommodation = "Accommodation"
    case office = "Office Supplies"
    case software = "Software & Subscriptions"
    case equipment = "Equipment & Hardware"
    case phoneInternet = "Phone & Internet"
    case utilities = "Utilities"
    case marketing = "Advertising & Marketing"
    case professional = "Professional Services"
    case groceries = "Groceries"
    case bankFees = "Bank Fees & Interest"
    case tax = "Tax & Government"
    case income = "Income"
    case transfer = "Transfers"
    case other = "Other"

    /// Categories that make sense for a purchase receipt.
    static var expenseCases: [ReceiptCategory] {
        allCases.filter { ![.income, .transfer].contains($0) }
    }

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .meals: "fork.knife"
        case .travel: "airplane"
        case .fuel: "fuelpump"
        case .accommodation: "bed.double"
        case .office: "paperclip"
        case .software: "square.stack.3d.up"
        case .equipment: "desktopcomputer"
        case .phoneInternet: "antenna.radiowaves.left.and.right"
        case .utilities: "bolt"
        case .marketing: "megaphone"
        case .professional: "briefcase"
        case .groceries: "cart"
        case .bankFees: "building.columns"
        case .tax: "doc.text.magnifyingglass"
        case .income: "arrow.down.circle"
        case .transfer: "arrow.left.arrow.right"
        case .other: "tag"
        }
    }
}

// CloudKit sync rules: every stored property needs a default, relationships must be optional,
// and no unique constraints.

@Model
final class Company {
    /// Stable id for syncing. Derived from the name so the same company made on two devices matches.
    var companyID: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \Receipt.company)
    var receipts: [Receipt]? = []
    @Relationship(deleteRule: .nullify, inverse: \BankTransaction.company)
    var transactions: [BankTransaction]? = []
    @Relationship(deleteRule: .nullify, inverse: \BankAccount.company)
    var bankAccounts: [BankAccount]? = []
    /// This company's own chart of accounts (empty means it uses the standard chart).
    @Relationship(deleteRule: .nullify, inverse: \LedgerAccount.company)
    var ledgerAccounts: [LedgerAccount]? = []
    @Relationship(deleteRule: .nullify, inverse: \LedgerJournal.company)
    var journals: [LedgerJournal]? = []

    init(name: String) {
        self.name = name
        self.companyID = Company.stableID(for: name)
    }

    static func stableID(for name: String) -> UUID {
        StableID.make("company:" + name.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

@Model
final class Receipt {
    var receiptID: UUID = UUID()
    var merchant: String = ""
    var date: Date = Date.now
    var total: Double = 0
    var gst: Double = 0
    var currency: String = "AUD"
    var categoryRaw: String = ReceiptCategory.other.rawValue
    var notes: String = ""
    var ocrText: String = ""
    /// Who chose the category: "Apple Intelligence", "Your earlier receipts", "Text rules" or "You".
    var classifiedBy: String = ""
    var isProcessing: Bool = false
    /// Photos library id when the receipt was imported from Photos, so it is never imported twice.
    var sourcePhotoID: String = ""
    var createdAt: Date = Date.now
    @Attribute(.externalStorage) var imageData: Data?
    var thumbnailData: Data?
    var company: Company?
    @Relationship(deleteRule: .nullify, inverse: \BankTransaction.receipt)
    var bankTransaction: BankTransaction?

    init() {}

    var category: ReceiptCategory {
        get { ReceiptCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    /// Short stable tag used in image file names so edits can find and replace the old file.
    var shortID: String { String(receiptID.uuidString.prefix(8)) }
}

@Model
final class BankAccount {
    var accountID: UUID = UUID()
    var name: String = ""
    var institution: String = ""
    /// Business or Personal.
    var kind: String = "Business"
    var currency: String = "AUD"
    /// This bank account's code in the ledger, e.g. 090.
    var ledgerCode: String = ""
    var createdAt: Date = Date.now
    /// Transactions imported into this account default to this company.
    var company: Company?
    @Relationship(deleteRule: .cascade, inverse: \BankTransaction.account)
    var transactions: [BankTransaction]? = []

    init(name: String, institution: String = "", kind: String = "Business") {
        self.name = name
        self.institution = institution
        self.kind = kind
    }
}

enum MatchStatus: String, CaseIterable, Identifiable {
    case needsReceipt = "Needs receipt"
    case matched = "Matched"
    case noReceiptNeeded = "No receipt needed"
    var id: String { rawValue }
}

@Model
final class BankTransaction {
    var transactionID: UUID = UUID()
    var date: Date = Date.now
    /// Negative is money out, positive is money in.
    var amount: Double = 0
    var details: String = ""
    var balance: Double?
    /// Dedupe key so importing an overlapping statement does not double up.
    var importKey: String = ""
    var categoryRaw: String = ReceiptCategory.other.rawValue
    var classifiedBy: String = ""
    var statusRaw: String = MatchStatus.needsReceipt.rawValue
    var matchedBy: String = ""
    var notes: String = ""
    var importedAt: Date = Date.now
    /// Ledger: account code and Xero tax type chosen for this line (empty means use the suggestion).
    var ledgerCode: String = ""
    var taxTypeRaw: String = ""
    var isReconciled: Bool = false
    var account: BankAccount?
    var company: Company?
    var receipt: Receipt?

    init() {}

    var category: ReceiptCategory {
        get { ReceiptCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var status: MatchStatus {
        get { MatchStatus(rawValue: statusRaw) ?? .needsReceipt }
        set { statusRaw = newValue.rawValue }
    }

    var isMoneyOut: Bool { amount < 0 }
    var merchantName: String { BankText.cleanMerchant(details) }
}

enum StableID {
    /// Same text gives the same UUID on every device.
    static func make(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
