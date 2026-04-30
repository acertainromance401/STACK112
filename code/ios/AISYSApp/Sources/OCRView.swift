import SwiftUI
import PhotosUI
import Vision
import SwiftData

struct OCRView: View {
    @EnvironmentObject private var runtime: AppRuntimeState
    @Environment(\.modelContext) private var modelContext

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var recognizedText = ""
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
                                }
                            }
                        }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("사진 선택", systemImage: "photo")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRecognizing || isExtractingIR)

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
            .onChange(of: selectedPhoto) { newValue in
                guard let newValue else { return }
                Task { await recognize(item: newValue) }
            }
    }

    // MARK: - OCR

    private func recognize(item: PhotosPickerItem) async {
        isRecognizing = true
        ocrError = nil
        recognizedText = ""
        defer { isRecognizing = false }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            ocrError = "이미지를 불러오지 못했습니다."
            return
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ko-KR"]

        let handler = VNImageRequestHandler(data: data)
        do {
            try handler.perform([request])
            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            recognizedText = lines.joined(separator: "\n")
            if recognizedText.isEmpty {
                ocrError = "인식된 텍스트가 없습니다. 다른 사진으로 시도해 주세요."
            }
        } catch {
            ocrError = "OCR 처리 중 오류가 발생했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - IR 추출 → 임시 APICase 생성 → 암기수첩 이동

    private func processOCRText() async {
        isExtractingIR = true
        ocrError = nil
        defer { isExtractingIR = false }

        // 백엔드 /ir/extract 호출 (실패 시 로컬 폴백)
        var keywords: [String] = []
        var keySentences = ""

        do {
            let result = try await NetworkService.shared.irExtract(text: recognizedText)
            keywords = result.keywords
            keySentences = result.keySentences
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
        }

        // OCR 텍스트로 임시 APICase 구성
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let ocrCase = APICase(
            id: "ocr-\(Int(now.timeIntervalSince1970))",
            caseNumber: "OCR 스캔 판례",
            caseName: String(recognizedText.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines),
            courtName: "스캔 문서",
            subject: keywords.prefix(3).joined(separator: " · "),
            issueSummary: keySentences,
            holdingSummary: nil,
            examPoints: keywords.prefix(5).joined(separator: ", "),
            sourceUrl: nil
        )

        // ViewModel IR 결과 주입 (재생성 없이 기존 인스턴스 재사용)
        summaryViewModel.injectIRResult(keywords: keywords, keySentences: keySentences)

        // SwiftData에 영구 저장
        let record = ScannedCase(
            ocrRawText: recognizedText,
            keywords: keywords,
            keySentences: keySentences,
            caseName: String(recognizedText.prefix(40))
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
}
