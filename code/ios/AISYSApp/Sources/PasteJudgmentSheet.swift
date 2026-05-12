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
                    guideRow(rank: "필수", title: "판시사항 + 판결요지(다수의견)",
                             detail: "핵심 쟁점과 결론 카드를 둘 다 채우려면 두 단락 모두 필요합니다. 하나만 넣으면 그 카드만 채워집니다.")
                    guideRow(rank: "권장", title: "참조조문 · 참조판례",
                             detail: "도메인(형법/민사/행정 등) 분류와 관련 선례 연결 정확도가 크게 올라갑니다.")
                    guideRow(rank: "선택", title: "이유 본문 일부",
                             detail: "논거 보강용. 시간이 없으면 생략해도 됩니다.")
                    Text("⚠ 판시사항만 넣으면 결론 카드는 ‘판결요지를 함께 넣어주세요’ 안내로 표시됩니다. portal.scourt.go.kr 탭을 위→아래로 끝까지 스크롤한 뒤 통째로 복사하시면 가장 정확합니다.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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
                .background(rank == "필수" ? Color.red : (rank == "권장" ? Color.indigo : Color.gray))
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
            // 분석 품질에 결정적인 누락 경고 — 사용자가 어떤 데이터를 더 넣어야 하는지 즉시 알 수 있게 한다.
            if d.hasIssues && !d.hasHolding {
                Label("판결요지(다수의견)가 감지되지 않았습니다. 결론 카드가 부정확할 수 있어요. portal.scourt.go.kr에서 【판결요지】 단락까지 함께 복사해 주세요.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            } else if !d.hasIssues && d.hasHolding {
                Label("판시사항이 감지되지 않았습니다. 핵심 쟁점 카드가 누락될 수 있어요. 【판시사항】 단락도 함께 붙여넣어 주세요.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
            if d.hasIssues && d.hasHolding && !d.hasStatutes {
                Label("참조조문이 없어 도메인 분류 정확도가 낮을 수 있습니다.",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
