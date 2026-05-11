import SwiftUI

// MARK: - 새 RootTabView (6탭 구조)
//
// 디자인 철학: 수험생이 앱을 열자마자 "오늘 할 일"이 보이고, 클릭 3회 이내에 학습을 시작.
//
// 탭 구조:
//   0. 홈        — 오늘의 학습, 진행률, 약점, D-Day
//   1. 문제풀이   — OX·객관식 풀이 (확신도 기록 → AI 약점 분석에 활용)
//   2. 오답노트   — 자동 분류·반복 추적·요약 비교
//   3. 판례카드   — 압축 카드형 판례 (스와이프), OCR 진입점
//   4. AI분석    — 약점 패턴/함정/단원 붕괴/회독 추천
//   5. 통계      — 정답률·기억유지·회독·streak + 설정 진입점
//
struct RootTabView: View {
    @EnvironmentObject private var runtime: AppRuntimeState

    var body: some View {
        TabView(selection: $runtime.selectedTab) {
            tab(0, label: "홈", icon: "house.fill") { HomeView() }
            tab(1, label: "문제풀이", icon: "square.and.pencil") { PracticeView() }
            tab(2, label: "오답노트", icon: "exclamationmark.bubble.fill") { WrongNoteView() }
            tab(3, label: "판례카드", icon: "rectangle.stack.fill") { CaseCardsView() }
            tab(4, label: "AI분석", icon: "brain.head.profile") { AIAnalysisView() }
            tab(5, label: "통계", icon: "chart.bar.xaxis") { StatsView() }
        }
        .tint(AppColor.accent)
        .toolbarBackground(AppColor.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    @ViewBuilder
    private func tab<Content: View>(_ tag: Int, label: String, icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .withAppBackground()
        }
        .tabItem { Label(label, systemImage: icon) }
        .tag(tag)
    }
}
