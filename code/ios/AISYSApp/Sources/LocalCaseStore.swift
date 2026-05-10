import Foundation

/// 앱 전체에서 공유되는 "로컬 판례 풀" 싱글톤.
///
/// 백엔드를 제거하고 모든 검색/유사판례 조회를 온디바이스에서 처리하기 위한
/// in-memory corpus 입니다. SearchView/ReviewView 같은 SwiftData 화면에서
/// `update(scanned:)` 로 ScannedCase 풀이 갱신될 때마다 동기화됩니다.
///
/// 또한 번들 탑재된 시드 판례(`seed_cases.json`, 선택적)를 함께 합쳐서
/// 빈 상태에서도 검색이 동작하도록 합니다.
final class LocalCaseStore: @unchecked Sendable {
    static let shared = LocalCaseStore()

    private let lock = NSLock()
    /// 검색용 corpus (issueSummary 에 OCR 원문 일부 포함)
    private var scannedSearchable: [APICase] = []
    /// UI 표시용 corpus (원문 미포함, detail 화면에서 사용)
    private var scannedDisplay: [APICase] = []
    private var seed: [APICase] = []

    private init() {
        self.seed = Self.loadBundleSeed()
    }

    /// 검색 시 사용하는 풀 (raw 가 합쳐진 issueSummary 포함)
    var searchCorpus: [APICase] {
        lock.lock(); defer { lock.unlock() }
        return scannedSearchable + seed
    }

    /// UI 표시용 풀 (검색 결과 클릭 시 detail 로 라우팅할 때 매핑)
    var displayCorpus: [APICase] {
        lock.lock(); defer { lock.unlock() }
        return scannedDisplay + seed
    }

    /// 호환 alias — 기존 호출(searchCases/listCases) 에선 검색용 풀 사용
    var allCases: [APICase] { searchCorpus }

    /// 스캔된 풀 동기화. searchable / display 두 가지를 함께 받는다.
    func updateScanned(searchable: [APICase], display: [APICase]) {
        lock.lock(); defer { lock.unlock() }
        scannedSearchable = searchable
        scannedDisplay = display
    }

    /// 단일 인자 호환 — display 와 search 가 동일한 경우(시드 등) 사용
    func updateScanned(_ cases: [APICase]) {
        updateScanned(searchable: cases, display: cases)
    }

    /// 사건번호 또는 id 로 단일 케이스 조회 (display 우선)
    func find(caseNumber: String) -> APICase? {
        let pool = displayCorpus
        return pool.first { $0.caseNumber == caseNumber || $0.id == caseNumber }
    }

    // MARK: - Seed Loading

    private static func loadBundleSeed() -> [APICase] {
        guard let url = Bundle.main.url(forResource: "seed_cases", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode([APICase].self, from: data)) ?? []
    }
}
