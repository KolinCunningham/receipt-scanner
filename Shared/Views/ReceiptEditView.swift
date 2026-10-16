import SwiftUI
import SwiftData

struct ReceiptEditView: View {
    @Bindable var receipt: Receipt
    /// When set (Mac split view), the parent clears its selection and deletes.
    var onDelete: (() -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Company.name) private var companies: [Company]

    @State private var showFullImage = false
    @State private var confirmDelete = false
    @State private var deleteOnClose = false
    @State private var rereading = false

    private var categoryBinding: Binding<ReceiptCategory> {
        Binding {
            receipt.category
        } set: {
            receipt.category = $0
            receipt.classifiedBy = "You"
        }
    }

    private var companyBinding: Binding<String> {
        Binding {
            receipt.company?.name ?? ""
        } set: { name in
            receipt.company = companies.first { $0.name == name }
        }
    }

    private var image: PlatformImage? {
        receipt.imageData.flatMap { PlatformImage(data: $0) }
    }

    var body: some View {
        Form {
            if let image {
                Section {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 320)
                        .onTapGesture { showFullImage = true }
                } footer: {
                    Text("Tap the photo to zoom.")
                }
            }

            Section("Details") {
                TextField("Merchant", text: $receipt.merchant)
                DatePicker("Date", selection: $receipt.date, displayedComponents: .date)
                LabeledContent("Total") {
                    TextField("0.00", value: $receipt.total, format: .number.precision(.fractionLength(2)))
                        .decimalKeyboard()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("GST") {
                    TextField("0.00", value: $receipt.gst, format: .number.precision(.fractionLength(2)))
                        .decimalKeyboard()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Currency") {
                    TextField("AUD", text: $receipt.currency)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                Picker("Category", selection: categoryBinding) {
                    ForEach(ReceiptCategory.expenseCases) { category in
                        Label(category.rawValue, systemImage: category.symbol).tag(category)
                    }
                }
                Picker("Company", selection: companyBinding) {
                    ForEach(companies) { company in
                        Text(company.name).tag(company.name)
                    }
                }
            } footer: {
                if !receipt.classifiedBy.isEmpty {
                    Text("Category chosen by \(receipt.classifiedBy). Change it and future receipts from this merchant will follow your choice.")
                }
            }

            Section("Bank") {
                if let t = receipt.bankTransaction {
                    LabeledContent("Matched to") {
                        VStack(alignment: .trailing) {
                            Text(t.merchantName)
                            Text("\(t.date.formatted(date: .abbreviated, time: .omitted)) · \(t.account?.name ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Unmatch", role: .destructive) { Ledger.unlink(t, context: context) }
                } else {
                    Text("Not matched to a bank transaction yet. Import a statement in Bank and check Match.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notes") {
                TextField("What was this for?", text: $receipt.notes, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section {
                Button {
                    Task {
                        rereading = true
                        await ReceiptProcessor.process(receipt, context: context)
                        rereading = false
                    }
                } label: {
                    HStack {
                        Label("Read again with AI", systemImage: "sparkles")
                        if rereading { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(rereading || receipt.isProcessing)
            }

            if !receipt.ocrText.isEmpty {
                Section {
                    DisclosureGroup("Scanned text") {
                        Text(receipt.ocrText)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                Button("Delete receipt", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(receipt.merchant.isEmpty ? "Receipt" : receipt.merchant)
        .inlineTitle()
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullImage) {
            if let image { ZoomableImageView(image: image) }
        }
        #else
        .sheet(isPresented: $showFullImage) {
            if let image { ZoomableImageView(image: image).frame(minWidth: 700, minHeight: 800) }
        }
        #endif
        .confirmationDialog("Delete this receipt?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let onDelete {
                    onDelete()
                } else {
                    deleteOnClose = true
                    dismiss()
                }
            }
        }
        .onDisappear {
            // Delete after leaving the screen so the form never reads a deleted record.
            if deleteOnClose { context.delete(receipt) }
            try? context.save()
            Task { await CloudDriveSync.shared.sync(context: context) }
        }
    }
}

struct ZoomableImageView: View {
    let image: PlatformImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = max(1, lastScale * $0.magnification) }
                        .onEnded { _ in lastScale = scale }
                        .simultaneously(with: DragGesture()
                            .onChanged {
                                offset = CGSize(width: lastOffset.width + $0.translation.width,
                                                height: lastOffset.height + $0.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset })
                )
                .onTapGesture(count: 2) {
                    withAnimation { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding()
        }
    }
}
