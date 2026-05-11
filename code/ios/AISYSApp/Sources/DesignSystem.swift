import SwiftUI

// MARK: - Color Palette (Police Navy + Gold)
//
// 디자인 철학: 화려함보다 집중. 다크 네이비 기반, 포인트 컬러 최소화.
// 경찰 상징색(짙은 남색 + 금색)을 채택해 수험생에게 시험·제복 분위기를 환기.
// 모든 화면은 다크모드 기준으로 최적화되며 라이트모드는 자동 변환 대응만 한다.
enum AppColor {
    // 배경 — 깊이 단계별로 3단 (가장 어두운 배경 → 카드 → 카드 hover)
    static let background = Color(red: 0.039, green: 0.078, blue: 0.157)        // #0A1428 짙은 네이비
    static let surface = Color(red: 0.078, green: 0.137, blue: 0.235)           // #14233C 카드
    static let surfaceElevated = Color(red: 0.110, green: 0.180, blue: 0.290)   // #1C2E4A 카드 hover/active

    // 텍스트 — 시인성과 시선피로 균형
    static let textPrimary = Color(red: 0.961, green: 0.973, blue: 0.984)       // #F5F8FB
    static let textSecondary = Color(red: 0.612, green: 0.655, blue: 0.729)     // #9CA7BA
    static let textTertiary = Color(red: 0.412, green: 0.451, blue: 0.518)      // #697384

    // 포인트 — 경찰 금색 (전문성, 절제). 강조는 1화면 1~2회만 사용.
    static let accent = Color(red: 0.961, green: 0.769, blue: 0.094)            // #F5C418 골드
    static let accentSoft = Color(red: 0.961, green: 0.769, blue: 0.094, opacity: 0.18)

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
    static let separator = Color(red: 0.157, green: 0.220, blue: 0.318, opacity: 0.6)
    static let border = Color(red: 0.196, green: 0.275, blue: 0.396)

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
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let pill: CGFloat = 999
}

// MARK: - Reusable UI Components

/// 정보 밀도가 높은 메인 카드. 모든 섹션 컨테이너의 기본형.
struct AppCard<Content: View>: View {
    var padding: CGFloat = AppSpace.l
    var background: Color = AppColor.surface
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.l, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.l, style: .continuous)
                    .stroke(AppColor.separator, lineWidth: 0.5)
            )
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
struct AppBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            AppColor.background.ignoresSafeArea()
            content
        }
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
