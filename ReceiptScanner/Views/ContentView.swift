import SwiftUI
import SwiftData
import VisionKit

struct ShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Company.name) private var companies: [Company]
    @Query(sort: [SortDescriptor(\Receipt.date, order: .reverse), SortDescriptor(\Receipt.createdAt, order: .reverse)])
    private var allReceipts: [Receipt]
    @AppStorage("selectedCompanyName") private var selectedCompanyName = ""

    @State private var showScanner = false
    @State private var showCompanies = false
    @State private var showLibrarySync = false
    @State private var showFileImporter = false
    @State private var showPhotoFinder = ProcessInfo.processInfo.arguments.contains("-autoFindPhotos")
    @State private var shareFile: ShareFile?
    @State private var alertMessage: String?
    @State private var sync = CloudDriveSync.shared

    private var selectedCompany: Company? {
        companies.first { $0.name == selectedCompanyName }
    }

    private var receipts: [Receipt] {
        guard let id = selectedCompany?.persistentModelID else { return [] }
        return allReceipts.filter { $0.company?.persistentModelID == id }
    }

    private var companyTotal: Double {
        receipts.reduce(0) { $0 + $1.total }
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem = StoreInfo.loadError {
                    Section {
                        Label("Your saved receipts could not be opened by this version, so it is showing nothing and has changed nothing. They are still on this iPhone. Ask Claude to fix the update. Detail: \(problem)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section("Company") {
                    if companies.isEmpty {
                        Button("Add your first company") { showCompanies = true }
                    } else {
                        Picker("Company", selection: $selectedCompanyName) {
                            ForEach(companies) { company in
                                Text(company.name).tag(company.name)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 140)
                    }
                }

                Section {
                    // Scans are kept inside this app and the sync folder only, never in the Photos app.
                    Button(action: startScan) {
                        Label("Scan receipt", systemImage: "doc.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selectedCompany == nil)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    if receipts.isEmpty {
                        Text("No receipts yet for \(selectedCompanyName). Tap Scan receipt to add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(receipts) { receipt in
                        NavigationLink(value: receipt) {
                            ReceiptRowView(receipt: receipt)
                        }
                    }
                    .onDelete(perform: delete)
                } header: {
                    HStack {
                        Text(receipts.count == 1 ? "1 receipt" : "\(receipts.count) receipts")
                        Spacer()
                        Text(companyTotal, format: .currency(code: "AUD"))
                    }
                } footer: {
                    syncFooter
                }
            }
            .navigationTitle("Receipts")
            .navigationDestination(for: Receipt.self) { ReceiptEditView(receipt: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showCompanies = true } label: {
                        Label("Companies", systemImage: "building.2")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await shareSpreadsheet() } } label: {
                            Label("Share spreadsheet", systemImage: "square.and.arrow.up")
                        }
                        Button { showPhotoFinder = true } label: {
                            Label("Find receipts in Photos…", systemImage: "photo.badge.magnifyingglass")
                        }
                        Button { showFileImporter = true } label: {
                            Label("Import from Files…", systemImage: "doc.badge.plus")
                        }
                        .disabled(selectedCompany == nil)
                        Button { showLibrarySync = true } label: {
                            Label("Sync with Mac…", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Label("Spreadsheet", systemImage: "tablecells")
                    }
                }
            }
            .sheet(isPresented: $showCompanies) {
                NavigationStack { CompaniesView() }
            }
            .sheet(item: $shareFile) { file in
                ActivityView(items: [file.url])
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView { images in
                    showScanner = false
                    addReceipts(from: images)
                } onCancel: {
                    showScanner = false
                }
                .ignoresSafeArea()
            }
            .alert("Receipts", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, let company = selectedCompany else { return }
                ReceiptIntake.add(imageData: urls.flatMap(PDFPages.receiptImages(from:)), to: company, context: context)
            }
            .onChange(of: companies.map(\.name)) { _, _ in
                CompanyStore.mergeDuplicates(context)
                CompanyStore.applyFolds(context)
                fixSelection()
            }
            .onAppear {
                CompanyStore.repairIDs(context)
                CompanyStore.seedIfNeeded(context)
                CompanyStore.applyFolds(context)
                CompanyStore.mergeDuplicates(context)
                fixSelection()
            }
            .sheet(isPresented: $showPhotoFinder) {
                NavigationStack { PhotoReceiptFinderView() }
            }
            .sheet(isPresented: $showLibrarySync) {
                NavigationStack {
                    LibrarySyncView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showLibrarySync = false } } }
                }
            }
        }
    }

    @ViewBuilder
    private var syncFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sync.isSyncing {
                Text("Saving spreadsheet…")
            } else if let date = sync.lastSynced {
                Text("\(sync.lastMessage) · \(date.formatted(.relative(presentation: .named)))")
            } else if !sync.lastMessage.isEmpty {
                Text(sync.lastMessage)
            }
            #if ICLOUD
            if !StoreInfo.cloudKitEnabled {
                Text("iCloud sync is off, so receipts are stored on this iPhone only. Sign in to iCloud and check the iCloud capability in Xcode.")
                    .foregroundStyle(.orange)
            }
            #endif
        }
    }

    // MARK: Actions

    private func fixSelection() {
        if selectedCompany == nil, let first = companies.first {
            selectedCompanyName = first.name
        }
    }

    private func startScan() {
        if VNDocumentCameraViewController.isSupported {
            showScanner = true
        } else {
            alertMessage = "The document camera is not available on this device. Use Import from Files in the table menu instead."
        }
    }

    private func addReceipts(from images: [UIImage]) {
        guard let company = selectedCompany else { return }
        ReceiptIntake.add(imageData: images.compactMap { $0.jpegData(compressionQuality: 0.9) }, to: company, context: context)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(receipts[index]) }
        try? context.save()
        Task { await sync.sync(context: context) }
    }

    private func shareSpreadsheet() async {
        do {
            shareFile = ShareFile(url: try await sync.makeShareableCopy(context: context))
        } catch {
            alertMessage = "Could not build the spreadsheet: \(error.localizedDescription)"
        }
    }
}

struct ReceiptRowView: View {
    let receipt: Receipt

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = receipt.thumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))

            VStack(alignment: .leading, spacing: 3) {
                if receipt.isProcessing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading receipt…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(receipt.merchant.isEmpty ? "Unknown merchant" : receipt.merchant)
                        .font(.headline)
                        .lineLimit(1)
                    Label(receipt.category.rawValue, systemImage: receipt.category.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(receipt.date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !receipt.isProcessing {
                Text(receipt.total, format: .currency(code: receipt.currency))
                    .monospacedDigit()
            }
        }
    }
}
