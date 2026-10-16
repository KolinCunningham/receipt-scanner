import SwiftUI
import SwiftData

struct LibrarySyncView: View {
    @Environment(\.modelContext) private var context
    @State private var sync = LibrarySync.shared
    @State private var showPicker = false
    @State private var confirmStop = false
    @Query private var receipts: [Receipt]
    @Query private var transactions: [BankTransaction]
    @Query private var bankAccounts: [BankAccount]

    var body: some View {
        Form {
            Section {
                Text("Your iPhone and Mac share receipts, bank accounts and matches through one folder in iCloud Drive. Pick the same folder on both. If you ever reinstall the app, pick the folder again and everything comes back.")
                    .foregroundStyle(.secondary)
            }

            Section("Sync folder") {
                if let name = sync.folderName {
                    LabeledContent("Folder", value: name)
                    Button {
                        Task { await sync.sync(context: context) }
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            if sync.isSyncing { Spacer(); ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(sync.isSyncing)
                    Button("Choose a different folder") { showPicker = true }
                    Button("Stop syncing", role: .destructive) { confirmStop = true }
                } else {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Choose folder", systemImage: "folder.badge.plus")
                    }
                    Text("In the picker tap Browse › iCloud Drive, tap Recipts once so you are inside it, then tap Open. Do not go into the folders inside it. Folders under On My iPhone will not sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if sync.folderName == nil && !sync.status.isEmpty {
                Section { Text(sync.status).foregroundStyle(.orange) }
            }
            if sync.folderName != nil {
                Section("Status") {
                    Text(sync.status.isEmpty ? "Not synced yet." : sync.status)
                        .foregroundStyle(sync.status.contains("folder") && sync.status.contains("choose") || sync.status.contains("Choose") ? Color.orange : Color.primary)
                    if let date = sync.lastSync {
                        LabeledContent("Last sync", value: date.formatted(.relative(presentation: .named)))
                    }
                }
            }

            Section {
                LabeledContent("Receipts", value: "\(receipts.count)")
                LabeledContent("Bank accounts", value: "\(bankAccounts.count)")
                LabeledContent("Bank transactions", value: "\(transactions.count)")
            } header: {
                Text("On this device")
            } footer: {
                Text("When everything is connected, these numbers are the same in the Receipts app, the Ledger app and on the Mac (give each a minute to sync).")
            }

            if let warning = sync.pendingDeletionWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Yes, I deleted them on purpose") {
                        sync.confirmLargeDeletes()
                        Task { await sync.sync(context: context) }
                    }
                } header: {
                    Text("Check before deleting")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync with Mac")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            if sync.setFolder(url) {
                Task { await CloudDriveSync.shared.sync(context: context) }
            }
        }
        .confirmationDialog("Stop syncing?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop syncing", role: .destructive) { sync.stopSyncing() }
        } message: {
            Text("Nothing is deleted. This device keeps its receipts and the folder keeps its files.")
        }
    }
}

/// Syncs when the app comes to the front and every two minutes while it is open.
struct PeriodicSync: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .task {
                while !Task.isCancelled {
                    await CloudDriveSync.shared.sync(context: context)
                    try? await Task.sleep(for: .seconds(120))
                }
            }
            .onChange(of: phase) { _, newPhase in
                if newPhase == .active { Task { await CloudDriveSync.shared.sync(context: context) } }
            }
    }
}

extension View {
    func periodicSync() -> some View { modifier(PeriodicSync()) }
}
