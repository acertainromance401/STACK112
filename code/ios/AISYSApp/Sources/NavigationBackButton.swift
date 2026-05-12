import SwiftUI

struct SmallBackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppColor.textPrimary)
                .frame(width: 32, height: 32)
                .background(AppColor.surface)
                .overlay(Circle().stroke(AppColor.border, lineWidth: 0.5))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("뒤로 가기")
    }
}

struct SmallBackButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SmallBackButton()
                }
            }
    }
}

extension View {
    func withSmallBackButton() -> some View {
        modifier(SmallBackButtonModifier())
    }
}