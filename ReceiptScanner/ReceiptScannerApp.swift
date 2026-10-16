import SwiftUI
import SwiftData

/// Receipts on iPhone: scanning only. Bank, reconciling and reports live in the Ledger app,
/// which shares data through the Receipts Library sync folder.
@main
struct ReceiptScannerApp: App {
    let container = StoreInfo.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .periodicSync()
                #if DEBUG
                .task { await DemoData.loadIfRequested(context: container.mainContext) }
                #endif
        }
        .modelContainer(container)
    }
}
