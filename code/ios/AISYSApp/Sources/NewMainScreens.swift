import SwiftUI
import SwiftData

private extension DateFormatter {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        return f
    }()
}

// =====================================================================
//  NewMainScreens.swift
//  경찰고시 학습 보조 앱 — UX/UI 개편 1차 (다크 네이비 + 골드)
//
//  포함 화면 (6 메인 탭):
//    HomeView          : 오늘의 학습, D-Day, 추천 복습, 약점, 진행률
//    PracticeView      : 문제풀이 (OX, 확신도 입력 → AI 약점 분석)
//    WrongNoteView     : 오답노트 (자동 분류, 반복 추적)
//    CaseCardsView     : 판례카드 (스와이프, OCR 진입)
//    AIAnalysisView    : AI 분석 (약점 패턴/회독 추천)
//    StatsView         : 정답률·기억유지·streak + 설정 진입
//
//  공통 디자인 토큰은 `DesignSystem.swift` 에서 가져온다.
// =====================================================================

// MARK: =============================================================
// MARK: Home
// MARK: =============================================================
struct HomeView: View {
    @EnvironmentObject private var runtime: AppRuntimeState
    @EnvironmentObject private var store: ReviewStore
    @StateObject private var studyStore = StudyStore.shared
    @Query(sort: \ScannedCase.scannedAt, order: .reverse)
    private var scannedCases: [ScannedCase]
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.l) {
                header
                dDayCard
                todayProgressCard
                quickActionsRow
                if !weakSubjects.isEmpty { weakAreasCard }
                aiRoutineCard
                recentReviewCard
            }
            .padding(AppSpace.l)
            .padding(.bottom, AppSpace.xxl)
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI SYS")
                    .font(AppFont.tag)
                    .foregroundStyle(AppColor.accent)
                Text("오늘도 합격을 향해")
                    .font(AppFont.displayTitle)
                    .foregroundStyle(AppColor.textPrimary)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(10)
                    .background(AppColor.surface)
                    .clipShape(Circle())
            }
        }
        .padding(.top, AppSpace.s)
    }

    private var dDayCard: some View {
        AppCard {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(studyStore.dDayName)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("D-\(max(0, studyStore.dDay))")
                            .font(AppFont.metricNumber)
                            .foregroundStyle(AppColor.accent)
                        Text("일 남음")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("연속 학습")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(AppColor.accent)
                        Text("\(studyStore.streakDays)일")
                            .font(AppFont.bodyEmphasis)
                            .foregroundStyle(AppColor.textPrimary)
                    }
                }
            }
        }
    }

    private var todayProgressCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                SectionHeader(title: "오늘의 학습", trailing: "목표 \(studyStore.dailyGoalQuestions)문항")
                HStack(spacing: AppSpace.l) {
                    MetricBlock(value: "\(studyStore.todaySolved)", label: "푼 문제")
                    MetricBlock(value: "\(studyStore.todayWrong)", label: "오답", tint: AppColor.danger)
                    MetricBlock(
                        value: studyStore.todaySolved > 0 ? "\(Int((Double(studyStore.todayCorrect)/Double(studyStore.todaySolved)) * 100))" : "—",
                        label: "정답률",
                        tint: AppColor.success,
                        trailingSymbol: studyStore.todaySolved > 0 ? "%" : nil
                    )
                }
                ProgressView(value: studyStore.todayProgress)
                    .progressViewStyle(.linear)
                    .tint(AppColor.accent)
                    .background(AppColor.surfaceElevated)
                    .clipShape(Capsule())
                Button {
                    runtime.selectedTab = 2
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("오늘의 문제 시작")
                            .font(AppFont.bodyEmphasis)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding(.vertical, AppSpace.m)
                    .padding(.horizontal, AppSpace.l)
                    .background(AppColor.accent)
                    .foregroundStyle(AppColor.background)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.m, style: .continuous))
                }
            }
        }
    }

    private var quickActionsRow: some View {
        HStack(spacing: AppSpace.m) {
            QuickActionButton(icon: "doc.text.viewfinder", label: "판례 스캔", tint: AppColor.accent) {
                runtime.selectedTab = 1
            }
            QuickActionButton(icon: "exclamationmark.bubble.fill", label: "오답노트", tint: AppColor.danger) {
                runtime.selectedTab = 3
            }
            QuickActionButton(icon: "brain.head.profile", label: "AI분석", tint: AppColor.info) {
                runtime.selectedTab = 4
            }
        }
    }

    private var weakSubjects: [(label: String, count: Int)] {
        store.weakSubjects()
    }

    private var weakAreasCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                SectionHeader(title: "최근 약점", trailing: "AI 분석 →")
                ForEach(weakSubjects, id: \.label) { item in
                    HStack {
                        Circle()
                            .fill(AppColor.danger)
                            .frame(width: 6, height: 6)
                        Text(item.label)
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textPrimary)
                        Spacer()
                        Text("오답 \(item.count)회")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onTapGesture { runtime.selectedTab = 4 }
    }

    private var aiRoutineCard: some View {
        AppCard(background: AppColor.surfaceElevated) {
            VStack(alignment: .leading, spacing: AppSpace.s) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(AppColor.accent)
                    Text("AI 추천 학습 루틴")
                        .font(AppFont.sectionHeader)
                }
                Text(aiRoutineText)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(3)
            }
        }
    }

    private var aiRoutineText: String {
        if studyStore.todaySolved == 0 {
            return "오늘은 아직 학습을 시작하지 않았습니다. 어제 오답 \(store.wrongQuizRecords.prefix(10).count)건부터 5분 회독을 권장합니다."
        }
        if let weak = weakSubjects.first {
            return "‘\(weak.label)’ 영역에서 오답 \(weak.count)회. 같은 단원 OX 10문항을 다시 풀어 약점을 다지세요."
        }
        return "정답률이 안정적입니다. 새 판례 카드 5장을 회독하고 OX 변형 문제로 점검하세요."
    }

    private var recentReviewCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                SectionHeader(title: "최근 스캔 판례", trailing: scannedCases.isEmpty ? nil : "전체보기 →")
                if scannedCases.isEmpty {
                    Text("아직 스캔한 판례가 없습니다. ‘판례 스캔’ 탭에서 추가하세요.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                } else {
                    ForEach(scannedCases.prefix(3)) { sc in
                        HStack(spacing: AppSpace.m) {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(AppColor.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sc.caseName)
                                    .font(AppFont.bodyEmphasis)
                                    .foregroundStyle(AppColor.textPrimary)
                                    .lineLimit(1)
                                Text(sc.keywords.prefix(3).joined(separator: " · "))
                                    .font(AppFont.caption)
                                    .foregroundStyle(AppColor.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .onTapGesture { runtime.selectedTab = 1 }
    }
}

private struct QuickActionButton: View {
    let icon: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(label)
                    .font(AppFont.captionEmphasis)
                    .foregroundStyle(AppColor.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpace.m)
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.m).stroke(AppColor.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: =============================================================
// MARK: Practice (문제풀이)
// MARK: =============================================================
//
// 현재 데이터 모델로 객관식 문제 풀(seed) 이 없으므로, 사용자가 가장 최근에 OCR 한 판례를
// 기반으로 OX 변형 문제를 즉시 만들어 푸는 1버전을 제공한다.
// 확신도(sure/unsure/guess) 를 답안과 함께 기록하여 AI 분석의 입력으로 활용한다.
struct PracticeView: View {
    @StateObject private var studyStore = StudyStore.shared
    @EnvironmentObject private var store: ReviewStore
    @Query(sort: \ScannedCase.scannedAt, order: .reverse)
    private var scannedCases: [ScannedCase]

    @State private var quiz: [OXQuizQuestion] = []
    @State private var currentIndex: Int = 0
    @State private var selectedConfidence: AnswerConfidence = .unsure
    @State private var userAnswer: Bool? = nil
    @State private var loading = false
    @State private var statusText: String = ""
    @State private var sessionCorrect = 0
    @State private var sessionSolved = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.l) {
                header
                if quiz.isEmpty {
                    emptyCard
                } else if currentIndex >= quiz.count {
                    finishedCard
                } else {
                    questionCard
                    confidencePicker
                    answerButtons
                    if userAnswer != nil { feedbackCard }
                }
            }
            .padding(AppSpace.l)
        }
        .navigationTitle("문제풀이")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppColor.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { if quiz.isEmpty { await loadQuizFromMostRecentScan() } }
    }

    private var header: some View {
        AppCard {
            HStack(spacing: AppSpace.l) {
                MetricBlock(value: "\(sessionSolved)", label: "푼 문제")
                MetricBlock(value: "\(sessionCorrect)", label: "정답", tint: AppColor.success)
                MetricBlock(value: quiz.isEmpty ? "—" : "\(currentIndex + 1)/\(quiz.count)", label: "진행률", tint: AppColor.accent)
            }
        }
    }

    private var emptyCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                Text(loading ? "퀴즈 생성 중…" : "오늘의 문제를 준비할 자료가 없습니다.")
                    .font(AppFont.bodyEmphasis)
                Text(loading ? "" : "‘판례카드’ 탭에서 판례를 스캔하면 자동으로 OX 문제가 생성됩니다.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                if !statusText.isEmpty {
                    Text(statusText).font(AppFont.caption).foregroundStyle(AppColor.textTertiary)
                }
                Button("다시 생성") { Task { await loadQuizFromMostRecentScan() } }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColor.accent)
                    .disabled(loading)
            }
        }
    }

    private var finishedCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                Text("이번 세션 완료")
                    .font(AppFont.sectionHeader)
                MetricBlock(value: "\(sessionCorrect)/\(sessionSolved)", label: "정답", tint: AppColor.success)
                Text("문항을 다시 풀어 약점을 굳히세요.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                HStack(spacing: AppSpace.m) {
                    Button("다시 풀기") { restart() }
                        .buttonStyle(.bordered).tint(AppColor.accent)
                    Button("새 문제 생성") { Task { restart(); await loadQuizFromMostRecentScan() } }
                        .buttonStyle(.borderedProminent).tint(AppColor.accent)
                }
            }
        }
    }

    private var questionCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                HStack {
                    AppTag(text: "OX")
                    if let scanned = scannedCases.first {
                        AppTag(text: scanned.caseName.prefix(20).description, color: AppColor.info, background: AppColor.infoSoft)
                    }
                    Spacer()
                    Text("\(currentIndex + 1) / \(quiz.count)")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Text(quiz[currentIndex].statement)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var confidencePicker: some View {
        VStack(alignment: .leading, spacing: AppSpace.s) {
            Text("얼마나 확신하나요?")
                .font(AppFont.captionEmphasis)
                .foregroundStyle(AppColor.textSecondary)
            HStack(spacing: AppSpace.s) {
                ForEach(AnswerConfidence.allCases) { c in
                    Button {
                        selectedConfidence = c
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: c.systemImage)
                            Text(c.label).font(AppFont.captionEmphasis)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(selectedConfidence == c ? c.color.opacity(0.25) : AppColor.surface)
                        .foregroundStyle(selectedConfidence == c ? c.color : AppColor.textSecondary)
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.m).stroke(selectedConfidence == c ? c.color : AppColor.separator, lineWidth: selectedConfidence == c ? 1.2 : 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
                    }
                    .buttonStyle(.plain)
                    .disabled(userAnswer != nil)
                }
            }
        }
    }

    private var answerButtons: some View {
        HStack(spacing: AppSpace.m) {
            answerButton(true, label: "O", color: AppColor.success)
            answerButton(false, label: "X", color: AppColor.danger)
        }
    }

    private func answerButton(_ value: Bool, label: String, color: Color) -> some View {
        Button { commit(answer: value) } label: {
            Text(label)
                .font(.system(size: 36, weight: .black, design: .rounded))
                .foregroundStyle(userAnswer == value ? AppColor.background : color)
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(userAnswer == value ? color : color.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.l).stroke(color, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.l))
        }
        .buttonStyle(.plain)
        .disabled(userAnswer != nil)
    }

    private var feedbackCard: some View {
        let q = quiz[currentIndex]
        let isCorrect = userAnswer == q.answer
        return AppCard(background: isCorrect ? AppColor.successSoft : AppColor.dangerSoft) {
            VStack(alignment: .leading, spacing: AppSpace.s) {
                HStack {
                    Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(isCorrect ? AppColor.success : AppColor.danger)
                    Text(isCorrect ? "정답입니다" : "오답입니다")
                        .font(AppFont.bodyEmphasis)
                        .foregroundStyle(isCorrect ? AppColor.success : AppColor.danger)
                    Spacer()
                    AppTag(text: selectedConfidence.label, color: selectedConfidence.color, background: selectedConfidence.color.opacity(0.18))
                }
                Text(q.explanation)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(3)
                Button(currentIndex + 1 < quiz.count ? "다음 문제" : "세션 종료") { next() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppColor.accent)
                    .foregroundStyle(AppColor.background)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
            }
        }
    }

    // MARK: Logic

    @MainActor
    private func loadQuizFromMostRecentScan() async {
        loading = true
        defer { loading = false }
        statusText = ""
        guard let scanned = scannedCases.first else {
            statusText = "스캔한 판례가 없습니다."
            return
        }
        do {
            let apiCase = scanned.toAPICase()
            let items = try await LLMService.shared.generateOXQuiz(
                caseItem: apiCase,
                keySentences: scanned.keySentences,
                keywords: scanned.keywords,
                count: 4
            )
            quiz = items
            currentIndex = 0
            userAnswer = nil
            sessionCorrect = 0
            sessionSolved = 0
        } catch {
            statusText = "퀴즈 생성 실패: \(error.localizedDescription)"
        }
    }

    private func commit(answer: Bool) {
        guard userAnswer == nil, currentIndex < quiz.count else { return }
        userAnswer = answer
        let q = quiz[currentIndex]
        let correct = (answer == q.answer)
        sessionSolved += 1
        if correct { sessionCorrect += 1 }
        studyStore.recordAnswer(correct: correct, confidence: selectedConfidence)
        if !correct {
            let scanned = scannedCases.first
            store.saveWrongQuizRecord(
                caseNumber: scanned?.caseName ?? "OX",
                caseTitle: scanned?.caseName ?? "OX",
                question: q.statement,
                userAnswer: answer,
                correctAnswer: q.answer,
                explanation: q.explanation,
                caseSummary: scanned?.keySentences ?? "",
                subject: scanned?.keywords.prefix(2).joined(separator: " · ")
            )
        }
    }

    private func next() {
        userAnswer = nil
        selectedConfidence = .unsure
        currentIndex += 1
    }

    private func restart() {
        currentIndex = 0
        userAnswer = nil
        selectedConfidence = .unsure
        sessionCorrect = 0
        sessionSolved = 0
    }
}

// MARK: =============================================================
// MARK: Wrong Note (오답노트)
// MARK: =============================================================
struct WrongNoteView: View {
    @EnvironmentObject private var store: ReviewStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.l) {
                Text("오답노트")
                    .font(AppFont.displayTitle)
                Text("틀린 이유를 분류하고 반복 회독으로 굳히세요.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)

                if !weakSubjects.isEmpty { weakSection }

                AppCard {
                    SectionHeader(title: "최근 오답", trailing: "\(store.wrongQuizRecords.count)건")
                    if store.wrongQuizRecords.isEmpty {
                        Text("아직 오답이 없습니다. 문제풀이 탭에서 학습을 시작하세요.")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .padding(.top, 8)
                    } else {
                        VStack(spacing: AppSpace.m) {
                            ForEach(store.wrongQuizRecords.prefix(20)) { rec in
                                WrongRecordCard(record: rec)
                            }
                        }
                    }
                }
            }
            .padding(AppSpace.l)
        }
        .navigationBarHidden(true)
    }

    private var weakSubjects: [(label: String, count: Int)] { store.weakSubjects() }

    private var weakSection: some View {
        AppCard(background: AppColor.surfaceElevated) {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColor.accent)
                    Text("자주 틀리는 영역")
                        .font(AppFont.sectionHeader)
                }
                ForEach(weakSubjects, id: \.label) { item in
                    NavigationLink {
                        WeakOXListView(subjectLabel: item.label)
                    } label: {
                        HStack {
                            Text(item.label)
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textPrimary)
                            Spacer()
                            Text("오답 \(item.count)회")
                                .font(AppFont.captionEmphasis)
                                .foregroundStyle(AppColor.danger)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppColor.textTertiary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, AppSpace.m)
                        .background(AppColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct WrongRecordCard: View {
    let record: WrongQuizRecord

    var body: some View {
        AppCard(padding: AppSpace.m, background: AppColor.surfaceElevated) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    AppTag(text: record.caseNumber, color: AppColor.info, background: AppColor.infoSoft)
                    Spacer()
                    Text(record.solvedAt)
                        .font(AppFont.tag)
                        .foregroundStyle(AppColor.textTertiary)
                }
                Text(record.question)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: AppSpace.s) {
                    AppTag(text: "내 답 \(record.userAnswer)", color: AppColor.danger, background: AppColor.dangerSoft)
                    AppTag(text: "정답 \(record.correctAnswer)", color: AppColor.success, background: AppColor.successSoft)
                }
                if !record.explanation.isEmpty {
                    Text(record.explanation)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineSpacing(2)
                }
            }
        }
    }
}

// MARK: =============================================================
// MARK: Case Scan (판례 스캔 — OCR 메인 화면)
// MARK: =============================================================
//
// 본 앱의 핵심 기능. 화면 진입 즉시 "판례 스캔하기" CTA 가 가장 크게 보이며,
// 그 아래에 스캔된 판례 카드들이 시간 역순으로 나열된다.
// 카드 탭 → CaseSummaryView push (요약 + 학습 가이드 + OX 생성).
struct CaseCardsView: View {
    @Query(sort: \ScannedCase.scannedAt, order: .reverse)
    private var scannedCases: [ScannedCase]
    @State private var showOCR = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.l) {
                header
                primaryScanCTA
                if !scannedCases.isEmpty {
                    summaryShortcutCard
                    listSection
                } else {
                    emptyHint
                }
            }
            .padding(AppSpace.l)
            .padding(.bottom, AppSpace.xxl)
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showOCR) {
            NavigationStack {
                OCRView()
                    .withAppBackground()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("핵심 기능")
                    .font(AppFont.tag)
                    .foregroundStyle(AppColor.accent)
                Text("판례 스캔")
                    .font(AppFont.displayTitle)
                    .foregroundStyle(AppColor.textPrimary)
            }
            Spacer()
            if !scannedCases.isEmpty {
                AppTag(text: "보관 \(scannedCases.count)건", color: AppColor.accent, background: AppColor.accentSoft)
            }
        }
        .padding(.top, AppSpace.s)
    }

    /// 화면에서 가장 크고 눈에 띄는 OCR 시작 CTA — 1탭이면 사진 선택 화면 진입.
    private var primaryScanCTA: some View {
        Button { showOCR = true } label: {
            HStack(spacing: AppSpace.l) {
                ZStack {
                    Circle()
                        .fill(AppColor.background.opacity(0.25))
                        .frame(width: 64, height: 64)
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(AppColor.background)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("판례 스캔하기")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AppColor.background)
                    Text("사진을 선택하면 자동으로 분석하고 요약해 드립니다")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.background.opacity(0.75))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.title3.bold())
                    .foregroundStyle(AppColor.background)
            }
            .padding(AppSpace.l)
            .frame(maxWidth: .infinity)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.l, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 가장 최근 스캔 1건의 핵심 정보를 큰 카드로 보여주고 바로 "요약 보기" 진입.
    @ViewBuilder
    private var summaryShortcutCard: some View {
        if let latest = scannedCases.first {
            NavigationLink {
                CaseSummaryView(apiCase: latest.toAPICase())
            } label: {
                AppCard(background: AppColor.surfaceElevated) {
                    VStack(alignment: .leading, spacing: AppSpace.m) {
                        HStack {
                            AppTag(text: "가장 최근", color: AppColor.accent, background: AppColor.accentSoft)
                            Spacer()
                            Text(DateFormatter.shortDate.string(from: latest.scannedAt))
                                .font(AppFont.tag)
                                .foregroundStyle(AppColor.textTertiary)
                        }
                        Text(latest.caseName)
                            .font(AppFont.title)
                            .foregroundStyle(AppColor.textPrimary)
                            .lineLimit(2)
                        if let issue = latest.keyIssue, !issue.isEmpty {
                            labelBlock("핵심 쟁점", text: issue)
                        }
                        if let holding = latest.rulingPoint, !holding.isEmpty {
                            labelBlock("결론", text: holding, color: AppColor.success)
                        }
                        HStack(spacing: 6) {
                            ForEach(latest.keywords.prefix(5), id: \.self) { kw in
                                AppTag(text: kw)
                            }
                            Spacer()
                        }
                        HStack(spacing: 6) {
                            Text("요약 자세히 보기")
                                .font(AppFont.captionEmphasis)
                                .foregroundStyle(AppColor.accent)
                            Image(systemName: "arrow.right")
                                .font(.caption.bold())
                                .foregroundStyle(AppColor.accent)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyHint: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.s) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(AppColor.accent)
                    Text("이렇게 사용하세요")
                        .font(AppFont.sectionHeader)
                }
                stepRow("1", "판례 이미지 1~20장을 한 번에 선택")
                stepRow("2", "자동 분석으로 핵심 쟁점·결론 추출")
                stepRow("3", "한 줄 요약 + OX 변형 문제로 즉시 학습")
            }
        }
    }

    private func stepRow(_ no: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpace.m) {
            Text(no)
                .font(AppFont.captionEmphasis)
                .foregroundStyle(AppColor.background)
                .frame(width: 22, height: 22)
                .background(AppColor.accent)
                .clipShape(Circle())
            Text(text)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labelBlock(_ title: String, text: String, color: Color = AppColor.accent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppFont.tag).foregroundStyle(color)
            Text(text)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var listSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.s) {
            SectionHeader(title: "전체 스캔본", trailing: "최신순 · \(scannedCases.count)건")
            ForEach(scannedCases) { sc in
                NavigationLink {
                    CaseSummaryView(apiCase: sc.toAPICase())
                } label: {
                    HStack(spacing: AppSpace.m) {
                        Image(systemName: "doc.text.fill")
                            .font(.title3)
                            .foregroundStyle(AppColor.accent)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sc.caseName)
                                .font(AppFont.bodyEmphasis)
                                .lineLimit(1)
                                .foregroundStyle(AppColor.textPrimary)
                            Text(sc.keyIssue ?? sc.keywords.prefix(3).joined(separator: " · "))
                                .font(AppFont.caption)
                                .foregroundStyle(AppColor.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(AppColor.textTertiary)
                    }
                    .padding(AppSpace.m)
                    .background(AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.m).stroke(AppColor.separator, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: =============================================================
// MARK: AI Analysis (AI 분석)
// MARK: =============================================================
struct AIAnalysisView: View {
    @EnvironmentObject private var store: ReviewStore
    @StateObject private var studyStore = StudyStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.l) {
                Text("AI 분석")
                    .font(AppFont.displayTitle)
                Text("당신의 약점 패턴과 함정 선택지, 반복 실수를 분석합니다.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)

                summaryCard
                metricsCard
                accuracyChartCard
                weakPatternCard
                confidenceCard
                routineCard
            }
            .padding(AppSpace.l)
        }
        .navigationBarHidden(true)
    }

    private var metricsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                SectionHeader(title: "누적 메트릭")
                HStack(spacing: AppSpace.l) {
                    MetricBlock(value: "\(studyStore.totalSolved)", label: "총 문항")
                    MetricBlock(value: "\(studyStore.totalCorrect)", label: "정답", tint: AppColor.success)
                    MetricBlock(
                        value: studyStore.totalSolved > 0 ? "\(Int(studyStore.overallAccuracy * 100))" : "—",
                        label: "정답률",
                        tint: AppColor.accent,
                        trailingSymbol: studyStore.totalSolved > 0 ? "%" : nil
                    )
                    MetricBlock(value: "\(studyStore.streakDays)", label: "연속", tint: AppColor.info, trailingSymbol: "일")
                }
            }
        }
    }

    private var accuracyChartCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                SectionHeader(title: "최근 7일 정답률")
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(studyStore.recentDays(7)) { rec in
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(AppColor.surfaceElevated)
                                    .frame(width: 26, height: 100)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(rec.solved == 0 ? AppColor.textTertiary.opacity(0.4) : AppColor.accent)
                                    .frame(width: 26, height: max(4, CGFloat(rec.accuracy) * 100))
                            }
                            Text(rec.shortLabel).font(AppFont.tag).foregroundStyle(AppColor.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var summaryCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                SectionHeader(title: "한 줄 진단")
                Text(diagnosis)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(4)
            }
        }
    }

    private var diagnosis: String {
        let acc = studyStore.overallAccuracy
        let total = studyStore.totalSolved
        let weak = store.weakSubjects().first?.label
        if total < 10 {
            return "데이터가 아직 부족합니다. 문제풀이 탭에서 10문항 이상 풀면 본격 분석이 시작됩니다."
        }
        var line = String(format: "전체 정답률 %.0f%% · 누적 %d문항.", acc * 100, total)
        if let w = weak {
            line += " ‘\(w)’ 영역의 반복 실수가 가장 큽니다."
        } else {
            line += " 특정 영역에 편향된 약점은 아직 보이지 않습니다."
        }
        return line
    }

    private var weakPatternCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                SectionHeader(title: "약점 패턴")
                let weak = store.weakSubjects()
                if weak.isEmpty {
                    Text("아직 반복 오답 영역이 없습니다.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                } else {
                    ForEach(weak, id: \.label) { item in
                        HStack {
                            Text(item.label).font(AppFont.body).foregroundStyle(AppColor.textPrimary)
                            Spacer()
                            ProgressView(value: Double(item.count), total: Double(max(item.count, 5)))
                                .tint(AppColor.danger)
                                .frame(width: 100)
                            Text("\(item.count)회")
                                .font(AppFont.captionEmphasis)
                                .foregroundStyle(AppColor.danger)
                        }
                    }
                }
            }
        }
    }

    private var confidenceCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpace.m) {
                SectionHeader(title: "확신도 분석")
                let counts = totalsByConfidence()
                HStack(spacing: AppSpace.l) {
                    ForEach(AnswerConfidence.allCases) { c in
                        VStack(spacing: 4) {
                            Text("\(counts[c.rawValue] ?? 0)").font(AppFont.metricNumber).foregroundStyle(c.color)
                            Text(c.label).font(AppFont.metricLabel).foregroundStyle(AppColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Text(confidenceInsight(counts))
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(3)
            }
        }
    }

    private func totalsByConfidence() -> [String: Int] {
        var totals: [String: Int] = [:]
        for rec in studyStore.dailySolvedRecords {
            for (k, v) in rec.confidenceCounts { totals[k, default: 0] += v }
        }
        return totals
    }

    private func confidenceInsight(_ counts: [String: Int]) -> String {
        let guess = counts[AnswerConfidence.guess.rawValue] ?? 0
        let unsure = counts[AnswerConfidence.unsure.rawValue] ?? 0
        let sure = counts[AnswerConfidence.sure.rawValue] ?? 0
        let total = guess + unsure + sure
        if total == 0 { return "확신도 데이터가 아직 없습니다. 문제풀이에서 확신도를 함께 기록하세요." }
        if guess > sure && guess > unsure {
            return "찍어 맞춘 비율이 큽니다. 정답이라도 다시 풀어 개념을 굳히세요."
        }
        if unsure > sure {
            return "‘애매’ 응답이 많아 개념 정리가 더 필요합니다. 같은 단원 회독을 권장합니다."
        }
        return "확신 응답이 안정적입니다. 새로운 단원으로 범위를 확장하세요."
    }

    private var routineCard: some View {
        AppCard(background: AppColor.surfaceElevated) {
            VStack(alignment: .leading, spacing: AppSpace.s) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .foregroundStyle(AppColor.accent)
                    Text("회독 추천")
                        .font(AppFont.sectionHeader)
                }
                Text(routineSuggestion)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineSpacing(3)
            }
        }
    }

    private var routineSuggestion: String {
        let last7 = studyStore.recentDays(7)
        let solved = last7.reduce(0) { $0 + $1.solved }
        if solved < 50 {
            return "최근 7일 누적 \(solved)문항. 일 30문항 페이스를 회복하면 D-Day 까지 충분히 회독 가능합니다."
        }
        return "최근 7일 \(solved)문항 양호. 새 판례 카드 회독과 OX 변형 풀이를 병행하세요."
    }
}

// MARK: =============================================================
// MARK: Settings Sheet (홈 톱니바퀴 → 모달)
// MARK: =============================================================
//
// 통계 그래프는 AI분석 탭으로 흡수되었으므로 별도 탭이 없다.
// 본 앱은 온디바이스 모드로만 동작하므로 백엔드 URL 같은 설정은 노출하지 않는다.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var studyStore = StudyStore.shared

    @State private var dDayNameInput: String = ""
    @State private var dDayDateInput: Date = Date()
    @State private var goalInput: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("학습 목표") {
                    TextField("D-Day 이름 (예: 경찰공채 1차)", text: $dDayNameInput)
                    DatePicker("시험일", selection: $dDayDateInput, displayedComponents: .date)
                    HStack {
                        Text("일일 목표 문항 수")
                        Spacer()
                        TextField("30", text: $goalInput)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section("동작 모드") {
                    HStack {
                        Image(systemName: "iphone.gen3")
                            .foregroundStyle(.green)
                        Text("온디바이스 모드")
                        Spacer()
                        Text("네트워크 미사용")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("정보") {
                    HStack { Text("앱"); Spacer(); Text("AI SYS").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .fontWeight(.bold)
                }
            }
            .onAppear {
                dDayNameInput = studyStore.dDayName
                dDayDateInput = studyStore.dDayDate
                goalInput = "\(studyStore.dailyGoalQuestions)"
            }
        }
    }

    private func save() {
        let name = dDayNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { studyStore.dDayName = name }
        studyStore.dDayDate = dDayDateInput
        if let v = Int(goalInput), v > 0 { studyStore.dailyGoalQuestions = v }
        dismiss()
    }
}
