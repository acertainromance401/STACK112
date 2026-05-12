import Foundation
import Combine

// MARK: - StudyStore
//
// "오늘의 학습" / 회독 카운트 / D-Day / streak 처럼 일자 기반 메트릭을 보관한다.
// 무거운 저장소(SwiftData) 대신 UserDefaults 만 사용 — 데이터 양이 작고 부팅 속도가 중요.
//
// `ReviewStore` 와는 책임을 분리: 오답 기록은 ReviewStore, 학습량/타이머/스트릭은 여기.
@MainActor
final class StudyStore: ObservableObject {
    static let shared = StudyStore()

    // MARK: - 영속 필드
    @Published var dDayName: String { didSet { defaults.set(dDayName, forKey: K.dDayName) } }
    @Published var dDayDate: Date { didSet { defaults.set(dDayDate, forKey: K.dDayDate) } }
    @Published var dailyGoalQuestions: Int { didSet { defaults.set(dailyGoalQuestions, forKey: K.dailyGoal) } }
    @Published var dailySolvedRecords: [DailyRecord] {
        didSet { persistDaily() }
    }

    // MARK: - 파생 메트릭
    var dDay: Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: dDayDate)
        return cal.dateComponents([.day], from: start, to: target).day ?? 0
    }

    var todayKey: String { Self.dayKey(Date()) }

    var todaySolved: Int {
        dailySolvedRecords.first { $0.day == todayKey }?.solved ?? 0
    }

    var todayCorrect: Int {
        dailySolvedRecords.first { $0.day == todayKey }?.correct ?? 0
    }

    var todayWrong: Int { max(0, todaySolved - todayCorrect) }

    /// 오늘 진행률 (0...1) — daily goal 기준
    var todayProgress: Double {
        guard dailyGoalQuestions > 0 else { return 0 }
        return min(1.0, Double(todaySolved) / Double(dailyGoalQuestions))
    }

    /// 연속 학습 streak — 가장 최근일부터 거꾸로 보며 solved>0 인 날짜 연속 개수.
    var streakDays: Int {
        let cal = Calendar.current
        var date = cal.startOfDay(for: Date())
        var count = 0
        // 오늘 0건이면 streak 는 "어제까지" 기준
        let recordsByDay: [String: DailyRecord] = Dictionary(uniqueKeysWithValues: dailySolvedRecords.map { ($0.day, $0) })
        // 오늘 학습이 없으면 어제부터
        if (recordsByDay[Self.dayKey(date)]?.solved ?? 0) == 0 {
            date = cal.date(byAdding: .day, value: -1, to: date) ?? date
        }
        while let rec = recordsByDay[Self.dayKey(date)], rec.solved > 0 {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        }
        return count
    }

    var totalSolved: Int { dailySolvedRecords.reduce(0) { $0 + $1.solved } }
    var totalCorrect: Int { dailySolvedRecords.reduce(0) { $0 + $1.correct } }
    var overallAccuracy: Double {
        guard totalSolved > 0 else { return 0 }
        return Double(totalCorrect) / Double(totalSolved)
    }

    // MARK: - 기록 API

    /// 한 문제 풀이 결과를 기록한다. 문제풀이/OX 채점 직후 호출.
    func recordAnswer(correct: Bool, confidence: AnswerConfidence) {
        let key = todayKey
        if let idx = dailySolvedRecords.firstIndex(where: { $0.day == key }) {
            dailySolvedRecords[idx].solved += 1
            if correct { dailySolvedRecords[idx].correct += 1 }
            dailySolvedRecords[idx].confidenceCounts[confidence.rawValue, default: 0] += 1
        } else {
            var rec = DailyRecord(day: key)
            rec.solved = 1
            rec.correct = correct ? 1 : 0
            rec.confidenceCounts = [confidence.rawValue: 1]
            dailySolvedRecords.append(rec)
        }
    }

    /// 일별 정답률(최근 N일) — 통계 그래프 용도.
    func recentDays(_ n: Int) -> [DailyRecord] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay: [String: DailyRecord] = Dictionary(uniqueKeysWithValues: dailySolvedRecords.map { ($0.day, $0) })
        var out: [DailyRecord] = []
        for offset in stride(from: n - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Self.dayKey(d)
            out.append(byDay[key] ?? DailyRecord(day: key))
        }
        return out
    }

    // MARK: - Private
    private let defaults = UserDefaults.standard

    private enum K {
        static let dDayName = "studyStore.dDayName"
        static let dDayDate = "studyStore.dDayDate"
        static let dailyGoal = "studyStore.dailyGoal"
        static let daily = "studyStore.dailyRecords"
    }

    private init() {
        self.dDayName = defaults.string(forKey: K.dDayName) ?? "경찰공채 1차"
        if let storedDate = defaults.object(forKey: K.dDayDate) as? Date {
            self.dDayDate = storedDate
        } else {
            // 기본: 90일 뒤
            self.dDayDate = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
        }
        let goal = defaults.integer(forKey: K.dailyGoal)
        self.dailyGoalQuestions = goal > 0 ? goal : 30
        if let data = defaults.data(forKey: K.daily),
           let decoded = try? JSONDecoder().decode([DailyRecord].self, from: data) {
            self.dailySolvedRecords = decoded
        } else {
            self.dailySolvedRecords = []
        }
    }

    private func persistDaily() {
        if let data = try? JSONEncoder().encode(dailySolvedRecords) {
            defaults.set(data, forKey: K.daily)
        }
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - DailyRecord
struct DailyRecord: Codable, Identifiable {
    var day: String                  // "yyyy-MM-dd"
    var solved: Int = 0
    var correct: Int = 0
    var confidenceCounts: [String: Int] = [:]   // "sure"/"unsure"/"guess" → count

    var id: String { day }
    var accuracy: Double { solved > 0 ? Double(correct) / Double(solved) : 0 }

    var shortLabel: String {
        // "MM/dd"
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "\(parts[1])/\(parts[2])"
    }
}
