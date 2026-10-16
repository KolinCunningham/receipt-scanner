import SwiftUI
import SwiftData
import Photos
import Vision

/// Looks through one year of the Photos library for pictures of receipts. Read only: it never
/// changes, adds or deletes anything in Photos.
@MainActor
@Observable
final class PhotoReceiptFinder {
    struct Found: Identifiable {
        let id: String
        let thumbnail: UIImage
        let date: Date?
        var selected = true
    }

    var found: [Found] = []
    var checked = 0
    var total = 0
    var isRunning = false
    var message = ""
    private var task: Task<Void, Never>?

    func start(year: Int, alreadyImported: Set<String>) {
        guard !isRunning else { return }
        found = []
        checked = 0
        total = 0
        message = ""
        task = Task { await run(year: year, skip: alreadyImported) }
    }

    func cancel() { task?.cancel() }

    private func run(year: Int, skip: Set<String>) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            message = "Receipts needs permission to look at your photos. Turn it on in Settings › Privacy & Security › Photos › Receipts."
            return
        }
        let cal = Calendar.current
        guard let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = cal.date(byAdding: .year, value: 1, to: start) else { return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@ AND mediaType == %d",
                                        start as NSDate, end as NSDate, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            if !skip.contains(asset.localIdentifier) { assets.append(asset) }
        }
        total = assets.count
        isRunning = true
        defer { isRunning = false }

        for asset in assets {
            if Task.isCancelled { break }
            if let image = await Self.image(for: asset, side: 1400),
               let cg = image.cgImage,
               let text = try? await Self.quickText(cg),
               ReceiptAnalyzer.receiptLikelihood(text) >= ReceiptAnalyzer.receiptThreshold {
                found.append(Found(id: asset.localIdentifier, thumbnail: image, date: asset.creationDate))
            }
            checked += 1
        }
        if Task.isCancelled {
            message = "Stopped. Showing what was found so far."
        } else if status == .limited {
            message = "Only the photos you allowed were checked. To check all of them: Settings › Privacy & Security › Photos › Receipts › Full Access."
        }
        if found.isEmpty && !Task.isCancelled { message = message.isEmpty ? "No receipts found in \(year)'s photos." : message }
    }

    /// Imports the ticked receipts into a company. Full quality originals, downloaded from iCloud Photos if needed.
    func importSelected(into company: Company, context: ModelContext) async -> Int {
        let picked = found.filter(\.selected)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: picked.map(\.id), options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { a, _, _ in byID[a.localIdentifier] = a }
        var datas: [Data] = [], ids: [String] = [], dates: [Date?] = []
        for item in picked {
            guard let asset = byID[item.id], let data = await Self.originalData(for: asset) else { continue }
            datas.append(data)
            ids.append(item.id)
            dates.append(item.date)
        }
        ReceiptIntake.add(imageData: datas, photoIDs: ids, dates: dates, to: company, context: context)
        let importedIDs = Set(ids)
        found.removeAll { importedIDs.contains($0.id) }
        return datas.count
    }

    // MARK: Photos and Vision

    private static func image(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                cont.resume(returning: image)
            }
        }
    }

    private static func originalData(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                cont.resume(returning: data)
            }
        }
    }

    private static func quickText(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}

struct PhotoReceiptFinderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Company.name) private var companies: [Company]
    @Query private var receipts: [Receipt]
    @AppStorage("selectedCompanyName") private var selectedCompanyName = ""

    @State private var finder = PhotoReceiptFinder()
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var companyName = ""
    @State private var importing = false
    @State private var importedNote: String?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
    private var selectedCount: Int { finder.found.filter(\.selected).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Looks through your photos from \(String(year)) for pictures of receipts. Nothing in your Photos app is changed, added or deleted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if finder.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(finder.checked), total: Double(max(finder.total, 1)))
                        Text("Checked \(finder.checked) of \(finder.total) photos · \(finder.found.count) receipts found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Stop", role: .cancel) { finder.cancel() }
                    }
                } else if finder.found.isEmpty {
                    Button {
                        finder.start(year: year, alreadyImported: Set(receipts.map(\.sourcePhotoID).filter { !$0.isEmpty }))
                    } label: {
                        Label("Find receipts in \(String(year)) photos", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if !finder.message.isEmpty {
                    Text(finder.message).font(.callout).foregroundStyle(.orange)
                }
                if let note = importedNote {
                    Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }

                if !finder.found.isEmpty {
                    HStack {
                        Text("\(finder.found.count) found. Tap to untick any that are not receipts.")
                            .font(.callout)
                        Spacer()
                        Button(selectedCount == finder.found.count ? "None" : "All") {
                            let all = selectedCount != finder.found.count
                            for i in finder.found.indices { finder.found[i].selected = all }
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach($finder.found) { $item in
                            Image(uiImage: item.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .frame(height: 130)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .opacity(item.selected ? 1 : 0.35)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(.white, item.selected ? Color.accentColor : Color.black.opacity(0.4))
                                        .padding(6)
                                }
                                .overlay(alignment: .bottomLeading) {
                                    if let d = item.date {
                                        Text(d, format: .dateTime.day().month(.abbreviated))
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .padding(6)
                                    }
                                }
                                .onTapGesture { item.selected.toggle() }
                        }
                    }
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            if !finder.found.isEmpty && !finder.isRunning {
                VStack(spacing: 8) {
                    Picker("Company", selection: $companyName) {
                        ForEach(companies) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.menu)
                    Button {
                        Task { await importTicked() }
                    } label: {
                        HStack {
                            if importing { ProgressView() }
                            Text("Import \(selectedCount) into \(companyName)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selectedCount == 0 || importing)
                    Text("Different companies? Tick just one company's receipts, import, then repeat.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.bar)
            }
        }
        .navigationTitle("Receipts in Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { finder.cancel(); dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    let now = Calendar.current.component(.year, from: .now)
                    Picker("Year", selection: $year) {
                        ForEach((now - 3)...now, id: \.self) { Text(String($0)).tag($0) }
                    }
                } label: {
                    Label(String(year), systemImage: "calendar")
                }
                .disabled(finder.isRunning)
            }
        }
        .onAppear {
            if companyName.isEmpty { companyName = selectedCompanyName.isEmpty ? (companies.first?.name ?? "") : selectedCompanyName }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-autoFindPhotos") {
                finder.start(year: year, alreadyImported: [])
            }
            #endif
        }
        .interactiveDismissDisabled(finder.isRunning || importing)
    }

    private func importTicked() async {
        guard let company = companies.first(where: { $0.name == companyName }) else { return }
        importing = true
        let n = await finder.importSelected(into: company, context: context)
        importing = false
        importedNote = "Imported \(n) into \(company.name). The AI is reading them now; they appear on the Receipts tab."
    }
}
