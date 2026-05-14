import SwiftUI

// MARK: - Color Palette (Glass Navy + Gold Hairline)
//
// 디자인 철학: 화려함보다 집중. AppIcon 의 "글래스 블록 + 골드 윤곽" 메타포를
// 앱 본체로 확장. 다크 네이비 기반에 카드는 반투명 글래스, 강조는 골드 1px hairline.
// 골드 fill 은 핵심 CTA·STACK 카운터 같은 1화면 1~2회 한정.
enum AppColor {
    // 배경 — 깊이 단계별로 3단 (가장 어두운 배경 → 카드 → 카드 hover)
    static let background = Color(red: 0.039, green: 0.078, blue: 0.157)        // #0A1428 짙은 네이비
    // surface / surfaceElevated 는 글래스 배경 위에 떠 있는 단색 카드.
    // 그림자로 입체감을 만들기 위해 배경보다 살짝 밝은 톤.
    static let surface = Color(red: 0.094, green: 0.180, blue: 0.298)           // #182E4C
    static let surfaceElevated = Color(red: 0.137, green: 0.227, blue: 0.357)   // #233A5B

    // 글래스 카드 그라데이션 (AppIcon 블록 톤과 동일 계열)
    static let glassFillTop = Color(red: 0.196, green: 0.314, blue: 0.510)      // #325082
    static let glassFillBot = Color(red: 0.078, green: 0.157, blue: 0.290)      // #14284A
    static let glassHighlight = Color.white.opacity(0.06)                       // 상단 광택

    // 텍스트 — 시인성과 시선피로 균형
    static let textPrimary = Color(red: 0.961, green: 0.973, blue: 0.984)       // #F5F8FB
    static let textSecondary = Color(red: 0.643, green: 0.690, blue: 0.769)     // #A4B0C4
    static let textTertiary = Color(red: 0.435, green: 0.486, blue: 0.561)      // #6F7C8F

    // 포인트 — 경찰 금색. fill 대신 hairline / 핵심 숫자에만 사용.
    static let accent = Color(red: 0.961, green: 0.769, blue: 0.094)            // #F5C418 골드
    static let accentSoft = Color(red: 0.961, green: 0.769, blue: 0.094, opacity: 0.10) // fill 약화
    static let goldHairline = Color(red: 0.961, green: 0.769, blue: 0.094, opacity: 0.55) // 카드 윤곽

    // 의미적 컬러 — 채도 낮춰 시선 피로 완화
    static let danger = Color(red: 0.820, green: 0.298, blue: 0.298)            // #D14C4C
    static let dangerSoft = Color(red: 0.820, green: 0.298, blue: 0.298, opacity: 0.18)
    static let success = Color(red: 0.314, green: 0.671, blue: 0.435)           // #50AB6F
    static let successSoft = Color(red: 0.314, green: 0.671, blue: 0.435, opacity: 0.18)
    static let info = Color(red: 0.310, green: 0.561, blue: 0.882)              // #4F8FE1
    static let infoSoft = Color(red: 0.310, green: 0.561, blue: 0.882, opacity: 0.18)
    static let warning = Color(red: 0.929, green: 0.604, blue: 0.220)           // #ED9A38
    static let warningSoft = Color(red: 0.929, green: 0.604, blue: 0.220, opacity: 0.18)

    // 경계선
    static let separator = Color(red: 0.176, green: 0.255, blue: 0.376, opacity: 0.5)
    static let border = Color(red: 0.235, green: 0.318, blue: 0.451)

    // 확신도 컬러 — 문제풀이에서 "확실/애매/찍음" 시각화용
    static let confidenceHigh = Color(red: 0.314, green: 0.671, blue: 0.435)
    static let confidenceMid = Color(red: 0.961, green: 0.769, blue: 0.094)
    static let confidenceLow = Color(red: 0.820, green: 0.298, blue: 0.298)
}

// MARK: - Typography
//
// 시스템 폰트(SF Pro / Apple SD Gothic Neo) 기반.
// 정보 밀도를 높이되 본문은 1.4 line-height 로 가독성 확보.
enum AppFont {
    static let displayTitle = Font.system(size: 28, weight: .bold, design: .rounded)
    static let title = Font.system(size: 22, weight: .bold)
    static let sectionHeader = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 15, weight: .regular)
    static let bodyEmphasis = Font.system(size: 15, weight: .semibold)
    static let caption = Font.system(size: 13, weight: .regular)
    static let captionEmphasis = Font.system(size: 13, weight: .semibold)
    static let metricNumber = Font.system(size: 28, weight: .heavy, design: .rounded)
    static let metricLabel = Font.system(size: 12, weight: .medium)
    static let tag = Font.system(size: 11, weight: .semibold)
}

// MARK: - Spacing & Radius
enum AppSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum AppRadius {
    static let s: CGFloat = 10
    static let m: CGFloat = 14
    static let l: CGFloat = 22
    static let xl: CGFloat = 28
    static let pill: CGFloat = 999
}

// MARK: - Reusable UI Components

/// 정보 밀도가 높은 메인 카드. 모든 섹션 컨테이너의 기본형.
///
/// 리테마 v1.1: 배경이 글래스 블루를 입고 카드는 단색 짙은 네이비로 돌아간다.
/// - 카드 fill: `surface` 단색 (#15263F)
/// - 카드 윤곽: 옅은 골드 hairline 1px (`goldHairline` 35% 로 약화)
/// - 그라데이션 카드가 필요하면 background 파라미터로 override
struct AppCard<Content: View>: View {
    var padding: CGFloat = AppSpace.l
    /// nil 이면 기본 단색 surface. 명시 시 해당 색으로 override.
    var background: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background ?? AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.l, style: .continuous))
            // 윤곽선 제거, 부드러운 그림자로만 입체감 (iOS 17 모던 스타일)
            // 스플래시 로고와 동일한 골드 halo 톤(accent 12%)을 카드 뒤에 옅게 깔아
            // 모든 탭의 컨테이너가 같은 디자인 언어를 공유하도록 한다.
            .shadow(color: AppColor.accent.opacity(0.25), radius: 24, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 6)
            .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
    }
}

/// 큰 숫자 + 라벨 한 쌍. 홈 위젯·통계 카드 등에 사용.
struct MetricBlock: View {
    let value: String
    let label: String
    var tint: Color = AppColor.textPrimary
    var trailingSymbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(AppFont.metricNumber)
                    .foregroundStyle(tint)
                if let trailingSymbol {
                    Text(trailingSymbol)
                        .font(AppFont.captionEmphasis)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            Text(label)
                .font(AppFont.metricLabel)
                .foregroundStyle(AppColor.textSecondary)
        }
    }
}

/// 짧은 메타 정보 표시용 태그. 가로 스택으로 여러 개 나열한다.
struct AppTag: View {
    let text: String
    var color: Color = AppColor.accent
    var background: Color = AppColor.accentSoft

    var body: some View {
        Text(text)
            .font(AppFont.tag)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.s, style: .continuous))
    }
}

/// 섹션 제목 + 우측 액션 라벨. 정보 위계를 빠르게 인지하게 한다.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppFont.sectionHeader)
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
    }
}

/// 화면 배경에 전역 적용하는 modifier.
///
/// 리테마 v2.0: 순흑 배경 + 좌상단 옅은 앰버 그라데이션 글로우 + 하단 골드 글로우.
/// 첨부 이미지 톤처럼 어두운 베이스에 따뜻한 포인트만 은은하게 깐다.
struct AppBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            // 1) 순흑 베이스
            AppColor.background.ignoresSafeArea()
            // 2) 좌상단 앰버 라이트 — 첨부 이미지의 따뜻한 하이라이트 재현
            RadialGradient(
                colors: [
                    AppColor.glassFillTop.opacity(0.55),
                    AppColor.background.opacity(0)
                ],
                center: UnitPoint(x: 0.05, y: -0.05),
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            // 3) 하단 미세한 골드 글로우 — CTA 영역 시선 유도
            RadialGradient(
                colors: [
                    AppColor.accent.opacity(0.10),
                    AppColor.background.opacity(0)
                ],
                center: UnitPoint(x: 0.5, y: 1.05),
                startRadius: 0,
                endRadius: 320
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            content
        }
    }
}

// MARK: - Primary CTA Button
//
// 첨부 이미지 하단의 큰 알약형 골드 CTA를 재사용 가능한 컴포넌트로 추출.
// "오늘의 문제 시작 →" 같은 1화면 1개의 핵심 액션에 사용.
struct AppPrimaryButton: View {
    let title: String
    var systemImage: String = "arrow.right"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Spacer()
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .bold))
                }
            }
            .foregroundStyle(Color.black)
            .padding(.vertical, 18)
            .padding(.horizontal, 22)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
            .shadow(color: AppColor.accent.opacity(0.35), radius: 18, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// 모든 메인 탭 화면에 적용해 일관된 배경 + 텍스트 색을 유지한다.
    func withAppBackground() -> some View {
        modifier(AppBackground())
            .foregroundStyle(AppColor.textPrimary)
            .tint(AppColor.accent)
    }
}

// MARK: - Confidence (문제풀이 확신도)
//
// AI 가 "찍어서 맞춘 문제" 도 약점으로 분류할 수 있도록 사용자 자기보고를 받는다.
enum AnswerConfidence: String, Codable, CaseIterable, Identifiable {
    case sure       // 확실히 앎
    case unsure     // 애매함
    case guess      // 찍음

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sure: return "확실"
        case .unsure: return "애매"
        case .guess: return "찍음"
        }
    }

    var color: Color {
        switch self {
        case .sure: return AppColor.confidenceHigh
        case .unsure: return AppColor.confidenceMid
        case .guess: return AppColor.confidenceLow
        }
    }

    var systemImage: String {
        switch self {
        case .sure: return "checkmark.seal.fill"
        case .unsure: return "questionmark.circle.fill"
        case .guess: return "die.face.5.fill"
        }
    }
}
