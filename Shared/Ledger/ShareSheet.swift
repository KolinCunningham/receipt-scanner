import SwiftUI

/// Share sheet on iPhone, Save panel on Mac.
struct ShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        ActivityViewBridge(items: [url])
        #else
        VStack(spacing: 16) {
            Text(url.lastPathComponent).font(.headline)
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Close") { dismiss() }
        }
        .padding(30)
        #endif
    }
}

#if os(iOS)
import UIKit
struct ActivityViewBridge: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
import AppKit
#endif
