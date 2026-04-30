import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: ReviewStore
    @State private var isLoadingDashboard = false
    @State private var dashboardError: String?
    @State private var currentAPIBaseURL = ""
    @State private var showAPISettings = false
    @State private var apiURLInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("복습 대시보드")
                    .font(.largeTitle.bold())
                Text("합격을 위한 오늘의 우선순위 판례입니다.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Label("추천 \(store.recommendedCases.count)건", systemImage: "sparkles")
                    Label("오답 \(store.wrongAnswers.count)건", systemImage: "target")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !currentAPIBaseURL.isEmpty {
                    HStack {
                        Text("API: \(currentAPIBaseURL)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("설정") {
                            apiURLInput = currentAPIBaseURL
                            showAPISettings = true
                        }
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    }
                    .contentShape(Rectangle())
                }

                HStack(spacing: 12) {
                    Button("복습 시작") {}
                        .buttonStyle(.borderedProminent)
                    NavigationLink("판례 검색으로 이동") {
                        SearchView()
                    }
                    .buttonStyle(.bordered)
                }

                Text("오늘의 추천 복습")
                    .font(.title2.bold())
                if isLoadingDashboard {
                    ProgressView("DB 대시보드 동기화 중...")
                        .font(.caption)
                }
                if let dashboardError {
                    Text(dashboardError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("총 \(store.recommendedCases.count)건")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(store.recommendedCases) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.subject)
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                        Text(item.title)
                            .font(.headline)
                        Text("핵심 쟁점: \(item.issue)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("최근 정답률 \(item.accuracy)%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text("최근 오답 노트")
                    .font(.title2.bold())
                Text("총 \(store.wrongAnswers.count)건")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(store.wrongAnswers) { wrong in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(wrong.title)
                            .font(.headline)
                        Text(wrong.memo)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(wrong.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .navigationTitle("AI_SYS")
        .withSmallBackButton()
        .sheet(isPresented: $showAPISettings) {
            NavigationStack {
                Form {
                    Section {
                        TextField("http://192.168.x.x:8000", text: $apiURLInput)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                        
                        HStack {
                            Button("저장") {
                                NetworkService.shared.configureBaseURL(apiURLInput)
                                currentAPIBaseURL = apiURLInput
                                showAPISettings = false
                            }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.borderedProminent)
                            
                            Button("초기화") {
                                NetworkService.shared.configureBaseURL("")
                                currentAPIBaseURL = ""
                                apiURLInput = ""
                                showAPISettings = false
                            }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                        }
                    } header: {
                        Text("API 서버 주소")
                    } footer: {
                        Text("현재 IP: \(currentAPIBaseURL)")
                    }
                }
                .navigationTitle("API 설정")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("닫기") {
                            showAPISettings = false
                        }
                    }
                }
            }
        }
        .task {
            await loadDashboardFromBackendIfNeeded()
        }
    }

    private func loadDashboardFromBackendIfNeeded() async {
        if store.isRemoteDashboardLoaded {
            return
        }

        isLoadingDashboard = true
        defer { isLoadingDashboard = false }

        currentAPIBaseURL = await NetworkService.shared.currentBaseURLString()

        let isHealthy = await NetworkService.shared.healthCheck()
        guard isHealthy else {
            dashboardError = "백엔드 연결 실패: 대시보드 데이터를 불러오지 못했습니다."
            return
        }

        do {
            async let recommended = NetworkService.shared.listRecommendedCases(limit: 7)
            async let wrong = NetworkService.shared.listWrongAnswers(userID: NetworkService.currentUserID(), limit: 20)
            let payload = try await (recommended, wrong)
            store.applyRemoteDashboard(recommended: payload.0, wrong: payload.1)
            dashboardError = nil
        } catch {
            dashboardError = "대시보드 로딩 실패: \(error.localizedDescription)"
        }
    }
}
