import SwiftUI
import TTMCore

/// Manage the category tree (CATEGORIZATION_PLAN.md §2 deliberate path / §5).
/// Two levels: top-level categories (a group once it has children) hold leaves.
/// Rename, recolor, regroup, reorder, merge, and delete-with-reassign live here;
/// system categories are guarded.
struct CategoriesView: View {
    @Bindable var model: AppModel
    @State private var editing: CategorySummary?
    @State private var addParent: String?? = nil   // .some(nil)=top level, .some(id)=in group
    @State private var newName = ""
    @State private var promotion: AppModel.PromotionPrompt?
    @State private var didDebugPromote = false

    private var topLevel: [CategorySummary] {
        model.categories.filter { $0.parentId == nil && $0.kind == "expense" }
    }
    private func count(_ id: String) -> Int { model.categoryCounts[id] ?? 0 }

    var body: some View {
        NavigationStack {
            List {
                ForEach(topLevel) { parent in
                    Section {
                        ForEach(model.children(of: parent.id)) { leaf in
                            leafRow(leaf)
                        }
                        .onMove { from, to in reorderChildren(of: parent.id, from: from, to: to) }
                        Button { promptAdd(parent: parent.id) } label: {
                            Label("Add subcategory", systemImage: "plus")
                                .font(.subheadline).foregroundStyle(Brand.evergreen)
                        }
                        .accessibilityIdentifier("add-sub-\(parent.id)")
                    } header: { parentHeader(parent) }
                    .listRowBackground(Brand.surface)
                }

                Section {
                    ForEach(model.systemCategories) { sys in
                        HStack(spacing: 8) {
                            CategoryDot(hex: sys.color)
                            Text(sys.name).foregroundStyle(Brand.ink)
                            Spacer()
                            Text("system").font(.caption2).foregroundStyle(Brand.slate)
                        }
                        .listRowBackground(Brand.surface)
                    }
                } header: { Eyebrow("System") }
            }
            .statementBackground()
            .inlineNavTitle("Categories")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { promptAdd(parent: nil) } label: { Label("New top-level category", systemImage: "folder.badge.plus") }
                    } label: { Image(systemName: "plus") }
                }
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                #endif
            }
            .sheet(item: $editing) { cat in CategoryEditSheet(model: model, category: cat) }
            .alert("New category", isPresented: addAlertBinding) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let parent = addParent ?? nil
                    let name = newName; newName = ""
                    Task {
                        if let parent {
                            promotion = await model.createSubcategory(name: name, parentId: parent)
                        } else {
                            await model.createCategory(name: name, parentId: nil)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { newName = "" }
            } message: {
                Text(addParent.flatMap { $0 }.flatMap { id in model.categories.first { $0.id == id }?.name }
                        .map { "Inside \($0)" } ?? "At the top level")
            }
            // Graceful promotion: a leaf that gained its first child still holds its
            // transactions — offer to move them into a subcategory.
            .confirmationDialog("Move transactions?", isPresented: promotionBinding, presenting: promotion) { p in
                Button("Move \(p.txnCount) to “\(p.newChildName)”") {
                    Task { await model.moveCategoryTransactions(fromId: p.parentId, toId: p.newChildId) }
                }
                Button("Move to “\(p.parentName) · General”") {
                    Task { await model.moveToNewGeneral(parentId: p.parentId) }
                }
                Button("Keep on “\(p.parentName)”", role: .cancel) {}
            } message: { p in
                Text("“\(p.parentName)” is now a group. Move its \(p.txnCount) transaction\(p.txnCount == 1 ? "" : "s") into a subcategory so they stay categorized?")
            }
            .task { await runDebugPromoteIfRequested() }
        }
    }

    private var promotionBinding: Binding<Bool> {
        Binding(get: { promotion != nil }, set: { if !$0 { promotion = nil } })
    }

    /// Test hook: exercise the real detect→prompt path on "auto" without needing
    /// to scroll a deep List in a UI test. Gated by a launch argument.
    private func runDebugPromoteIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-debugPromote"), !didDebugPromote else { return }
        didDebugPromote = true
        await model.refresh()
        // Wait for sample data to land (loadSampleData races this .task).
        for _ in 0..<25 where (model.categoryCounts["auto"] ?? 0) == 0 {
            try? await Task.sleep(for: .milliseconds(150))
            await model.refresh()
        }
        promotion = await model.createSubcategory(name: "Fuel", parentId: "auto")
    }

    private func parentHeader(_ parent: CategorySummary) -> some View {
        HStack(spacing: 8) {
            CategoryDot(hex: parent.color)
            Text(parent.name).foregroundStyle(Brand.ink).textCase(nil).font(.headline)
            if model.isGroup(parent.id) {
                Text("group").font(.caption2).foregroundStyle(Brand.slate)
            } else if count(parent.id) > 0 {
                Text("\(count(parent.id))").font(.caption2).foregroundStyle(Brand.slate)
            }
            Spacer()
            Button { editing = parent } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Brand.slate) }
        }
    }

    private func leafRow(_ leaf: CategorySummary) -> some View {
        Button { editing = leaf } label: {
            HStack(spacing: 8) {
                CategoryDot(hex: leaf.color)
                Text(leaf.name).foregroundStyle(Brand.ink)
                Spacer()
                if count(leaf.id) > 0 { Text("\(count(leaf.id))").font(.caption2).foregroundStyle(Brand.slate) }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Brand.slate)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("Delete", role: .destructive) { editing = leaf }
        }
    }

    // MARK: Actions

    private var addAlertBinding: Binding<Bool> {
        Binding(get: { addParent != nil }, set: { if !$0 { addParent = nil } })
    }
    private func promptAdd(parent: String?) { addParent = .some(parent) }

    private func reorderChildren(of parentId: String, from: IndexSet, to: Int) {
        var ids = model.children(of: parentId).map { $0.id }
        ids.move(fromOffsets: from, toOffset: to)
        Task { await model.reorderCategories(orderedIds: ids) }
    }
}

/// Edit a single category: rename, recolor, regroup, merge, delete-with-reassign.
private struct CategoryEditSheet: View {
    @Bindable var model: AppModel
    let category: CategorySummary
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    private var isGroup: Bool { model.isGroup(category.id) }
    private var count: Int { model.categoryCounts[category.id] ?? 0 }
    /// Other assignable leaves (valid merge / reassign targets).
    private var otherLeaves: [CategorySummary] {
        model.categories.filter { !model.isGroup($0.id) && !$0.isSystem && $0.id != category.id }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        .onSubmit { Task { await model.renameCategory(id: category.id, name: name) } }
                } header: { Eyebrow("Name") }
                .listRowBackground(Brand.surface)

                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                        ForEach(CategoryPalette.hexes, id: \.self) { hex in
                            Circle().fill(Color(categoryHex: hex))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Brand.ink, lineWidth: category.color?.uppercased() == hex.uppercased() ? 2 : 0))
                                .onTapGesture { Task { await model.recolorCategory(id: category.id, color: hex) } }
                        }
                    }
                    .padding(.vertical, 4)
                } header: { Eyebrow("Color") }
                .listRowBackground(Brand.surface)

                if !category.isSystem && !isGroup {
                    Section {
                        Menu {
                            Button("Top level") { Task { await model.moveCategory(id: category.id, toParentId: nil) } }
                            ForEach(model.expenseGroups.filter { $0.id != category.id }) { g in
                                Button(g.name) { Task { await model.moveCategory(id: category.id, toParentId: g.id) } }
                            }
                        } label: {
                            HStack { Text("Move to group"); Spacer()
                                Text(category.parentId.flatMap { id in model.categories.first { $0.id == id }?.name } ?? "Top level")
                                    .foregroundStyle(Brand.slate) }
                        }
                        Menu {
                            ForEach(otherLeaves) { target in
                                Button(target.name) { Task { await model.mergeCategory(fromId: category.id, intoId: target.id); dismiss() } }
                            }
                        } label: { HStack { Text("Merge into…"); Spacer(); Image(systemName: "arrow.triangle.merge").foregroundStyle(Brand.slate) } }
                    } header: { Eyebrow("Organize") }
                    .listRowBackground(Brand.surface)
                }

                if !category.isSystem {
                    Section {
                        deleteControl
                    } header: { Eyebrow("Delete") }
                    .listRowBackground(Brand.surface)
                }
            }
            .statementBackground()
            .inlineNavTitle(category.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") {
                Task { await model.renameCategory(id: category.id, name: name); dismiss() }
            } } }
            .onAppear { name = category.name }
        }
    }

    @ViewBuilder private var deleteControl: some View {
        if isGroup {
            Button("Delete group (subcategories move to top level)", role: .destructive) {
                Task { await model.deleteCategory(id: category.id, reassignTo: nil); dismiss() }
            }
        } else if count > 0 {
            // A leaf with transactions must send them somewhere.
            Menu {
                ForEach(otherLeaves) { target in
                    Button(target.name) { Task { await model.deleteCategory(id: category.id, reassignTo: target.id); dismiss() } }
                }
            } label: {
                Text("Delete & move \(count) transaction\(count == 1 ? "" : "s") to…").foregroundStyle(Brand.clay)
            }
        } else {
            Button("Delete", role: .destructive) {
                Task { await model.deleteCategory(id: category.id, reassignTo: nil); dismiss() }
            }
        }
    }
}
