#if DEBUG
import Foundation
import SwiftData

/// Debug builds only: launch with -demoData to load a sample statement and receipts for testing.
@MainActor
enum DemoData {
    static func loadIfRequested(context: ModelContext) async {
        guard ProcessInfo.processInfo.arguments.contains("-demoData") else { return }
        guard ((try? context.fetchCount(FetchDescriptor<BankAccount>())) ?? 0) == 0 else { return }
        CompanyStore.seedIfNeeded(context)
        let company = (try? context.fetch(FetchDescriptor<Company>()))?.first { $0.name == "My Business" }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let samples: [(String, Double, String)] = [
            ("2026-10-13", 12.30, "The Grounds Cafe"),
            ("2026-10-12", 88.15, "Ampol Bondi"),
            ("2026-10-10", 45.00, "Officeworks"),
            ("2026-09-20", 19.99, "Kmart"),
        ]
        for (date, total, merchant) in samples {
            let r = Receipt()
            context.insert(r)
            r.date = f.date(from: date)!
            r.total = total
            r.merchant = merchant
            r.company = company
            r.category = ReceiptAnalyzer.keywordCategory(for: merchant)
            r.classifiedBy = "Text rules"
        }
        // Give the first receipt a small generated photo so photo sync can be tested.
        if let first = (try? context.fetch(FetchDescriptor<Receipt>()))?.first(where: { $0.merchant == "The Grounds Cafe" }),
           let jpeg = demoJPEG() {
            first.imageData = jpeg
            first.thumbnailData = ImagePrep.prepare(jpeg)?.thumbnail
        }
        try? context.save()

        let account = BankAccount(name: "Business Everyday", institution: "CommBank")
        context.insert(account)
        account.company = company
        let csv = """
        14/10/2026,"-12.30","SQ *THE GROUNDS CAFE ALEXANDRIA AU Card xx1234 Value Date: 13/10/2026","+1234.56"
        13/10/2026,"+2500.00","Transfer from My Business Pty Ltd","+1246.86"
        12/10/2026,"-88.15","AMPOL BONDI 1234 BONDI NSW AU Card xx1234","-1253.14"
        12/10/2026,"-45.00","OFFICEWORKS 0345 BONDI JUNCTION AU","-1165.00"
        11/10/2026,"-45.00","OFFICEWORKS 0345 BONDI JUNCTION AU","-1120.00"
        09/10/2026,"-29.99","ADOBE *CREATIVE CLOUD SYDNEY AU","-1075.00"
        08/10/2026,"-6.00","MONTHLY ACCOUNT FEE","-1045.01"
        07/10/2026,"-64.20","WOOLWORTHS 1234 BONDI AU","-1039.01"
        """
        if let parsed = try? BankImport.parse(data: Data(csv.utf8), fileName: "demo.csv") {
            _ = await Ledger.importTransactions(parsed, into: account, context: context)
        }
    }
}
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private func demoJPEG() -> Data? {
    guard let ctx = CGContext(data: nil, width: 300, height: 450, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.95, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
    for i in 0..<8 { ctx.fill(CGRect(x: 30, y: 380 - i * 40, width: 240 - (i % 3) * 50, height: 12)) }
    guard let image = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}
#endif
