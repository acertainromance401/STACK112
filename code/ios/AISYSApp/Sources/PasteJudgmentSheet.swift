import SwiftUI
import UIKit

struct PasteJudgmentSheet: View {
    @Binding var pastedText: String
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("대법원·각급 법원 판결 전문을 붙여넣어 주세요. 【판시사항】 【판결요지】 【참조조문】 【참조판례】 【전 문】 같은 구조가 포함될수록 분석 정확도가 올라갑니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                TextEditor(text: $pastedText)
                    .focused($editorFocused)
                    .font(.callout)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                HStack {
                    Text("\(pastedText.count)자")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if let s = UIPasteboard.general.string {
                            pastedText = s
                        }
                    } label: {
                        Label("클립보드에서 가져오기", systemImage: "doc.on.clipboard.fill")
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            .navigationTitle("판례 텍스트 붙여넣기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("분석 시작") {
                        let trimmed = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.count >= 30 else { return }
                        onConfirm(trimmed)
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).count < 30)
                }
            }
            .onAppear { editorFocused = true }
        }
    }
}
