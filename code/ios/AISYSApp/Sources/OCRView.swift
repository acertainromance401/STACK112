import SwiftUI
import PhotosUI
import Vision
import SwiftData

struct OCRView: View {
    @EnvironmentObject private var runtime: AppRuntimeState
    @Environment(\.modelContext) private var modelContext

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var recognizedText = ""
    @State private var selectedPhotoCount = 0
    @State private var caseIdentifierInput = ""
    @State private var isRecognizing = false
    @State private var isExtractingIR = false
    @State private var ocrError: String?
    @State private var navigateToSummary = false
    @StateObject private var summaryViewModel = CaseSummaryViewModel()

    var body: some View {
        ScrollView {
                VStack(spacing: 20) {
                    Text("문제 스캔")
                        .font(.largeTitle.bold())
                    Text("판례 이미지를 선택하면 OCR → IR 분석 → 암기 수첩·OX 퀴즈 화면으로 이동합니다.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.blue.opacity(0.1))
                        .frame(height: 220)
                        .overlay {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.text.viewfinder")
                                    .font(.system(size: 46))
                                    .foregroundStyle(.blue)
                                if isRecognizing {
                                    ProgressView()
                                    Text("OCR 분석 중...").foregroundStyle(.secondary)
                                } else if isExtractingIR {
                                    ProgressView()
                                    Text("키워드 추출 중...").foregroundStyle(.secondary)
                                } else {
                                    Text("사진을 선택해 OCR 시작")
                                        .foregroundStyle(.secondary)
                                    if selectedPhotoCount > 0 {
                                        Text("선택된 이미지: \(selectedPhotoCount)장")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 20, matching: .images) {
                        Label("사진 여러 장 선택", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRecognizing || isExtractingIR)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("판례 이름/번호")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField("예: 2024다311181 또는 사건명", text: $caseIdentifierInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isRecognizing || isExtractingIR)
                        Text("입력하면 OCR 저장 시 우선 사용됩니다. 비워두면 자동 번호(OCR-시간)로 저장됩니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let ocrError {
                        Text(ocrError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if !recognizedText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("인식 결과 (\(recognizedText.count)자)")
                                .font(.headline)
                            Text(recognizedText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button {
                            Task { await processOCRText() }
                        } label: {
                            Label("판례 분석 시작", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(isExtractingIR)
                    }
                }
                .padding()
            }
            .navigationTitle("OCR")
            .withSmallBackButton()
            .navigationDestination(isPresented: $navigateToSummary) {
                if let ocrCase = runtime.pendingOCRCase {
                    CaseSummaryView(apiCase: ocrCase, viewModel: summaryViewModel)
                }
            }
            .onChange(of: selectedPhotos) { newValue in
                guard !newValue.isEmpty else { return }
                Task { await recognize(items: newValue) }
            }
    }

    // MARK: - OCR

    @MainActor
    private func recognize(items: [PhotosPickerItem]) async {
        isRecognizing = true
        ocrError = nil
        recognizedText = ""
        selectedPhotoCount = items.count
        defer { isRecognizing = false }

        var mergedTexts: [String] = []
        mergedTexts.reserveCapacity(items.count)

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            if let text = try? await recognizeSingleImage(data: data), !text.isEmpty {
                mergedTexts.append(text)
            }
        }

        let merged = mergedTexts.joined(separator: "\n\n")
        if merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ocrError = "인식된 텍스트가 없습니다. 다른 사진으로 시도해 주세요."
            return
        }

        recognizedText = merged
    }

    private func recognizeSingleImage(data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) { () throws -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ko-KR"]

            let handler = VNImageRequestHandler(data: data)
            try handler.perform([request])
            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            if text.isEmpty {
                throw OCRRecognitionError.emptyText
            }
            return text
        }.value
    }

    private enum OCRRecognitionError: Error {
        case emptyText
    }

    // MARK: - IR 추출 → 임시 APICase 생성 → 암기수첩 이동

    @MainActor
    private func processOCRText() async {
        isExtractingIR = true
        ocrError = nil
        defer { isExtractingIR = false }

        // 백엔드 /ir/extract 호출 (실패 시 로컬 폴백)
        var keywords: [String] = []
        var keySentences = ""
        var domain = "general_legal"
        var studyFocus: [String] = []

        do {
            let result = try await NetworkService.shared.irExtract(text: recognizedText)
            keywords = result.keywords
            keySentences = result.keySentences
            if let d = result.domain, !d.isEmpty {
                domain = d
            }
            studyFocus = result.studyFocus ?? []
        } catch {
            // 백엔드 없을 때: OCR 텍스트 앞 500자를 keySentences로 사용
            // 폴백: 상태바·URL 등 잡음 라인을 제거하고 의미있는 문장만 추출
            let meaningfulLines = recognizedText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in
                    line.count > 10 &&
                    !line.contains("portal.scourt") &&
                    !line.contains("http") &&
                    !line.allSatisfy({ $0.isNumber || $0 == ":" })
                }
            keySentences = meaningfulLines.prefix(8).joined(separator: " ")
            keywords = extractLocalKeywords(from: recognizedText)
            studyFocus = [
                "핵심 쟁점-결론-시험포인트 순서로 1회 요약",
                "헷갈리는 문장은 OX로 바꿔 반복 확인"
            ]
        }

        // OCR 원문 잡음을 줄여 요약 카드와 OX 품질을 올립니다.
        keySentences = refineIRSentences(keySentences, sourceText: recognizedText)
        if keywords.isEmpty {
            keywords = extractLocalKeywords(from: keySentences.isEmpty ? recognizedText : keySentences)
        }

        let issueSummary = inferIssueSummary(from: keySentences, fallbackText: recognizedText)
        let holdingSummary = inferHoldingSummary(from: keySentences, fallbackText: recognizedText)

        // OCR 텍스트로 임시 APICase 구성
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let manualIdentifier = caseIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocrCaseNumber = manualIdentifier.isEmpty ? "OCR-\(formatter.string(from: now))" : manualIdentifier
        let ocrCase = APICase(
            id: "ocr-\(Int(now.timeIntervalSince1970))",
            caseNumber: ocrCaseNumber,
            caseName: ocrCaseNumber,
            courtName: "스캔 문서",
            subject: keywords.prefix(3).joined(separator: " · "),
            issueSummary: issueSummary,
            holdingSummary: holdingSummary,
            examPoints: keywords.prefix(5).joined(separator: ", "),
            sourceUrl: nil
        )

        // ViewModel IR 결과 주입 (재생성 없이 기존 인스턴스 재사용)
        summaryViewModel.injectIRResult(
            keywords: keywords,
            keySentences: keySentences,
            domain: domain,
            studyFocus: studyFocus
        )

        // SwiftData에 영구 저장
        let record = ScannedCase(
            ocrRawText: recognizedText,
            keywords: keywords,
            keySentences: keySentences,
            caseName: ocrCaseNumber
        )
        modelContext.insert(record)

        runtime.pendingOCRCase = ocrCase
        navigateToSummary = true
    }

    // MARK: - 로컬 폴백 키워드 추출 (백엔드 없을 때)

    private func extractLocalKeywords(from text: String) -> [String] {
        let stopwords: Set<String> = ["이", "가", "은", "는", "을", "를", "의", "에", "에서", "로", "으로", "와", "과", "도", "한", "하여", "하고", "있다", "없다", "것", "수", "바"]
        let words = text
            .components(separatedBy: .init(charactersIn: " \n\t.,()[]「」『』《》〈〉·:;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && !stopwords.contains($0) }

        var freq: [String: Int] = [:]
        for w in words { freq[w, default: 0] += 1 }
        return freq.sorted { $0.value > $1.value }.prefix(10).map(\.key)
    }

    private func refineIRSentences(_ keySentences: String, sourceText: String) -> String {
        let raw = keySentences.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sourceText : keySentences

        let parts = raw
            .components(separatedBy: CharacterSet(charactersIn: "\n。.!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { s in
                s.count >= 12 &&
                !s.contains("portal.scourt") &&
                !s.contains("http") &&
                !s.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "-" })
            }

        var seen: Set<String> = []
        var cleaned: [String] = []

        for part in parts {
            let normalized = part
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"제\s*\d+\s*조(?:\s*제\s*\d+\s*항)?(?:\s*제\s*\d+\s*호)?"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard normalized.count >= 10, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            cleaned.append(normalized)
            if cleaned.count >= 4 { break }
        }

        return cleaned.joined(separator: ". ")
    }

    private func inferIssueSummary(from keySentences: String, fallbackText: String) -> String {
        let source = keySentences.isEmpty ? fallbackText : keySentences
        let candidate = source
            .components(separatedBy: CharacterSet(charactersIn: "\n。.!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.count >= 10 })
        return String((candidate ?? "쟁점 정보 확인 필요").prefix(120))
    }

    private func inferHoldingSummary(from keySentences: String, fallbackText: String) -> String {
        let source = keySentences.isEmpty ? fallbackText : keySentences
        let candidates = source
            .components(separatedBy: CharacterSet(charactersIn: "\n。.!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 10 }

        let verdictHints = ["유죄", "무죄", "기각", "인용", "위반", "해당", "불인정", "인정", "판단"]
        if let picked = candidates.first(where: { line in
            verdictHints.contains(where: { line.contains($0) })
        }) {
            return String(picked.prefix(120))
        }

        return String((candidates.first ?? "결론 정보 확인 필요").prefix(120))
    }
}
