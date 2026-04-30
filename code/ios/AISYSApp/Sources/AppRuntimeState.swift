import Foundation

@MainActor
final class AppRuntimeState: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var pendingSearchQuery: String?
    /// OCR로 추출한 텍스트를 임시 판례로 변환해 직접 요약/퀴즈 화면으로 넘길 때 사용
    @Published var pendingOCRCase: APICase?
}
