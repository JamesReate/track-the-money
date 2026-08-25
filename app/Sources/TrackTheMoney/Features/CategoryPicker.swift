import SwiftUI
import TTMCore

/// The grouped, searchable category picker with inline create-on-the-fly
/// (CATEGORIZATION_PLAN.md §2). It **owns its own `List`** (and the search bar):
/// vending Sections from a child view into a host List breaks button/tap delivery,
/// so the picker is self-contained and the host stacks a header above it.
/// Leaves are always visible (no collapse) — every category is one tap away.
struct CategoryPicker: View {
    @Bindable var model: AppModel
    @Binding var search: String
    var currentCategoryId: String?
    /// Leaf the on-device model proposed — marked with a sparkle in the list.
    var suggestedCategoryId: String? = nil
    /// User chose an existing leaf.
    var onPick: (String) -> Void
    /// User wants a brand-new leaf: (name, parent group id or nil for top level).
    var onCreate: (String, String?) -> Void

    @State private var createGroup: String? = nil
    @FocusState private var searchFocused: Bool

    private var trimmed: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmed.isEmpty }

    private func matches(_ c: CategorySummary) -> Bool {
        trimmed.isEmpty || c.name.localizedCaseInsensitiveContains(trimmed)
    }
    private var exactExists: Bool {
        model.categories.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }
    private func parentName(_ c: CategorySummary) -> String? {
        c.parentId.flatMap { pid in model.categories.first { $0.id == pid }?.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            List {
                if isSearching {
                    searchResults
                } else {
                    groupedTree
                }
                if isSearching && !exactExists {
                    createSection
                }
            }
            .statementBackground()
        }
        // Route keystrokes to the search field instead of the List's macOS
        // type-select (which otherwise eats them — looks like "autocomplete",
        // never filters). Focusing on appear makes the picker search-first.
        // `.onAppear` alone can fire before the sheet's window becomes key on
        // macOS (so the focus request is dropped); re-assert it after a beat.
        .onAppear { searchFocused = true }
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            searchFocused = true
        }
    }

    // MARK: Search bar
    //
    // An in-content field the picker owns, rather than `.searchable` (which on
    // macOS hoists into the NavigationStack toolbar and — when the List is nested
    // in a VStack under a header — silently fails to wire its text back to the
    // list, so typing filtered nothing).

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.slate)
            TextField("Search or create a category", text: $search)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .foregroundStyle(Brand.ink)
                .accessibilityIdentifier("categorySearch")
            if isSearching {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.slate)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Brand.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1) }
    }

    // MARK: Search results (flat, matching leaves across the whole tree)

    private var searchResults: some View {
        let leaves = model.categories.filter { !model.isGroup($0.id) && $0.id != "uncategorized" && matches($0) }
        return Section {
            if leaves.isEmpty {
                Text("No category matches “\(trimmed)”.").foregroundStyle(Brand.slate)
            } else {
                ForEach(leaves) { leaf in
                    leafRow(leaf, subtitle: parentName(leaf))
                }
            }
        } header: { Eyebrow("Matches") }
        .listRowBackground(Brand.surface)
    }

    // MARK: Always-expanded two-level tree

    private var groupedTree: some View {
        Group {
            ForEach(model.expenseGroups) { group in
                Section {
                    ForEach(model.children(of: group.id)) { leafRow($0, subtitle: nil) }
                } header: {
                    HStack(spacing: 6) {
                        CategoryDot(hex: group.color, size: 8)
                        Text(group.name.uppercased()).font(.system(.caption, design: .default).weight(.semibold))
                            .tracking(1.0).foregroundStyle(Brand.slate)
                    }
                }
                .listRowBackground(Brand.surface)
            }

            if !model.standaloneExpenseLeaves.isEmpty {
                Section {
                    ForEach(model.standaloneExpenseLeaves) { leafRow($0, subtitle: nil) }
                } header: { Eyebrow("Other") }
                .listRowBackground(Brand.surface)
            }

            Section {
                ForEach(model.systemCategories.filter { $0.id != "uncategorized" }) { leafRow($0, subtitle: nil) }
            } header: { Eyebrow("System") }
            .listRowBackground(Brand.surface)
        }
    }

    // MARK: Inline create

    private var createSection: some View {
        Section {
            Button { onCreate(trimmed, createGroup) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Brand.evergreen)
                    Text("Create “\(trimmed)”").foregroundStyle(Brand.ink)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button("Top level") { createGroup = nil }
                ForEach(model.expenseGroups) { g in
                    Button(g.name) { createGroup = g.id }
                }
            } label: {
                HStack {
                    Text("In group").foregroundStyle(Brand.slate)
                    Spacer()
                    Text(createGroup.flatMap { id in model.categories.first { $0.id == id }?.name } ?? "Top level")
                        .foregroundStyle(Brand.evergreen)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Brand.slate)
                }
            }
        } header: { Eyebrow("New category") }
        .listRowBackground(Brand.surface)
    }

    // MARK: Rows

    private func leafRow(_ leaf: CategorySummary, subtitle: String?) -> some View {
        Button { onPick(leaf.id) } label: {
            HStack(spacing: 8) {
                CategoryDot(hex: leaf.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(leaf.name).foregroundStyle(Brand.ink)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(Brand.slate) }
                }
                if leaf.id == suggestedCategoryId {
                    Label("Suggested", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.brass)
                }
                Spacer()
                if currentCategoryId == leaf.id {
                    Image(systemName: "checkmark").foregroundStyle(Brand.evergreen)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Stable id so UI tests can match a leaf regardless of the parent-group
        // subtitle that search-results mode adds to the visible label.
        .accessibilityIdentifier(leaf.name)
    }
}
