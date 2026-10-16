import SwiftUI
import SwiftData

struct CompaniesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Company.name) private var companies: [Company]
    @AppStorage("selectedCompanyName") private var selectedCompanyName = ""

    @State private var showAdd = false
    @State private var newName = ""
    @State private var renaming: Company?
    @State private var renameText = ""
    @State private var deleting: Company?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(companies) { company in
                    Button {
                        renameText = company.name
                        renaming = company
                    } label: {
                        HStack {
                            Text(company.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(company.receipts?.count ?? 0)").foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = company }
                    }
                }
            } footer: {
                Text("Tap a company to rename it. Swipe left to delete. The number is how many receipts it has.")
            }
        }
        .navigationTitle("Companies")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { newName = ""; showAdd = true } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .alert("New company", isPresented: $showAdd) {
            TextField("Company name", text: $newName)
            Button("Add") { add() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename company", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Company name", text: $renameText)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Companies", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            if let source = deleting {
                // Receipts are precious: offer to move them before anything is deleted.
                if hasItems(source) {
                    ForEach(companies.filter { $0.persistentModelID != source.persistentModelID }) { target in
                        Button("Move everything to \(target.name)") { moveAndDelete(source, into: target) }
                    }
                    Button("Delete company and its \(source.receipts?.count ?? 0) receipts", role: .destructive) { deleteCompany() }
                } else {
                    Button("Delete company", role: .destructive) { deleteCompany() }
                }
            }
        } message: {
            if let source = deleting, hasItems(source) {
                Text("It has \(source.receipts?.count ?? 0) receipts and \(source.transactions?.count ?? 0) bank transactions. Move them to another company first, or delete them too.")
            }
        }
    }

    private func hasItems(_ c: Company) -> Bool {
        !(c.receipts ?? []).isEmpty || !(c.transactions ?? []).isEmpty || !(c.bankAccounts ?? []).isEmpty
    }

    private func moveAndDelete(_ source: Company, into target: Company) {
        deleting = nil
        if selectedCompanyName == source.name { selectedCompanyName = target.name }
        CompanyStore.merge(source, into: target, context: context)
        Task { await CloudDriveSync.shared.sync(context: context) }
    }

    private func isTaken(_ name: String, except company: Company? = nil) -> Bool {
        companies.contains {
            $0.persistentModelID != company?.persistentModelID && $0.name.lowercased() == name.lowercased()
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard !isTaken(name) else { errorMessage = "\(name) is already in the list."; return }
        context.insert(Company(name: name))
        try? context.save()
        selectedCompanyName = name
    }

    private func rename() {
        guard let company = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty, name != company.name else { return }
        guard !isTaken(name, except: company) else { errorMessage = "\(name) is already in the list."; return }
        if selectedCompanyName == company.name { selectedCompanyName = name }
        company.name = name
        try? context.save()
        Task { await CloudDriveSync.shared.sync(context: context) }
    }

    private func deleteCompany() {
        guard let company = deleting else { return }
        deleting = nil
        context.delete(company)
        try? context.save()
        Task { await CloudDriveSync.shared.sync(context: context) }
    }
}
