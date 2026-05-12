import SwiftUI

// MARK: - 새 RootTabView (5탭 구조)
//
// iOS TabView는 5탭 초과 시 "More" 메뉴로 자동 축소되어 UX가 망가진다.
// 따라서 5탭으로 유지하고, "통계"는 AI분석 화면 + 홈 설정으로 분산 흡수한다.
// "판례 스캔" 탭이 OCR 메인 진입점이며 앱의 핵심 기능이다.
//
// 탭 구조:
//   0. 홈        — 오늘의 학습, D-Day, 추천 복습, 약점, AI 루틴, 설정 진입
//   1. 판례 스캔  — OCR로 판례 인식 → 자동 IR 분석 → 카드 회독 (메인 기능)
//   2. 문제풀이   — OX 풀이 (확신도 입력 → AI 약점 분석)
//   3. 오답노트   — 자동 분류, 반복 추적
//   4. AI분석    — 약점 패턴 + 정답률 차트 + 회독 추천
//
struct RootTabView: View {
    @EnvironmentObject private var runtime: AppRuntimeState

    var body: some View {
        TabView(selection: $runtime.selectedTab) {
            tab(0, label: "홈", icon: "house.fill") { HomeView() }
            tab(1, label: "판례 스캔", icon: "doc.text.viewfinder") { CaseCardsView() }
            tab(2, label: "문제풀이", icon: "square.and.pencil") { PracticeView() }
            tab(3, label: "오답노트", icon: "exclamationmark.bubble.fill") { WrongNoteView() }
            tab(4, label: "AI분석", icon: "brain.head.profile") { AIAnalysisView() }
        }
        .tint(AppColor.accent)
        .toolbarBackground(AppColor.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
    }

    @ViewBuilder
    private func tab<Content: View>(_ tag: Int, label: String, icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .withAppBackground()
                .toolbarBackground(AppColor.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .tabItem { Label(label, systemImage: icon) }
        .tag(tag)
    }
}
