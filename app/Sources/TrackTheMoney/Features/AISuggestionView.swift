import SwiftUI
import TTMCore

/// Shared AI affordance for the category-setting dialogs: a loading row while the
/// on-device model runs, then a badged, one-tap-Approve banner with the suggested
/// category. Renders nothing when not loading and no suggestion.
struct AISuggestionView: View {
    @Bindable var model: AppModel
    let loading: Bool
    let suggestion: CategorySuggestion?
    let onApprove: (String) -> Void

    var body: some View {
        if loading {
            card {
                ProgressView().controlSize(.small)
                Text("Finding a category…").font(.subheadline).foregroundStyle(Brand.slate)
                Spacer()
            }
        } else if let s = suggestion {
            card {
                Image(systemName: "sparkles").foregroundStyle(Brand.brass)
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow("AI suggested")
                    HStack(spacing: 6) {
                        CategoryDot(hex: model.categoryColorHex(s.categoryId), size: 9)
                        Text(model.categoryName(s.categoryId))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
                    }
                }
                Spacer()
                Button { onApprove(s.categoryId) } label: {
                    Text("Approve").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Brand.evergreen).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10, content: content)
            .padding(12)
            .background(Brand.brass.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.brass.opacity(0.35), lineWidth: 1))
    }
}
