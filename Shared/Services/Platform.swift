import SwiftUI
import SwiftData
import ImageIO
import UniformTypeIdentifiers
import PDFKit

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}
#else
import AppKit
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}
#endif

extension View {
    /// Number pad on iPhone, nothing on Mac.
    func decimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

enum ImagePrep {
    /// Upright JPEG (max 2200 px) for storage plus a small thumbnail for lists.
    /// Works from any image file data, applying the photo's rotation.
    static func prepare(_ data: Data) -> (full: Data, thumbnail: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = jpeg(source, maxSide: 2200, quality: 0.7),
              let thumb = jpeg(source, maxSide: 240, quality: 0.6) else { return nil }
        return (full, thumb)
    }

    private static func jpeg(_ source: CGImageSource, maxSide: Int, quality: Double) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

enum StoreInfo {
    static let cloudKitContainer = "iCloud.com.kolincunningham.ReceiptScanner"
    nonisolated(unsafe) static var cloudKitEnabled = false
    /// Set when the saved database could not be opened. The app then runs on an empty
    /// in-memory store and changes nothing on disk.
    nonisolated(unsafe) static var loadError: String?

    static func makeContainer() -> ModelContainer {
        let schema = Schema([Company.self, Receipt.self, BankAccount.self, BankTransaction.self, LedgerAccount.self, LedgerJournal.self])
        // Copy the database aside before a new version touches it.
        StoreBackup.backupIfNeeded()

        // CloudKit stops the app outright (rather than throwing) when the iCloud entitlement is
        // missing, so only try it in builds made with a paid team and the ICLOUD flag.
        #if ICLOUD && targetEnvironment(simulator)
        let tryCloudKit = FileManager.default.ubiquityIdentityToken != nil
        #elseif ICLOUD
        let tryCloudKit = true
        #else
        let tryCloudKit = false
        #endif
        if tryCloudKit {
            do {
                // Records sync to your private iCloud database, so iPhone and Mac see the same data.
                let config = ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloudKitContainer))
                let container = try ModelContainer(for: schema, configurations: config)
                cloudKitEnabled = true
                return container
            } catch {
                print("iCloud store unavailable, running on this device only: \(error)")
            }
        }
        do {
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // Never delete or replace the saved store. Run empty in memory and say so.
            loadError = error.localizedDescription
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: memory)
        }
    }
}

/// Copies the database (receipts, scans, bank data) to Documents/Backups before a new build
/// opens it, and at least weekly. On iPhone that folder shows in Files › On My iPhone › Receipt Scanner.
enum StoreBackup {
    static let keep = 6

    static func backupIfNeeded() {
        let fm = FileManager.default
        let support = URL.applicationSupportDirectory
        let items = ((try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("default.store") || $0.lastPathComponent == ".default_SUPPORT" }
        guard items.contains(where: { $0.lastPathComponent == "default.store" }) else { return }

        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let defaults = UserDefaults.standard
        let lastBuild = defaults.string(forKey: "backup.lastBuild")
        let lastDate = defaults.object(forKey: "backup.lastDate") as? Date ?? .distantPast
        guard lastBuild != build || Date.now.timeIntervalSince(lastDate) > 7 * 86400 else { return }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        let backups = URL.documentsDirectory.appending(path: "Backups")
        let dest = backups.appending(path: "\(f.string(from: .now)) build \(build)")
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for item in items {
                try fm.copyItem(at: item, to: dest.appending(path: item.lastPathComponent))
            }
            defaults.set(build, forKey: "backup.lastBuild")
            defaults.set(Date.now, forKey: "backup.lastDate")
        } catch {
            print("Backup failed: \(error)")
            return
        }
        // Keep the newest few. Folder names sort by date.
        let all = ((try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(keep) { try? fm.removeItem(at: old) }
    }
}

/// Imports receipt images (from Photos, Files or drag and drop) and reads them with AI.
@MainActor
enum ReceiptIntake {
    /// `photoIDs` and `dates` line up with `imageData` when importing from Photos: the id stops
    /// double imports and the photo's date is used when the receipt text has no readable date.
    static func add(imageData: [Data], photoIDs: [String]? = nil, dates: [Date?]? = nil, to company: Company, context: ModelContext) {
        var created: [Receipt] = []
        for (i, data) in imageData.enumerated() {
            guard let prepared = ImagePrep.prepare(data) else { continue }
            let receipt = Receipt()
            context.insert(receipt)
            receipt.imageData = prepared.full
            receipt.thumbnailData = prepared.thumbnail
            receipt.company = company
            receipt.isProcessing = true
            if let ids = photoIDs, i < ids.count { receipt.sourcePhotoID = ids[i] }
            if let dates, i < dates.count, let d = dates[i] { receipt.date = d }
            created.append(receipt)
        }
        try? context.save()
        Task {
            for receipt in created {
                await ReceiptProcessor.process(receipt, context: context)
            }
            Ledger.autoMatch(context: context)
            await CloudDriveSync.shared.sync(context: context)
        }
    }
}

/// Emailed receipts often arrive as PDFs: render each page so it can be read like a photo.
enum PDFPages {
    static func renderJPEGs(_ url: URL) -> [Data] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return (0..<min(doc.pageCount, 10)).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 2200 / max(bounds.width, bounds.height, 1)
            let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            #if canImport(UIKit)
            return image.jpegData(compressionQuality: 0.85)
            #else
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            #endif
        }
    }

    /// Image or PDF file contents, ready for ReceiptIntake.
    static func receiptImages(from url: URL) -> [Data] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "pdf" { return renderJPEGs(url) }
        return (try? Data(contentsOf: url)).map { [$0] } ?? []
    }
}
