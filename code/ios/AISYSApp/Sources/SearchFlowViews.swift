import SwiftUI
import SwiftData

struct SearchView: View {
    @EnvironmentObject private var store: ReviewStore
    @EnvironmentObject private var runtime: AppRuntimeState
    @StateObject private var viewModel = CaseSummaryViewModel()
    @State private var keyword = ""
    @State private var showAllScannedCases = false
    @State private var apiConnectionHint: String?

    private let defaultScannedCaseLimit = 20

    @Query(sort: \ScannedCase.scannedAt, order: .reverse)
    private var scannedCases: [ScannedCase]

    private var visibleScannedCases: [ScannedCase] {
        if showAllScannedCases {
            return scannedCases
        }
        return Array(scannedCases.prefix(defaultScannedCaseLimit))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("판례 통합 검색")
                    .font(.largeTitle.bold())
                Text("키워드, 사건번호 또는 문서 스캔으로 정밀한 판례 정보를 찾으세요.")
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("키워드 검색", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await viewModel.search(query: keyword) } }
                    Button {
                        Task { await viewModel.search(query: keyword) }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isSearching || keyword.isEmpty)
                }

                if let apiConnectionHint {
                    Text(apiConnectionHint)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("추천 키워드")
                    .font(.headline)
                HStack {
                    ForEach(["영장주의", "자백배제법칙", "위법수집증거"], id: \.self) { kw in
                        Button { keyword = kw; Task { await viewModel.search(query: kw) } }
                        label: { TagView(text: kw) }
                        .buttonStyle(.plain)
                    }
                }

                Text("검색 결과")
                    .font(.title3.bold())

                if viewModel.hasAttemptedBackendSearch && !viewModel.backendConnected {
                    Text("백엔드(DB) 연결이 없어 검색 결과를 불러오지 못했습니다.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if viewModel.isSearching {
                    ProgressView("검색 중...").frame(maxWidth: .infinity)
                } else if let err = viewModel.errorMessage {
                    Text(err).foregroundStyle(.red).font(.subheadline)
                } else if viewModel.searchResults.isEmpty && !keyword.isEmpty {
                    Text("검색 결과가 없습니다. 다른 키워드로 시도해보세요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if !viewModel.searchResults.isEmpty {
                    // List + .lazy로 렌더링 성능 개선 (화면 에 보이는 항목만 렌더링)
                    VStack(spacing: 10) {
                        ForEach(viewModel.searchResults) { apiCase in
                            NavigationLink {
                                LazyView(CaseSummaryView(apiCase: apiCase, viewModel: viewModel, shouldAutoSave: true))
                            } label: {
                                SearchResultCard(
                                    title: apiCase.caseName,
                                    subtitle: "\(apiCase.courtName)  \(apiCase.caseNumber)",
                                    tags: apiCase.subject.isEmpty ? [] : ["#\(apiCase.subject)"],
                                    summary: apiCase.issueSummary ?? ""
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("표시할 판례가 없습니다. 백엔드 연결 또는 키워드를 확인해주세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // ── 로컬 스캔 판례 섹션 ────────────────────────────
                if !scannedCases.isEmpty {
                    Divider().padding(.vertical, 4)

                    Text("내가 스캔한 판례")
                        .font(.title3.bold())
                    Text("저장된 \(scannedCases.count)건")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        ForEach(visibleScannedCases) { scanned in
                            NavigationLink {
                                LazyView(buildScannedCaseSummaryView(scanned))
                            } label: {
                                SearchResultCard(
                                    title: scanned.caseName,
                                    subtitle: "스캔 \(DateFormatter.shortDate.string(from: scanned.scannedAt))",
                                    tags: scanned.keywords.prefix(3).map { "#\($0)" },
                                    summary: String(scanned.keySentences.prefix(140))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if scannedCases.count > defaultScannedCaseLimit {
                        Button(showAllScannedCases ? "접기" : "더보기") {
                            showAllScannedCases.toggle()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Search")
        .onChange(of: runtime.pendingSearchQuery) { newValue in
            guard let query = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return
            }
            keyword = query
            runtime.pendingSearchQuery = nil
            Task { await viewModel.search(query: query) }
        }
        .task(priority: .utility) {
            apiConnectionHint = await NetworkService.shared.deviceConnectionHint()
            LocalCaseStore.shared.updateScanned(
                searchable: scannedCases.map { $0.toSearchableAPICase() },
                display: scannedCases.map { $0.toAPICase() }
            )
            // 약점 카드 등에서 탭 전환과 함께 pendingSearchQuery 가 미리 설정된 경우 즉시 트리거
            if let pending = runtime.pendingSearchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !pending.isEmpty {
                keyword = pending
                runtime.pendingSearchQuery = nil
                await viewModel.search(query: pending)
            }
        }
        .onChange(of: scannedCases.count) { _ in
            LocalCaseStore.shared.updateScanned(
                searchable: scannedCases.map { $0.toSearchableAPICase() },
                display: scannedCases.map { $0.toAPICase() }
            )
        }
    }

    private func buildScannedCaseSummaryView(_ scanned: ScannedCase) -> CaseSummaryView {
        let vm = CaseSummaryViewModel()
        vm.injectIRResult(
            keywords: scanned.keywords,
            keySentences: scanned.keySentences
        )
        return CaseSummaryView(
            apiCase: scanned.toAPICase(),
            viewModel: vm
        )
    }
}

private struct LazyView<Content: View>: View {
    private let build: () -> Content

    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }

    var body: some View {
        build()
    }
}

struct CaseSummaryView: View {
    // 실제 API 데이터 경로
    var apiCase: APICase? = nil
    @ObservedObject var viewModel: CaseSummaryViewModel = CaseSummaryViewModel()
    // 더미 데이터 폴백 경로
    var detail: CaseDetail? = nil
    /// true 이면 화면 진입 시 ReviewStore 에 자동 저장
    var shouldAutoSave: Bool = false
    @EnvironmentObject private var store: ReviewStore

    /// 카드별 사용자 메모를 영속 저장하기 위한 키 (사건번호 + 섹션 식별자)
    fileprivate func memoKey(_ detail: CaseDetail, _ section: String) -> String {
        let identifier = apiCase?.caseNumber ?? detail.title
        return "case_memo::\(identifier)::\(section)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                if let resolved = viewModel.displayDetail ?? detail {

                    // ── 제목 ──────────────────────────────────────
                    Text(resolved.title)
                        .font(AppFont.title)
                        .foregroundStyle(AppColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    // ── 엔진 정보 패널 (사용자 노출 X. 내부 진단용 — SHOW_LLM_DEBUG_PANEL 컴파일 플래그가 설정되면 표시) ──────────────
                    #if SHOW_LLM_DEBUG_PANEL
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(
                                "Documents 모델 무시",
                                isOn: Binding(
                                    get: { viewModel.ignoreDocumentsModel },
                                    set: { newValue in
                                        Task { await viewModel.setIgnoreDocumentsModel(newValue) }
                                    }
                                )
                            )
                            .font(AppFont.caption)
                            .tint(AppColor.accent)

                            if let source = viewModel.selectedModelSource, !source.isEmpty {
                                Text("선택 소스: \(source)")
                                    .font(AppFont.tag)
                                    .foregroundStyle(AppColor.textTertiary)
                            }
                            if let reason = viewModel.modelSelectionReason, !reason.isEmpty {
                                Text("선택 기준: \(reason)")
                                    .font(AppFont.tag)
                                    .foregroundStyle(AppColor.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let message = viewModel.llmLoadMessage, !message.isEmpty {
                                Text(message)
                                    .font(AppFont.tag)
                                    .foregroundStyle(AppColor.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let selectedPath = viewModel.selectedModelPath, !selectedPath.isEmpty {
                                Text("사용 경로: \(selectedPath)")
                                    .font(AppFont.tag)
                                    .foregroundStyle(AppColor.textTertiary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let bundlePath = viewModel.bundleModelPath, !bundlePath.isEmpty {
                                Text("Bundle: \(bundlePath)")
                                    .font(AppFont.tag)
                                    .foregroundStyle(AppColor.textTertiary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let documentsPath = viewModel.documentsModelPath, !documentsPath.isEmpty {
                                Text("Documents: \(documentsPath)")
                                    .font(AppFont.tag)
                                    .foregroundStyle(AppColor.textTertiary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: viewModel.isUsingFallbackEngine ? "exclamationmark.triangle.fill" : "cpu.fill")
                                .font(.caption)
                            Text(viewModel.isUsingFallbackEngine
                                 ? "LLM: \(viewModel.activeEngineName) (fallback)"
                                 : "LLM: \(viewModel.activeEngineName)")
                                .font(AppFont.tag)
                        }
                        .foregroundStyle(viewModel.isUsingFallbackEngine ? AppColor.warning : AppColor.success)
                    }
                    .tint(AppColor.textSecondary)
                    .padding(AppSpace.m)
                    .background(AppColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
                    #endif

                    // ── LLM 추론 상태 ──────────────────────────────
                    if viewModel.isSummarizing {
                        HStack(spacing: 8) {
                            ProgressView().tint(AppColor.accent)
                            Text("판례를 분석하는 중...")
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textSecondary)
                        }
                    }

                    // ── 암기 수첩 카드 ──────────────────────────────
                    StudyNoteCard(
                        label: "판례 요약",
                        content: displaySummaryText(resolved: resolved),
                        accentColor: AppColor.accent,
                        memoStorageKey: memoKey(resolved, "summary")
                    )
                    StudyNoteCard(
                        label: "핵심 쟁점",
                        content: displayIssueText(resolved: resolved),
                        accentColor: AppColor.warning,
                        memoStorageKey: memoKey(resolved, "issue")
                    )
                    StudyNoteCard(
                        label: "판결 결론",
                        content: displayRulingText(resolved: resolved),
                        accentColor: AppColor.success,
                        memoStorageKey: memoKey(resolved, "ruling")
                    )
                    StudyNoteCard(
                        label: "시험 포인트",
                        content: displayExamText(resolved: resolved),
                        accentColor: AppColor.info,
                        memoStorageKey: memoKey(resolved, "exam")
                    )

                    // IR 키워드 태그
                    if !viewModel.irKeywords.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("추출 키워드")
                                .font(AppFont.tag)
                                .foregroundStyle(AppColor.textSecondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(viewModel.irKeywords, id: \.self) { kw in
                                        TagView(text: kw)
                                    }
                                }
                            }
                        }
                    }

                    if !viewModel.irStudyFocus.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("학습 가이드")
                                .font(AppFont.tag)
                                .foregroundStyle(AppColor.textSecondary)
                            HStack(spacing: 6) {
                                Image(systemName: localizedDomainIcon)
                                    .font(.caption)
                                    .foregroundStyle(localizedDomainAccent)
                                Text(localizedDomainLabel)
                                    .font(AppFont.tag)
                                    .foregroundStyle(localizedDomainAccent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(localizedDomainAccent.opacity(0.18))
                                    .clipShape(Capsule())
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(viewModel.irStudyFocus.enumerated()), id: \.offset) { idx, item in
                                    Text("\(idx + 1). \(item)")
                                        .font(AppFont.body)
                                        .foregroundStyle(AppColor.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            Button {
                                Task { await viewModel.generateOXQuizForSelectedCase() }
                            } label: {
                                Label("이 가이드로 OX 생성", systemImage: "bolt.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(AppColor.accent)
                            .disabled(viewModel.isSummarizing || viewModel.isGeneratingOXQuiz)
                        }
                        .padding(AppSpace.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
                    }

                    if let err = viewModel.errorMessage {
                        Text(err)
                            .foregroundStyle(AppColor.danger)
                            .font(AppFont.caption)
                    }

                    Divider().background(AppColor.separator)

                    // ── OX 퀴즈 버튼 ───────────────────────────────
                    if viewModel.isGeneratingOXQuiz {
                        HStack(spacing: 8) {
                            ProgressView().tint(AppColor.accent)
                            Text("OX 퀴즈를 생성하는 중...")
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textSecondary)
                        }
                    } else {
                        Button {
                            Task { await viewModel.generateOXQuizForSelectedCase() }
                        } label: {
                            Label(
                                viewModel.oxQuizItems.isEmpty ? "OX 퀴즈 생성" : "OX 퀴즈 다시 생성",
                                systemImage: "checkmark.circle"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColor.accent)
                        .foregroundStyle(AppColor.background)
                        .disabled(viewModel.isSummarizing)
                    }

                    if !viewModel.oxQuizItems.isEmpty {
                        NavigationLink {
                            let caseNumber = apiCase?.caseNumber ?? resolved.title
                            let caseSummary = "쟁점: \(displayIssueText(resolved: resolved))\n결론: \(displayRulingText(resolved: resolved))\n시험포인트: \(displayExamText(resolved: resolved))"
                            OXQuizView(
                                caseNumber: caseNumber,
                                caseTitle: resolved.title,
                                caseSubject: apiCase?.subject,
                                caseSummary: caseSummary,
                                items: viewModel.oxQuizItems
                            )
                        } label: {
                            Label("OX 퀴즈 풀기 (\(viewModel.oxQuizItems.count)문항)", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(AppColor.accent)
                    }

                    Divider().background(AppColor.separator)

                    // 유사 판례
                    VStack(alignment: .leading, spacing: 10) {
                        Text("유사 판례")
                            .font(AppFont.sectionHeader)
                            .foregroundStyle(AppColor.textPrimary)

                        if viewModel.isLoadingSimilarCases {
                            HStack(spacing: 8) {
                                ProgressView().tint(AppColor.accent)
                                Text("유사 판례를 찾는 중...")
                                    .font(AppFont.body)
                                    .foregroundStyle(AppColor.textSecondary)
                            }
                        } else if viewModel.similarCases.isEmpty {
                            Text("유사 판례를 찾지 못했습니다.")
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textSecondary)
                        } else {
                            ForEach(viewModel.similarCases) { similar in
                                NavigationLink {
                                    CaseSummaryView(apiCase: similar, shouldAutoSave: true)
                                } label: {
                                    SearchResultCard(
                                        title: similar.caseNumber,
                                        subtitle: similar.caseName,
                                        tags: similar.subject.isEmpty ? [] : ["#\(similar.subject)"],
                                        summary: similar.issueSummary ?? ""
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(AppSpace.l)
        }
        .withAppBackground()
        .navigationTitle("판례 요약")
        .navigationBarTitleDisplayMode(.inline)
        .withSmallBackButton()
        .task {
            if let c = apiCase {
                await viewModel.select(caseItem: c)
                if shouldAutoSave { store.saveCase(c) }
            }
        }
    }

    private var localizedDomainLabel: String {
        switch viewModel.irDomain {
        case "criminal_law":
            return "형법"
        case "criminal_procedure_evidence":
            return "형소-증거"
        case "criminal_procedure_investigation":
            return "형소-수사"
        case "constitutional_law":
            return "헌법"
        case "administrative_law":
            return "행정-조세"
        case "police_committees":
            return "경찰학-위원회"
        default:
            return "일반"
        }
    }

    private var localizedDomainIcon: String {
        switch viewModel.irDomain {
        case "criminal_law":
            return "building.columns"
        case "criminal_procedure_evidence":
            return "doc.text.magnifyingglass"
        case "criminal_procedure_investigation":
            return "person.text.rectangle"
        case "constitutional_law":
            return "scale.3d"
        case "administrative_law":
            return "building.columns.circle"
        case "police_committees":
            return "person.3"
        default:
            return "book"
        }
    }

    private var localizedDomainAccent: Color {
        switch viewModel.irDomain {
        case "criminal_law":
            return AppColor.warning
        case "criminal_procedure_evidence":
            return AppColor.success
        case "criminal_procedure_investigation":
            return AppColor.info
        case "constitutional_law":
            return AppColor.danger
        case "administrative_law":
            return AppColor.info
        case "police_committees":
            return AppColor.accent
        default:
            return AppColor.textSecondary
        }
    }

    private func displaySummaryText(resolved: CaseDetail) -> String {
        let issue = displayIssueText(resolved: resolved)
        let ruling = displayRulingText(resolved: resolved)
        let domainLabel = apiCase?.subject.components(separatedBy: "·").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts: [String] = []
        if !domainLabel.isEmpty && domainLabel.count <= 8 {
            parts.append("[\(domainLabel)]")
        }
        parts.append(resolved.title.hasSuffix("사건") ? "\(resolved.title)." : "\(resolved.title) 사건.")
        if !issue.isEmpty && !issue.contains("복원하지 못했습니다") {
            parts.append("쟁점: \(issue)")
        }
        if !ruling.isEmpty && !ruling.contains("복원하지 못했습니다") {
            parts.append("결론: \(ruling)")
        }
        return parts.joined(separator: " ")
    }

    private func displayIssueText(resolved: CaseDetail) -> String {
        let base = apiCase?.issueSummary ?? resolved.issue
        let normalized = normalizeCardText(base, role: .issue)
        return normalized.isEmpty ? "핵심 쟁점 문장을 완전하게 복원하지 못했습니다." : normalized
    }

    private func displayRulingText(resolved: CaseDetail) -> String {
        let base = apiCase?.holdingSummary ?? resolved.conclusion
        let normalized = normalizeCardText(base, role: .ruling)
        return normalized.isEmpty ? "판결 결론 문장을 완전하게 복원하지 못했습니다." : normalized
    }

    private func displayExamText(resolved: CaseDetail) -> String {
        let base = apiCase?.examPoints ?? resolved.examPoint
        let normalized = normalizeCardText(base, role: .exam)
        return normalized.isEmpty ? "시험 포인트 문장을 완전하게 복원하지 못했습니다." : normalized
    }

    private enum CardTextRole {
        case issue
        case ruling
        case exam
    }

    private func normalizeCardText(_ raw: String, role: CardTextRole) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        if role == .issue {
            if let slash = text.range(of: #"\s*/\s*"#, options: .regularExpression) {
                let left = String(text[..<slash.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(text[slash.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                text = (left.isEmpty || left.hasPrefix("여부")) ? right : left
            }
            text = text.replacingOccurrences(of: #"^여부\s*(\((적극|소극|한정 적극|한정 소극|한정적극|한정소극)\))?\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"^위증죄의 주체와 관련하여,\s*"#, with: "", options: .regularExpression)
            if text.contains("(적극)") || text.contains("(한정 적극)") || text.contains("(한정적극)") {
                let decl = JudgmentParser.declarativeStatement(issue: text, polarity: .positive)
                if !decl.isEmpty { text = decl }
            } else if text.contains("(소극)") || text.contains("(한정 소극)") || text.contains("(한정소극)") {
                let decl = JudgmentParser.declarativeStatement(issue: text, polarity: .negative)
                if !decl.isEmpty { text = decl }
            } else if text.hasSuffix("여부") || text.hasSuffix("여부.") || text.hasSuffix("는지") || text.hasSuffix("는지.") {
                let decl = JudgmentParser.declarativeStatement(issue: text, polarity: .positive)
                if !decl.isEmpty { text = decl }
            }
        }

        if text.hasPrefix("위의 진술") && role == .ruling { return "" }
        if text.hasPrefix("여부") { return "" }
        if text.contains(" / ") || text.contains("/") { return "" }
        if text.hasSuffix("…") || text.hasSuffix("...") || text.hasSuffix("(이하 생략)") { return "" }
        if text.count < 12 { return "" }

        if !(text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!")) {
            if text.hasSuffix("다") || text.hasSuffix("요") {
                text += "."
            } else if role == .exam {
                text += "."
            }
        }
        return text
    }
}

// MARK: - 암기 수첩 카드

private struct StudyNoteCard: View {
    let label: String
    let content: String
    let accentColor: Color
    /// 사용자 메모를 영속 저장할 UserDefaults 키. nil 이면 메모 기능 비활성.
    var memoStorageKey: String? = nil

    @State private var memoText: String = ""
    @State private var isEditingMemo: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── 라벨 + AI 요약 뱃지 ──────────────────────────
            HStack(spacing: 6) {
                Text(label)
                    .font(AppFont.tag)
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.18))
                    .clipShape(Capsule())

                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .bold))
                    Text("AI 요약")
                        .font(AppFont.tag)
                }
                .foregroundStyle(AppColor.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppColor.surfaceElevated)
                .clipShape(Capsule())

                Spacer()
            }

            Text(content)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // ── 사용자 메모 영역 ─────────────────────────────
            if memoStorageKey != nil {
                memoSection
            }
        }
        .padding(AppSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.m)
                .stroke(accentColor.opacity(0.35), lineWidth: 1)
        )
        .onAppear { loadMemo() }
        .onChange(of: memoStorageKey ?? "") { _ in loadMemo() }
    }

    @ViewBuilder
    private var memoSection: some View {
        // AI 요약과 시각적으로 분리되는 점선 구분선
        Divider()
            .overlay(AppColor.border)
            .padding(.vertical, 4)

        HStack(spacing: 6) {
            Image(systemName: "pencil.line")
                .font(.system(size: 11, weight: .semibold))
            Text("내 메모")
                .font(AppFont.tag)
            Spacer()
            if !isEditingMemo {
                Button {
                    isEditingMemo = true
                } label: {
                    Text(memoText.isEmpty ? "추가" : "수정")
                        .font(AppFont.tag)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accentColor)
            }
        }
        .foregroundStyle(AppColor.textSecondary)

        if isEditingMemo {
            // 편집 모드 — 사용자 입력 영역. 배경을 진한 navy 로 깔아 AI 영역과 명확히 구분.
            VStack(alignment: .trailing, spacing: 6) {
                TextEditor(text: $memoText)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .padding(8)
                    .background(AppColor.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.s)
                            .stroke(accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )

                HStack(spacing: 8) {
                    Button("취소") {
                        loadMemo() // 변경 사항 폐기
                        isEditingMemo = false
                    }
                    .font(AppFont.captionEmphasis)
                    .foregroundStyle(AppColor.textSecondary)

                    Button("저장") {
                        saveMemo()
                        isEditingMemo = false
                    }
                    .font(AppFont.captionEmphasis)
                    .foregroundStyle(accentColor)
                }
            }
        } else if !memoText.isEmpty {
            // 표시 모드 — 저장된 메모를 점선 테두리 + 배경 구분으로 표시
            Text(memoText)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AppColor.background.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.s)
                        .stroke(accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                )
        } else {
            // 빈 상태 — 가벼운 안내
            Text("메모를 추가하면 여기에 표시됩니다.")
                .font(AppFont.tag)
                .foregroundStyle(AppColor.textTertiary)
                .padding(.bottom, 2)
        }
    }

    private func loadMemo() {
        guard let key = memoStorageKey else { memoText = ""; return }
        memoText = UserDefaults.standard.string(forKey: key) ?? ""
    }

    private func saveMemo() {
        guard let key = memoStorageKey else { return }
        let trimmed = memoText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            memoText = ""
        } else {
            UserDefaults.standard.set(memoText, forKey: key)
        }
    }
}

// MARK: - OX 퀴즈 뷰

struct OXQuizView: View {
    @EnvironmentObject private var store: ReviewStore

    let caseNumber: String
    let caseTitle: String
    let caseSubject: String?
    let caseSummary: String
    let items: [OXQuizQuestion]

    @State private var currentIndex = 0
    @State private var selectedAnswer: Bool? = nil
    @State private var showResult = false
    @State private var correctCount = 0
    @State private var finished = false
    @State private var showWrongMemoSheet = false
    @State private var wrongMemoDraft = ""
    @State private var pendingWrongRecordId: String?

    private var current: OXQuizQuestion? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.l) {
                Text(caseTitle)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)

                if finished {
                    // ── 결과 화면 ──────────────────────────────────
                    VStack(spacing: 12) {
                        Image(systemName: correctCount == items.count ? "star.fill" : "checkmark.seal")
                            .font(.system(size: 52))
                            .foregroundStyle(correctCount == items.count ? AppColor.accent : AppColor.success)
                        Text("\(items.count)문항 중 \(correctCount)개 정답")
                            .font(AppFont.title)
                            .foregroundStyle(AppColor.textPrimary)
                        Text(correctCount == items.count ? "완벽합니다!" : "틀린 문항을 다시 확인해보세요.")
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                        Button("처음부터 다시") {
                            currentIndex = 0
                            selectedAnswer = nil
                            showResult = false
                            correctCount = 0
                            finished = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColor.accent)
                        .foregroundStyle(AppColor.background)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)

                } else if let q = current {
                    // ── 진행 바 ────────────────────────────────────
                    ProgressView(value: Double(currentIndex), total: Double(items.count))
                        .tint(AppColor.accent)
                    Text("문항 \(currentIndex + 1) / \(items.count)")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)

                    // ── 진술 ───────────────────────────────────────
                    Text(q.statement)
                        .font(AppFont.bodyEmphasis)
                        .foregroundStyle(AppColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(AppSpace.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColor.surface)
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.m).stroke(AppColor.separator, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))

                    // ── O / X 버튼 ────────────────────────────────
                    HStack(spacing: 24) {
                        OXButton(label: "O", color: AppColor.success, selected: selectedAnswer == true) {
                            guard !showResult else { return }
                            selectedAnswer = true
                            commitAnswer(question: q, chosenAnswer: true)
                        }
                        OXButton(label: "X", color: AppColor.danger, selected: selectedAnswer == false) {
                            guard !showResult else { return }
                            selectedAnswer = false
                            commitAnswer(question: q, chosenAnswer: false)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // ── 해설 ───────────────────────────────────────
                    if showResult, let chosen = selectedAnswer {
                        let isCorrect = chosen == q.answer
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isCorrect ? "정답입니다" : "오답입니다")
                                .font(AppFont.sectionHeader)
                                .foregroundStyle(isCorrect ? AppColor.success : AppColor.danger)
                            Text(q.explanation)
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textPrimary)
                            Button {
                                showWrongMemoSheet = true
                            } label: {
                                Label(
                                    (pendingWrongRecordId.flatMap { id in store.wrongQuizRecords.first(where: { $0.id == id })?.userMemo }?.isEmpty == false) ? "메모 수정" : "메모 남기기",
                                    systemImage: "square.and.pencil"
                                )
                                .font(AppFont.captionEmphasis)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background((isCorrect ? AppColor.accent : AppColor.danger).opacity(0.14))
                                .foregroundStyle(isCorrect ? AppColor.accent : AppColor.danger)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
                            }
                        }
                        .padding(AppSpace.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColor.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))

                        Button(currentIndex + 1 < items.count ? "다음 문항" : "결과 보기") {
                            advance()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColor.accent)
                        .foregroundStyle(AppColor.background)
                    }
                }
            }
            .padding(AppSpace.l)
        }
        .withAppBackground()
        .navigationTitle("OX 퀴즈")
        .navigationBarTitleDisplayMode(.inline)
        .withSmallBackButton()
        .sheet(isPresented: $showWrongMemoSheet) {
            NavigationStack {
                VStack(alignment: .leading, spacing: AppSpace.m) {
                    Text("오답 메모")
                        .font(AppFont.sectionHeader)
                    Text("틀린 이유나 다음 회독 포인트를 짧게 기록하세요.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    TextEditor(text: $wrongMemoDraft)
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.m)
                                .stroke(AppColor.separator, lineWidth: 0.6)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
                    Spacer()
                }
                .padding(AppSpace.l)
                .withAppBackground()
                .navigationTitle("오답 메모")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("건너뛰기") { showWrongMemoSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("저장") {
                            if let id = pendingWrongRecordId {
                                store.updateWrongQuizMemo(recordId: id, memo: wrongMemoDraft)
                            }
                            showWrongMemoSheet = false
                        }
                    }
                }
            }
        }
    }

    private func commitAnswer(question: OXQuizQuestion, chosenAnswer: Bool) {
        let correct = chosenAnswer == question.answer
        showResult = true
        if correct { correctCount += 1 }
        let savedId = store.saveWrongQuizRecord(
            caseNumber: caseNumber,
            caseTitle: caseTitle,
            question: question.statement,
            userAnswer: chosenAnswer,
            correctAnswer: question.answer,
            explanation: question.explanation,
            caseSummary: caseSummary,
            subject: caseSubject
        )
        pendingWrongRecordId = savedId
        wrongMemoDraft = ""
    }

    private func advance() {
        if currentIndex + 1 < items.count {
            currentIndex += 1
            selectedAnswer = nil
            showResult = false
        } else {
            finished = true
        }
    }
}

private struct OXButton: View {
    let label: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 48, weight: .bold))
                .frame(width: 100, height: 100)
                .background(selected ? color : color.opacity(0.15))
                .foregroundStyle(selected ? .white : color)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}


struct QuizView: View {
    let question: QuizQuestion
    @State private var selected = 0
    @State private var checked = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("유사 사례 문제 풀이")
                    .font(.largeTitle.bold())
                Text(question.prompt)
                    .font(.headline)

                ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
                    let number = idx + 1
                    Button {
                        selected = number
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(number)")
                                .font(.headline)
                                .frame(width: 30, height: 30)
                                .background(selected == number ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundStyle(selected == number ? .white : .primary)
                                .clipShape(Circle())
                            Text(option)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding()
                        .background(selected == number ? Color.teal.opacity(0.25) : Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                if checked {
                    let isCorrect = selected == question.correctIndex + 1
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isCorrect ? "정답입니다" : "오답입니다")
                            .font(.headline)
                            .foregroundStyle(isCorrect ? .green : .red)
                        Text(question.explanation)
                            .font(.subheadline)
                        HStack {
                            ForEach(question.keywords, id: \.self) { keyword in
                                TagView(text: keyword)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button("정답 확인하기") {
                    checked = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == 0)

                NavigationLink("오답 저장 및 복습") {
                    WrongAnswerSaveView(caseTitle: question.title)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .padding()
        }
        .navigationTitle("문제 풀이")
        .withSmallBackButton()
    }
}

struct WrongAnswerSaveView: View {
    @EnvironmentObject private var store: ReviewStore
    @Environment(\.dismiss) private var dismiss

    let caseTitle: String
    @State private var confusionPoint = ""
    @State private var memo = ""
    @State private var showSaved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("오답 노트")
                    .font(.largeTitle.bold())
                Text(caseTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                TextField("헷갈리는 지점", text: $confusionPoint)
                    .textFieldStyle(.roundedBorder)
                TextField("나만의 메모", text: $memo, axis: .vertical)
                    .lineLimit(4, reservesSpace: true)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("취소") { dismiss() }
                        .buttonStyle(.bordered)
                    Button("저장") {
                        let note = WrongAnswerNote(title: caseTitle, confusionPoint: confusionPoint, memo: memo)
                        store.saveWrongAnswer(note: note)
                        showSaved = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .alert("복습 목록에 추가되었습니다", isPresented: $showSaved) {
            Button("확인", role: .cancel) { dismiss() }
        }
        .navigationTitle("오답 저장")
        .withSmallBackButton()
    }
}

struct ReviewView: View {
    @EnvironmentObject private var store: ReviewStore
    @EnvironmentObject private var runtime: AppRuntimeState
    @Query(sort: \ScannedCase.scannedAt, order: .reverse)
    private var scannedCases: [ScannedCase]

    /// 약점 영역 추천 판례 — body 평가 시마다 임베딩을 돌리지 않도록 비동기 계산 후 캐시한다.
    @State private var similarRecommendations: [APICase] = []
    @State private var lastSimilarityKey: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("복습 노트")
                    .font(.largeTitle.bold())
                Text("검색하거나 스캔한 판례가 자동으로 저장됩니다.")
                    .foregroundStyle(.secondary)

                // ── 약점 카테고리 (오답 패턴 분석) ──────────────
                let weak = store.weakSubjects()
                if !weak.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("자주 틀리는 영역")
                                .font(.headline)
                        }
                        ForEach(weak, id: \.label) { item in
                            NavigationLink {
                                WeakOXListView(subjectLabel: item.label)
                            } label: {
                                HStack {
                                    Text(item.label)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("오답 \(item.count)회")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(Color.orange.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                // ── 약점 영역 기반 유사 판례 추천 (비동기 캐시) ──
                if !weak.isEmpty && !similarRecommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.indigo)
                            Text("약점 영역 추천 판례")
                                .font(.headline)
                        }
                        ForEach(similarRecommendations) { c in
                            NavigationLink {
                                CaseSummaryView(apiCase: c)
                            } label: {
                                SearchResultCard(
                                    title: c.caseNumber,
                                    subtitle: c.subject,
                                    tags: c.subject.isEmpty ? [] : ["#\(c.subject)"],
                                    summary: c.issueSummary ?? ""
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // ── 빈 상태 ────────────────────────────────────
                if store.savedCases.isEmpty && scannedCases.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("저장된 판례가 없습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("검색 결과를 탭하거나 판례를 스캔해 가볍게 모아두는 공간입니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }

                // ── 검색한 판례 (API) ───────────────────────────
                if !store.savedCases.isEmpty {
                    Text("검색한 판례")
                        .font(.title3.bold())
                    ForEach(store.savedCases) { apiCase in
                        NavigationLink {
                            CaseSummaryView(apiCase: apiCase)
                        } label: {
                            SearchResultCard(
                                title: apiCase.caseNumber,
                                subtitle: "\(apiCase.courtName)  \(apiCase.caseNumber)",
                                tags: apiCase.subject.isEmpty ? [] : ["#\(apiCase.subject)"],
                                summary: apiCase.issueSummary ?? ""
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.removeCase(id: apiCase.id)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }
                }

                // ── 스캔한 판례 ───────────────────────────
                if !scannedCases.isEmpty {
                    if !store.savedCases.isEmpty { Divider().padding(.vertical, 4) }
                    Text("스캔한 판례")
                        .font(.title3.bold())
                    Text("저장된 \(scannedCases.count)건")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(scannedCases) { scanned in
                        NavigationLink {
                            CaseSummaryView(
                                apiCase: scanned.toAPICase(),
                                viewModel: {
                                    let vm = CaseSummaryViewModel()
                                    vm.injectIRResult(
                                        keywords: scanned.keywords,
                                        keySentences: scanned.keySentences
                                    )
                                    return vm
                                }()
                            )
                        } label: {
                            SearchResultCard(
                                title: scanned.toAPICase().caseNumber,
                                subtitle: "스캔 \(DateFormatter.shortDate.string(from: scanned.scannedAt))",
                                tags: scanned.keywords.prefix(3).map { "#\($0)" },
                                summary: scanned.keySentences
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("복습 노트")
        .task(id: similarityCacheKey) {
            await refreshSimilarRecommendations()
        }
    }

    /// 캐시 무효화 키 — weakSubjects 와 케이스 수 변화에만 반응
    private var similarityCacheKey: String {
        let weak = store.weakSubjects().map { $0.label }.joined(separator: "|")
        return "\(weak)#\(store.savedCases.count)#\(scannedCases.count)"
    }

    @MainActor
    private func refreshSimilarRecommendations() async {
        let weak = store.weakSubjects()
        guard !weak.isEmpty else {
            similarRecommendations = []
            return
        }
        let allCases: [APICase] = store.savedCases + scannedCases.map { $0.toAPICase() }
        let queryText = weak.map { $0.label }.joined(separator: " ")
        // NLEmbedding 호출은 첫 진입 시 무거우므로 background priority detached Task 로 실제로 떼어낸다.
        let result = await Task.detached(priority: .background) {
            LocalSimilarityEngine.shared.findSimilar(query: queryText, in: allCases, topK: 3)
        }.value
        similarRecommendations = result
    }
}

struct MyPageView: View {
    @AppStorage(NetworkService.overrideKey) private var apiBaseURLOverride: String = ""
    @State private var serverURLInput = ""

    var body: some View {
        Form {
            Section("계정") {
                Text("STACK112 사용자")
                Text("경찰 공무원 시험 준비")
            }
            // App Store Release 빌드에서는 외부 서버 입력 UI 숨김 — 본 앱은
            // 풀 온디바이스 모드로 전환되어 해당 옵션이 사용자에게 불필요하며,
            // 심사관이 "외부 전송 가능성" 으로 오해하지 않도록 노출 자체를 제거.
            #if DEBUG
            Section("서버 설정 (개발 전용)") {
                TextField("http://192.168.x.x:8000", text: $serverURLInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button("API 서버 주소 저장") {
                    apiBaseURLOverride = serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await NetworkService.shared.configureBaseURL(apiBaseURLOverride) }
                }
                .buttonStyle(.borderedProminent)

                if !apiBaseURLOverride.isEmpty {
                    Text("현재 오버라이드: \(apiBaseURLOverride)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("오버라이드 초기화") {
                    apiBaseURLOverride = ""
                    serverURLInput = ""
                    Task { await NetworkService.shared.configureBaseURL("") }
                }
                .buttonStyle(.bordered)
            }
            #endif
            Section("앱 정보") {
                Text("버전 1.0.0")
            }
        }
        .navigationTitle("My Page")
        .task {
            if serverURLInput.isEmpty {
                serverURLInput = apiBaseURLOverride
            }
        }
    }
}

private struct InfoCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SearchResultCard: View {
    let title: String
    let subtitle: String
    let tags: [String]
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subtitle)
                .font(AppFont.tag)
                .foregroundStyle(AppColor.accent)
            Text(title)
                .font(AppFont.bodyEmphasis)
                .foregroundStyle(AppColor.textPrimary)
            Text(summary)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            HStack {
                ForEach(tags, id: \.self) { tag in
                    TagView(text: tag)
                }
                Spacer()
                Text("상세보기 →")
                    .font(AppFont.captionEmphasis)
                    .foregroundStyle(AppColor.accent)
            }
        }
        .padding(AppSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.m).stroke(AppColor.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
    }
}

private struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppFont.tag)
            .foregroundStyle(AppColor.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppColor.accentSoft)
            .clipShape(Capsule())
    }
}

private extension DateFormatter {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()
}


// MARK: - 약점 영역 OX 모음 화면

/// 약점 영역(예: "민사 · 제19조제3항 · 제280조") 클릭 시 사용자가 그 영역에서 틀렸던 OX 기록을 열거.
struct WeakOXListView: View {
    let subjectLabel: String
    @EnvironmentObject private var store: ReviewStore

    var body: some View {
        let records = filteredRecords
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                Text(subjectLabel)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)

                if records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 48))
                            .foregroundStyle(AppColor.success)
                        Text("이 영역에 메모해 둔 오답이 아직 없어요.")
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    Text("총 \(records.count)건의 오답을 한 번 더 점검하세요.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)

                    ForEach(records) { rec in
                        WrongOXCard(record: rec)
                    }
                }
            }
            .padding(AppSpace.l)
        }
        .withAppBackground()
        .navigationTitle("자주 틀린 OX")
        .navigationBarTitleDisplayMode(.inline)
        .withSmallBackButton()
    }

    private var filteredRecords: [WrongQuizRecord] {
        let key = subjectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.wrongQuizRecords.filter { rec in
            let hasMemo = (rec.userMemo?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            let isWrong = rec.userAnswer != rec.correctAnswer
            guard isWrong || hasMemo else { return false }
            guard let subj = rec.subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subj.isEmpty else {
                return false
            }
            return subj == key || subj.hasPrefix(key) || subj.contains(key) || key.contains(subj)
        }
    }
}

private struct WrongOXCard: View {
    @EnvironmentObject private var store: ReviewStore
    let record: WrongQuizRecord
    @State private var showMemoEditor = false
    @State private var draftMemo: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(record.caseNumber)
                    .font(AppFont.tag)
                    .foregroundStyle(AppColor.accent)
                Spacer()
                Text(record.solvedAt)
                    .font(AppFont.tag)
                    .foregroundStyle(AppColor.textTertiary)
            }
            Text(record.question)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Label("내 답: \(record.userAnswer)", systemImage: "person.fill.questionmark")
                    .font(AppFont.captionEmphasis)
                    .foregroundStyle(AppColor.danger)
                Label("정답: \(record.correctAnswer)", systemImage: "checkmark.seal.fill")
                    .font(AppFont.captionEmphasis)
                    .foregroundStyle(AppColor.success)
            }
            if !record.explanation.isEmpty {
                Text(record.explanation)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let memo = record.userMemo, !memo.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("내 메모")
                        .font(AppFont.tag)
                        .foregroundStyle(AppColor.accent)
                    Text(memo)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(record.userMemo?.isEmpty == false ? "메모 수정" : "메모 추가") {
                draftMemo = record.userMemo ?? ""
                showMemoEditor = true
            }
            .font(AppFont.captionEmphasis)
            .foregroundStyle(AppColor.accent)
        }
        .padding(AppSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.m).stroke(AppColor.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
        .sheet(isPresented: $showMemoEditor) {
            NavigationStack {
                VStack(alignment: .leading, spacing: AppSpace.m) {
                    Text("오답 메모")
                        .font(AppFont.sectionHeader)
                    Text(record.question)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(3)
                    TextEditor(text: $draftMemo)
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(AppColor.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.m)
                                .stroke(AppColor.separator, lineWidth: 0.6)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
                    Text("이 문항에서 왜 틀렸는지, 다음 회독에서 볼 포인트를 남겨두세요.")
                        .font(AppFont.tag)
                        .foregroundStyle(AppColor.textTertiary)
                    Spacer()
                }
                .padding(AppSpace.l)
                .withAppBackground()
                .navigationTitle("오답 메모")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { showMemoEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("저장") {
                            store.updateWrongQuizMemo(recordId: record.id, memo: draftMemo)
                            showMemoEditor = false
                        }
                    }
                }
            }
        }
    }
}

