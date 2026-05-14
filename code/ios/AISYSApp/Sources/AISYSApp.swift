import SwiftUI
import SwiftData

@main
struct AISYSApp: App {
    @StateObject private var store = ReviewStore()
    @StateObject private var runtime = AppRuntimeState()
    @StateObject private var llm = LLMService.shared

    /// 스플래시는 LLM 로딩이 끝났거나 시작 후 최소 1초가 지난 시점에만 사라지게 한다.
    @State private var splashMinElapsed = false
    @State private var hideSplash = false

    let container: ModelContainer = {
        let c = try! ModelContainer(for: ScannedCase.self)
        #if DEBUG
        DemoSeed.seedIfNeeded(context: c.mainContext)
        #endif
        return c
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .environmentObject(store)
                    .environmentObject(runtime)

                if !hideSplash {
                    SplashView(progress: splashProgress, message: splashMessage)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .preferredColorScheme(.dark)
            .tint(AppColor.accent)
            .task {
                await LLMService.shared.loadModelIfNeeded()
                // 약점 키워드 공급원 등록 — OX 퀴즈 프롬프트에 개인화 hint 주입
                LLMService.shared.weakKeywordsProvider = { [weak store] in
                    guard let store else { return [] }
                    return LegalAnalyzer.weakKeywords(from: store.wrongQuizRecords, topK: 3)
                }
            }
            .task {
                // 너무 빠르게 사라지면 깜빡임이 생기므로 최소 노출 시간 보장
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                splashMinElapsed = true
                updateSplashVisibility()
            }
            .onChange(of: llm.state) { _, _ in
                updateSplashVisibility()
            }
        }
        .modelContainer(container)
    }

    private var splashProgress: Double {
        switch llm.state {
        case .idle: return 0.05
        case .loading(let p): return max(0.05, min(0.95, p))
        case .ready, .inferring: return 1.0
        case .error: return 1.0
        }
    }

    private var splashMessage: String? {
        switch llm.state {
        case .idle: return "온디바이스 AI 준비 중..."
        case .loading: return "온디바이스 AI 모델 로딩 중..."
        case .ready, .inferring: return "준비 완료"
        case .error(let msg): return msg
        }
    }

    private func updateSplashVisibility() {
        let ready: Bool
        switch llm.state {
        case .ready, .inferring, .error:
            ready = true
        default:
            ready = false
        }
        if ready && splashMinElapsed {
            withAnimation(.easeOut(duration: 0.35)) {
                hideSplash = true
            }
        }
    }
}

