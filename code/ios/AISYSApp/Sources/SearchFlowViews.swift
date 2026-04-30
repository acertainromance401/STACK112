import SwiftUI
import SwiftData

struct SearchView: View {
    @EnvironmentObject private var store: ReviewStore
    @EnvironmentObject private var runtime: AppRuntimeState
    @StateObject private var viewModel = CaseSummaryViewModel()
    @State private var keyword = ""

    @Query(sort: \ScannedCase.scannedAt, order: .reverse)
    private var scannedCases: [ScannedCase]

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

                if !viewModel.backendConnected {
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
                    ForEach(viewModel.searchResults) { apiCase in
                        NavigationLink {
                            CaseSummaryView(apiCase: apiCase, viewModel: viewModel)
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
                    Text("OCR로 저장된 \(scannedCases.count)건")
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
                                title: scanned.caseName,
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
        .navigationTitle("Search")
        .withSmallBackButton()
        .task {
            await viewModel.loadInitialCasesIfNeeded()
        }
        .onChange(of: runtime.pendingSearchQuery) { newValue in
            guard let query = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return
            }
            keyword = query
            runtime.pendingSearchQuery = nil
            Task { await viewModel.search(query: query) }
        }
    }
}

struct CaseSummaryView: View {
    // 실제 API 데이터 경로
    var apiCase: APICase? = nil
    @ObservedObject var viewModel: CaseSummaryViewModel = CaseSummaryViewModel()
    // 더미 데이터 폴백 경로
    var detail: CaseDetail? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let resolved = viewModel.displayDetail ?? detail {

                    // ── 제목 ──────────────────────────────────────
                    Text(resolved.title)
                        .font(.title2.bold())

                    // ── LLM 추론 상태 ──────────────────────────────
                    if viewModel.isSummarizing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("판례를 분석하는 중...")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    // ── 암기 수첩 카드 ──────────────────────────────
                    StudyNoteCard(
                        label: "한 줄 요약",
                        content: viewModel.summary?.oneLineSummary ?? resolved.issue,
                        accentColor: .blue
                    )
                    StudyNoteCard(
                        label: "핵심 쟁점",
                        content: viewModel.summary?.keyIssue ?? resolved.issue,
                        accentColor: .orange
                    )
                    StudyNoteCard(
                        label: "판결 결론",
                        content: viewModel.summary?.rulingPoint ?? resolved.conclusion,
                        accentColor: .teal
                    )
                    StudyNoteCard(
                        label: "시험 포인트",
                        content: viewModel.summary?.examTakeaway ?? resolved.examPoint,
                        accentColor: .purple
                    )

                    // IR 키워드 태그
                    if !viewModel.irKeywords.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("추출 키워드")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(viewModel.irKeywords, id: \.self) { kw in
                                        TagView(text: kw)
                                    }
                                }
                            }
                        }
                    }

                    if let err = viewModel.errorMessage {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }

                    Divider()

                    // ── OX 퀴즈 버튼 ───────────────────────────────
                    if viewModel.isGeneratingOXQuiz {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("OX 퀴즈를 생성하는 중...")
                                .font(.subheadline).foregroundStyle(.secondary)
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
                        .tint(.indigo)
                        .disabled(viewModel.isSummarizing)
                    }

                    if !viewModel.oxQuizItems.isEmpty {
                        NavigationLink {
                            OXQuizView(
                                caseTitle: resolved.title,
                                items: viewModel.oxQuizItems
                            )
                        } label: {
                            Label("OX 퀴즈 풀기 (\(viewModel.oxQuizItems.count)문항)", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(.indigo)
                    }

                    // 유사 판례
                    if !resolved.similarCases.isEmpty {
                        Text("유사 판례 리스트").font(.title2.bold())
                        ForEach(resolved.similarCases, id: \.self) { item in
                            InfoCard(title: item, detail: "유사 쟁점 비교 학습용")
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("판례 요약")
        .withSmallBackButton()
        .task {
            if let c = apiCase {
                await viewModel.select(caseItem: c)
            }
        }
    }
}

// MARK: - 암기 수첩 카드

private struct StudyNoteCard: View {
    let label: String
    let content: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(accentColor.opacity(0.12))
                .clipShape(Capsule())
            Text(content)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(accentColor.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - OX 퀴즈 뷰

struct OXQuizView: View {
    let caseTitle: String
    let items: [OXQuizQuestion]

    @State private var currentIndex = 0
    @State private var selectedAnswer: Bool? = nil
    @State private var showResult = false
    @State private var correctCount = 0
    @State private var finished = false

    private var current: OXQuizQuestion? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("OX 퀴즈")
                    .font(.largeTitle.bold())
                Text(caseTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if finished {
                    // ── 결과 화면 ──────────────────────────────────
                    VStack(spacing: 12) {
                        Image(systemName: correctCount == items.count ? "star.fill" : "checkmark.seal")
                            .font(.system(size: 52))
                            .foregroundStyle(correctCount == items.count ? .yellow : .teal)
                        Text("\(items.count)문항 중 \(correctCount)개 정답")
                            .font(.title2.bold())
                        Text(correctCount == items.count ? "완벽합니다!" : "틀린 문항을 다시 확인해보세요.")
                            .foregroundStyle(.secondary)
                        Button("처음부터 다시") {
                            currentIndex = 0
                            selectedAnswer = nil
                            showResult = false
                            correctCount = 0
                            finished = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)

                } else if let q = current {
                    // ── 진행 바 ────────────────────────────────────
                    ProgressView(value: Double(currentIndex), total: Double(items.count))
                        .tint(.indigo)
                    Text("문항 \(currentIndex + 1) / \(items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // ── 진술 ───────────────────────────────────────
                    Text(q.statement)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    // ── O / X 버튼 ────────────────────────────────
                    HStack(spacing: 24) {
                        OXButton(label: "O", color: .teal, selected: selectedAnswer == true) {
                            guard !showResult else { return }
                            selectedAnswer = true
                            commitAnswer(correct: q.answer)
                        }
                        OXButton(label: "X", color: .red, selected: selectedAnswer == false) {
                            guard !showResult else { return }
                            selectedAnswer = false
                            commitAnswer(correct: !q.answer)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // ── 해설 ───────────────────────────────────────
                    if showResult, let chosen = selectedAnswer {
                        let isCorrect = chosen == q.answer
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isCorrect ? "정답입니다" : "오답입니다")
                                .font(.headline)
                                .foregroundStyle(isCorrect ? .teal : .red)
                            Text(q.explanation)
                                .font(.subheadline)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button(currentIndex + 1 < items.count ? "다음 문항" : "결과 보기") {
                            advance()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("OX 퀴즈")
        .withSmallBackButton()
    }

    private func commitAnswer(correct: Bool) {
        showResult = true
        if correct { correctCount += 1 }
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

    var body: some View {
        List(store.wrongAnswers) { item in
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline)
                Text(item.memo).font(.subheadline).foregroundStyle(.secondary)
                Text(item.date).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Review")
        .withSmallBackButton()
    }
}

struct MyPageView: View {
    @AppStorage(NetworkService.overrideKey) private var apiBaseURLOverride: String = ""
    @State private var serverURLInput = ""

    var body: some View {
        Form {
            Section("계정") {
                Text("AI_SYS 사용자")
                Text("경찰 공무원 시험 준비")
            }
            Section("서버 설정") {
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
            Section("앱 정보") {
                Text("버전 1.0.0")
            }
        }
        .navigationTitle("My Page")
        .withSmallBackButton()
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
                .font(.caption)
                .foregroundStyle(.blue)
            Text(title)
                .font(.headline)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(tags, id: \.self) { tag in
                    TagView(text: tag)
                }
                Spacer()
                Text("상세보기")
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.12))
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

