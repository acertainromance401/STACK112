import SwiftUI

/// 앱 시작 시 LLM 로딩이 끝날 때까지 노출되는 스플래시.
/// AppIcon 톤(다크 네이비 + 글래스 블루)을 그대로 사용한다.
struct SplashView: View {
    let progress: Double          // 0.0 ~ 1.0
    let message: String?

    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            AppColor.background.ignoresSafeArea()
            LinearGradient(
                colors: [
                    AppColor.glassFillTop.opacity(0.55),
                    AppColor.glassFillBot.opacity(0.35),
                    AppColor.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 0)

                // 로고
                Image("LaunchLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
                    .shadow(color: AppColor.accent.opacity(0.25), radius: 32, x: 0, y: 0)
                    .scaleEffect(pulse ? 1.0 : 0.96)
                    .opacity(pulse ? 1.0 : 0.85)
                    .animation(
                        .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                        value: pulse
                    )

                VStack(spacing: 8) {
                    Text("STACK112")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColor.textPrimary)
                        .tracking(2)

                    Text("공부는 당신이, 기록은 우리가.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AppColor.textSecondary)
                }

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    // 가는 골드 프로그레스
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AppColor.textTertiary.opacity(0.25))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [AppColor.accent, AppColor.accent.opacity(0.6)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(8, geo.size.width * CGFloat(min(max(progress, 0), 1))))
                                .animation(.easeOut(duration: 0.4), value: progress)
                        }
                    }
                    .frame(height: 4)
                    .frame(maxWidth: 220)

                    Text(message ?? "온디바이스 AI 준비 중...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.textTertiary)
                }
                .padding(.bottom, 56)
            }
            .padding(.horizontal, 32)
        }
        .onAppear { pulse = true }
        .transition(.opacity)
    }
}
