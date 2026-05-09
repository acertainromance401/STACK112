import Foundation

// MARK: - CaseSummaryViewModel
//
// 흐름:
//   1. SearchView에서 search(query:) 호출
//   2. NetworkService로 백엔드 /search API 호출 → APICase 목록 획득
//   3. 사용자가 결과 선택 → select(caseItem:) 호출
//   4. LLMService.summarize()로 온디바이스 Llama 추론
//   5. 결과를 CaseDetail로 변환해 SearchFlowViews에 표시

@MainActor
final class CaseSummaryViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var searchResults: [APICase] = []
    @Published private(set) var selectedCase: APICase?
    @Published private(set) var summary: LLMSummary?
    @Published private(set) var quizQuestion: QuizQuestion?
    @Published private(set) var oxQuizItems: [OXQuizQuestion] = []
    @Published private(set) var similarCases: [APICase] = []

    @Published private(set) var isSearching = false
    @Published private(set) var isSummarizing = false
    @Published private(set) var isGeneratingQuiz = false
    @Published private(set) var isGeneratingOXQuiz = false
    @Published private(set) var isLoadingSimilarCases = false
    @Published private(set) var llmState: LLMState = .idle
    @Published private(set) var activeEngineName: String = "준비 전"
    @Published private(set) var isUsingFallbackEngine = true
    @Published private(set) var llmLoadMessage: String?
    @Published private(set) var selectedModelSource: String?
    @Published private(set) var selectedModelPath: String?
    @Published private(set) var bundleModelPath: String?
    @Published private(set) var documentsModelPath: String?
    @Published private(set) var modelSelectionReason: String?
    @Published private(set) var ignoreDocumentsModel = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var backendConnected = false
    @Published private(set) var hasAttemptedBackendSearch = false

    // IR 파이프라인 결과 (백엔드 /ir/extract 응답 캐시)
    private(set) var irKeywords: [String] = []
    private(set) var irKeySentences: String = ""
    @Published private(set) var irDomain: String = "general_legal"
    @Published private(set) var irStudyFocus: [String] = []

    // MARK: - Dependencies

    private let network: NetworkService
    private let llm: LLMService

    init(network: NetworkService, llm: LLMService) {
        self.network = network
        self.llm = llm

        // LLMService 상태를 미러링
        Task { [weak self] in
            guard let self else { return }
            for await state in llm.$state.values {
                self.llmState = state
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await name in llm.$activeEngineName.values {
                self.activeEngineName = name
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await useFallback in llm.$isUsingFallbackEngine.values {
                self.isUsingFallbackEngine = useFallback
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await message in llm.$lastLoadMessage.values {
                self.llmLoadMessage = message
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in llm.$selectedModelSource.values {
                self.selectedModelSource = value
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in llm.$selectedModelPath.values {
                self.selectedModelPath = value
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in llm.$bundleModelPath.values {
                self.bundleModelPath = value
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in llm.$documentsModelPath.values {
                self.documentsModelPath = value
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in llm.$modelSelectionReason.values {
                self.modelSelectionReason = value
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in llm.$ignoreDocumentsModel.values {
                self.ignoreDocumentsModel = value
            }
        }
    }

    convenience init() {
        self.init(network: .shared, llm: .shared)
    }

    /// OCRView에서 미리 추출한 IR 결과를 주입합니다 (DB 없이 테스트할 때 사용).
    func injectIRResult(
        keywords: [String],
        keySentences: String,
        domain: String? = nil,
        studyFocus: [String] = []
    ) {
        irKeywords = keywords
        irKeySentences = keySentences
        irDomain = (domain?.isEmpty == false) ? domain! : "general_legal"
        irStudyFocus = studyFocus
    }

    func setIgnoreDocumentsModel(_ ignore: Bool) async {
        await llm.setIgnoreDocumentsModel(ignore)
    }

    /// 경찰시험 분류 트리로 텍스트 분류 ("형법 > 재산범죄 > 절도" 형태 반환).
    /// LLM 미준비/실패 시 빈 문자열 또는 부분 경로.
    func classifyByTaxonomy(text: String) async -> String {
        await llm.classifyByTaxonomy(text: text)
    }

    // MARK: - Search

    /// 키워드/사건번호로 백엔드 검색
    func search(query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        hasAttemptedBackendSearch = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            searchResults = try await network.searchCases(query: query)
            backendConnected = true
        } catch {
            backendConnected = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Select + Summarize

    /// 검색 결과에서 판례를 선택하고 LLM 요약 시작
    func select(caseItem: APICase) async {
        selectedCase = caseItem
        summary = nil
        quizQuestion = nil
        oxQuizItems = []
        similarCases = []

        // OCR 경로에서 미리 주입된 IR 결과가 있다면 화면 진입 시 초기화하지 않습니다.
        let hasInjectedIR = !irKeywords.isEmpty || !irKeySentences.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !irStudyFocus.isEmpty
        let shouldPreserveInjectedIR = caseItem.caseNumber.hasPrefix("OCR-") && hasInjectedIR
        if !shouldPreserveInjectedIR {
            irKeywords = []
            irKeySentences = ""
            irDomain = "general_legal"
            irStudyFocus = []
        }

        // IR 추출과 LLM 요약을 병렬로 시작
        async let irTask: Void = fetchIRExtract(caseItem: caseItem)
        async let similarTask: Void = fetchSimilarCases(caseItem: caseItem)
        // 화면 진입 직후 가장 먼저 모델 준비 상태를 보장합니다.
        // 여기서 ready가 되면 아래 performSummarize가 실제 프롬프트 생성으로 이어집니다.
        guard await ensureModelReady() else {
            _ = await irTask
            _ = await similarTask
            return
        }
        await performSummarize(caseItem: caseItem)
        _ = await irTask
        _ = await similarTask
    }

    func generateQuizForSelectedCase() async {
        guard let caseItem = selectedCase else { return }
        errorMessage = nil
        quizQuestion = nil
        guard await ensureModelReady() else { return }
        await performQuizGeneration(caseItem: caseItem)
    }

    /// IR 처리 결과(keySentences, keywords) 기반 OX 퀴즈 생성
    func generateOXQuizForSelectedCase() async {
        guard let caseItem = selectedCase else { return }
        errorMessage = nil
        oxQuizItems = []
        guard await ensureModelReady() else { return }
        isGeneratingOXQuiz = true
        defer { isGeneratingOXQuiz = false }
        do {
            oxQuizItems = try await llm.generateOXQuiz(
                caseItem: caseItem,
                keySentences: irKeySentences,
                keywords: irKeywords
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Computed Display Values

    var displayDetail: CaseDetail? {
        guard let c = selectedCase else { return nil }
        return c.toCaseDetail(llmSummary: summary)
    }

    var searchResultItems: [SearchResultItem] {
        searchResults.map { $0.toSearchResultItem() }
    }

    // MARK: - Private

    private func ensureModelReady() async -> Bool {
        // idle/error 상태면 llama 엔진 로드 또는 fallback 전환을 다시 시도합니다.
        switch llm.state {
        case .idle, .error:
            await llm.load()
        default:
            break
        }

        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            switch llm.state {
            case .ready:
                return true
            case .idle, .error:
                await llm.load()
            case .loading, .inferring:
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        errorMessage = "LLM 초기화가 지연되고 있습니다. 잠시 후 다시 시도해주세요."
        return false
    }

    private func performSummarize(caseItem: APICase) async {
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            summary = try await llm.summarize(caseItem: caseItem)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performQuizGeneration(caseItem: APICase) async {
        isGeneratingQuiz = true
        defer { isGeneratingQuiz = false }
        do {
            quizQuestion = try await llm.generateQuiz(caseItem: caseItem, summary: summary)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 백엔드 /ir/extract 호출 — 실패해도 UX 차단 없이 폴백(빈 값)으로 진행
    private func fetchIRExtract(caseItem: APICase) async {
        // OCR 임시 케이스는 OCRView에서 이미 IR을 주입한 값을 우선 신뢰합니다.
        if caseItem.caseNumber.hasPrefix("OCR-") {
            let hasInjectedIR = !irKeywords.isEmpty || !irKeySentences.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasInjectedIR {
                return
            }
        }

        let combinedText = [
            caseItem.issueSummary,
            caseItem.holdingSummary,
            caseItem.examPoints,
        ].compactMap { $0 }.joined(separator: " ")

        guard !combinedText.isEmpty else { return }

        do {
            let result = try await network.irExtract(text: combinedText)
            irKeywords = result.keywords
            irKeySentences = result.keySentences
            irDomain = (result.domain?.isEmpty == false) ? result.domain! : "general_legal"
            irStudyFocus = result.studyFocus ?? []
        } catch {
            // IR 추출 실패 시 DB 데이터를 폴백으로 사용 (LLM은 계속 동작)
            irKeywords = caseItem.subject.isEmpty ? [] : [caseItem.subject]
            irKeySentences = caseItem.issueSummary ?? ""
            irDomain = "general_legal"
            irStudyFocus = [
                "핵심 쟁점-결론-시험포인트 순서로 1회 요약",
                "헷갈리는 문장은 OX로 바꿔 반복 확인",
            ]
        }
    }

    /// 백엔드 /cases/{case_number}/similar 호출
    private func fetchSimilarCases(caseItem: APICase) async {
        // OCR 임시 케이스는 유사 판례 API 대상이 아님
        guard !caseItem.caseNumber.hasPrefix("OCR-") else {
            similarCases = []
            return
        }

        isLoadingSimilarCases = true
        defer { isLoadingSimilarCases = false }

        do {
            similarCases = try await network.listSimilarCases(caseNumber: caseItem.caseNumber, topK: 5)
        } catch {
            // 유사 판례 로딩 실패는 상세 요약 UX를 막지 않음
            similarCases = []
        }
    }
}
