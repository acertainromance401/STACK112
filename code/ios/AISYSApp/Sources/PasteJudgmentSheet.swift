import SwiftUI
import UIKit

struct PasteJudgmentSheet: View {
    @Binding var pastedText: String
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    @FocusState private var editorFocused: Bool
    @State private var showGuide = true

    private var detected: DetectedSections {
        DetectedSections.detect(in: pastedText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                guideCard
                detectionBar

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

    @ViewBuilder
    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("어느 부분을 넣으면 좋을까요?", systemImage: "lightbulb.fill")
                    .font(.footnote.bold())
                    .foregroundStyle(.indigo)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showGuide.toggle() }
                } label: {
                    Image(systemName: showGuide ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if showGuide {
                VStack(alignment: .leading, spacing: 6) {
                    guideRow(rank: "최고", title: "판시사항 + 판결요지",
                             detail: "쟁점과 결론이 압축되어 있어 OX 정답 자동 추출까지 가능합니다.")
                    guideRow(rank: "유용", title: "참조조문 · 참조판례",
                             detail: "관련 법령·선례 연결에 사용됩니다.")
                    guideRow(rank: "보조", title: "이유 본문 일부",
                             detail: "논거 보강용. 일부 단락만 있어도 괜찮습니다.")
                    Text("전부 없어도 됩니다. 평문 30자 이상이면 본문 기반 분석으로 동작합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .background(Color.indigo.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func guideRow(rank: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(rank)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(rank == "최고" ? Color.indigo : (rank == "유용" ? Color.teal : Color.gray))
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold())
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detectionBar: some View {
        let d = detected
        if d.isEmpty {
            Text(pastedText.isEmpty
                 ? "여기에 붙여넣으면 자동으로 구조를 감지합니다."
                 : "구조 마커 미감지 — 본문 기반으로 분석됩니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("인식됨:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if d.hasIssues { chip("판시사항", .indigo) }
                    if d.hasHolding { chip("판결요지", .indigo) }
                    if d.hasStatutes { chip("참조조문", .teal) }
                    if d.hasPrecedents { chip("참조판례", .teal) }
                    if d.hasReasoning { chip("이유", .gray) }
                    if d.hasOpinionSplit { chip("다수/반대의견", .orange) }
                }
                .padding(.horizontal)
            }
        }
    }

    private func chip(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct DetectedSections {
    var hasIssues: Bool = false
    var hasHolding: Bool = false
    var hasStatutes: Bool = false
    var hasPrecedents: Bool = false
    var hasReasoning: Bool = false
    var hasOpinionSplit: Bool = false

    var isEmpty: Bool {
        !(hasIssues || hasHolding || hasStatutes || hasPrecedents || hasReasoning || hasOpinionSplit)
    }

    static func detect(in text: String) -> DetectedSections {
        guard !text.isEmpty else { return .init() }
        var d = DetectedSections()
        d.hasIssues       = text.contains("판시사항")
        d.hasHolding      = text.contains("판결요지") || text.contains("결정요지")
        d.hasStatutes     = text.contains("참조조문")
        d.hasPrecedents   = text.contains("참조판례")
        d.hasReasoning    = text.range(of: #"(^|\n)\s*【?\s*이\s*유\s*】?\s*($|\n)"#,
                                       options: .regularExpression) != nil
        d.hasOpinionSplit = text.contains("다수의견") || text.contains("반대의견")
                          || text.contains("보충의견") || text.contains("별개의견")
        return d
    }
}
