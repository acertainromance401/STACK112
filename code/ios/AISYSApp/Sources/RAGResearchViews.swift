import SwiftUI
import UniformTypeIdentifiers

struct RAGJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct RAGAnalysisView: View {
    let caseItem: APICase
    let rawText: String?
    @State private var question = "현재 쟁점과 참고 판례를 구분해 설명."
    @State private var mode: RAGRetrievalMode = .hybrid
    @State private var task: RAGAnalysisTask = .analysis
    @State private var record: RAGRunRecord?
    @State private var operation: Task<Void, Never>?
    @State private var error: String?
    @State private var exportData = RAGJSONDocument(data: Data())
    @State private var exporting = false
    @State private var reviewer = ""
    @State private var supportedClaims = 0

    var body: some View {
        Form {
            Section("원문 근거 분석 · 기존 카드와 별도") {
                Text(caseItem.caseName).font(.headline)
                Text("인용·숫자·문구 겹침 검사는 법률 판단의 정확성을 보장하지 않습니다. 원문과 직접 대조해 주세요.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("분석 질문", text: $question, axis: .vertical)
                    .disabled(operation != nil)
                Picker("생성 작업", selection: $task) {
                    ForEach(RAGAnalysisTask.allCases) { Text($0.label).tag($0) }
                }.disabled(operation != nil)
                Picker("검색 방식", selection: $mode) {
                    ForEach(RAGRetrievalMode.allCases) { Text($0.label).tag($0) }
                }.disabled(operation != nil)
                if operation == nil {
                    Button("근거 검색 및 분석", systemImage: "text.magnifyingglass") { analyze() }
                } else {
                    ProgressView("기기에서 분석 중")
                    Button("중단", role: .destructive) { operation?.cancel() }
                }
            }
            if let error { Section("실행 알림") { Text(error).foregroundStyle(.red) } }
            if let record {
                Section("생성 결과") {
                    Text("\(record.task.label) · \(record.question)").font(.caption)
                    Text(record.outputSuccess ? "인용 형식 검사 통과" : "생성/인용 형식 검사 실패")
                        .font(.headline)
                    if let failure = record.failureReason { Text(failure).foregroundStyle(.red) }
                    Text(record.generation?.output ?? "모델 생성 결과 없음").textSelection(.enabled)
                    if record.quizDraft != nil {
                        Text("별도의 검수 전 OX 초안입니다. 기존 퀴즈·오답노트에는 자동 반영하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("요청: \(record.search.requestedMode.label) · 실제: \(record.search.effectiveMode.label)")
                        .font(.caption)
                    if let model = record.search.semanticModelIdentity["model"] {
                        Text("의미 모델: \(model) · 768차원 / mean / L2").font(.caption)
                    }
                    ForEach(record.search.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    if !record.outputSuccess {
                        Text("아래 발췌는 검색된 원문입니다. 대체 생성 답변이 아니며 모델 성공으로 집계하지 않습니다.")
                            .font(.caption)
                    }
                }
                Section(record.generation == nil ? "검색 근거 · 모델 미전달" : "모델에 전달한 근거") {
                    ForEach(record.evidence) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("[\(source.id)] \(source.chunk.title)").font(.headline)
                            Text("\(source.chunk.caseNumber) · \(source.chunk.sourceKind)").font(.caption)
                            Text("UTF-16 \(source.chunk.startUTF16)..<\(source.chunk.endUTF16)")
                                .font(.caption.monospaced())
                            Text(source.chunk.text).textSelection(.enabled)
                            Text("원문 SHA-256: \(source.chunk.documentFingerprint)").font(.caption2).textSelection(.enabled)
                            if let text = originalText(for: source.chunk) {
                                DisclosureGroup("원문 전체 대조") { Text(text).font(.caption).textSelection(.enabled) }
                            }
                            if let value = source.chunk.sourceURL, let url = URL(string: value),
                               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                                Link("출처 열기", destination: url)
                            }
                        }
                    }
                }
                if !record.claims.isEmpty {
                    Section("문장별 기초 검사 · 의미적 함의 검증 아님") {
                        ForEach(record.claims) { claim in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(claim.text)
                                Text("인용 \(claim.citationIDs.joined(separator: ", ")) · 문구 겹침 \(Int(claim.lexicalCoverage * 100))%")
                                    .font(.caption)
                                if !claim.unknownCitationIDs.isEmpty { Text("알 수 없는 인용 ID").foregroundStyle(.red) }
                                if !claim.unsupportedNumbers.isEmpty {
                                    Text("근거에 없는 숫자: \(claim.unsupportedNumbers.joined(separator: ", "))").foregroundStyle(.orange)
                                }
                                if claim.quotedTextMatches == false { Text("따옴표 인용 불일치").foregroundStyle(.orange) }
                            }
                        }
                    }
                    Section("사람 검수") {
                        TextField("검수자 식별자", text: $reviewer)
                        Stepper("근거가 지지하는 문장 \(supportedClaims)/\(record.claims.count)", value: $supportedClaims, in: 0...record.claims.count)
                        Button("검수 기록 반영") {
                            do {
                                var updated = record
                                try updated.review(reviewer: reviewer, supportedClaims: supportedClaims)
                                self.record = updated
                            } catch { self.error = error.localizedDescription }
                        }
                        if let review = record.humanReview { Text("기록됨: \(review.reviewer)").font(.caption) }
                    }
                }
                Section("실행 기록") {
                    if record.environment == "physical_device" {
                        Text("검색 \(record.retrievalMS, specifier: "%.0f")ms · 모델 준비 \(record.modelPreparationMS, specifier: "%.0f")ms")
                        if let trace = record.generation {
                            Text("생성 \(trace.inferenceMS, specifier: "%.0f")ms · \(trace.attempts)회 시도")
                        }
                        if let peak = record.memory.sampledPeakMB { Text("프로세스 표본 최대 \(peak, specifier: "%.1f")MB") }
                        if let failure = record.memory.error { Text(failure).foregroundStyle(.orange) }
                    } else {
                        Text("시뮬레이터 기능 확인입니다. 실기기 성능 결과로 사용하지 마세요.")
                    }
                    Text(record.generation?.engine ?? "생성 엔진 미실행").font(.caption)
                    Button("실행 JSON 내보내기") { export(record) }
                    Text("내보내기에는 원문 발췌가 포함됩니다. 외부 공유 전 개인정보를 확인하세요.").font(.caption)
                }
            }
            Section {
                NavigationLink("논문용 RAG 평가", destination: RAGEvaluationView())
                DisclosureGroup("임베딩 모델 · MIT 라이선스") {
                    if let url = Bundle.main.url(forResource: "E5-MIT-LICENSE", withExtension: "txt") {
                        Text(licenseText(url)).font(.caption).textSelection(.enabled)
                    } else { Text("임베딩 라이선스 리소스가 없습니다. 배포 전에 확인해 주세요.").foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("근거 분석")
        .onDisappear { operation?.cancel() }
        .fileExporter(isPresented: $exporting, document: exportData, contentType: .json, defaultFilename: "rag-run") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
    }

    private func analyze() {
        error = nil
        record = nil
        supportedClaims = 0
        let target = RAGDocument.resolve(caseItem: caseItem, rawText: rawText, documents: LocalCaseStore.shared.snapshot().documents)
        operation = Task { @MainActor in
            defer { operation = nil }
            do { record = try await RAGResearchService().run(target: target, question: question, mode: mode, task: task) }
            catch is CancellationError { error = "분석을 중단했습니다. 성공 결과로 집계하지 않습니다." }
            catch { self.error = error.localizedDescription }
        }
    }

    private func originalText(for chunk: RAGChunk) -> String? {
        let target = RAGDocument(caseItem: caseItem, rawText: rawText)
        let documents = [target] + LocalCaseStore.shared.snapshot().documents
        return documents.first { $0.id == chunk.documentID && $0.fingerprint == chunk.documentFingerprint }?.text
    }

    private func export(_ record: RAGRunRecord) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            exportData = RAGJSONDocument(data: try encoder.encode(RAGRunExport(run: record)))
            exporting = true
        } catch { self.error = error.localizedDescription }
    }

    private func licenseText(_ url: URL) -> String {
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch { return "라이선스 읽기 실패: \(error.localizedDescription)" }
    }
}

struct RAGEvaluationView: View {
    @State private var dataset: RAGEvaluationDataset?
    @State private var report: RAGEvaluationReport?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportData = RAGJSONDocument(data: Data())
    @State private var repetitions = 3
    @State private var selectedModes = Set(RAGRetrievalMode.allCases)
    @State private var operation: Task<Void, Never>?
    @State private var progress = ""
    @State private var error: String?
    @State private var reviewer = ""
    @State private var reviewCounts: [UUID: Int] = [:]

    var body: some View {
        Form {
            Section("평가 데이터") {
                Text("합성 데이터는 파이프라인 점검 전용입니다. 실제 판례 정확도나 논문 성능의 증거가 아닙니다.")
                    .font(.caption)
                Button("합성 평가셋 불러오기") {
                    do { dataset = try .bundledSynthetic(); report = nil; error = nil }
                    catch { self.error = error.localizedDescription }
                }
                Button("JSON 평가셋 가져오기") { importing = true }
                if let dataset {
                    Text("\(dataset.id) · \(dataset.kind)")
                    Text("문서 \(dataset.documents.count)개 · 질문 \(dataset.queries.count)개")
                    Text(dataset.provenance).font(.caption)
                    Button("평가셋 JSON 내보내기 · 양식으로 사용") {
                        do {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            exportData = RAGJSONDocument(data: try encoder.encode(dataset))
                            exporting = true
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }.disabled(operation != nil)
            Section("실기기 반복 평가") {
                ForEach(RAGRetrievalMode.allCases) { mode in
                    Toggle(mode.label, isOn: Binding(
                        get: { selectedModes.contains(mode) },
                        set: { enabled in
                            if enabled { selectedModes.insert(mode) } else { selectedModes.remove(mode) }
                        }
                    )).disabled(operation != nil)
                }
                Stepper("질문·모드별 \(repetitions)회", value: $repetitions, in: 1...20).disabled(operation != nil)
                Text("검색 없음 / 키워드 / 하이브리드를 비교합니다. 실제 사용 모드와 모델 로드 여부를 각각 기록합니다.")
                    .font(.caption)
                Text("독립 메모리 비교는 앱을 새로 실행하고 모드 하나만 선택해 측정하세요. 여러 모드 배치에서는 모델이 프로세스에 남습니다.")
                    .font(.caption)
                #if targetEnvironment(simulator)
                Text("성능 평가는 iPhone 실기기에서만 실행할 수 있습니다.")
                #else
                if operation == nil {
                    Button("평가 실행") { evaluate() }.disabled(dataset == nil || selectedModes.isEmpty)
                }
                #endif
                if operation != nil {
                    ProgressView(progress)
                    Button("평가 중단", role: .destructive) { operation?.cancel() }
                }
            }
            if let error { Section("알림") { Text(error).foregroundStyle(.red) } }
            if let report {
                Section("결과") {
                    Text("출력 성공 \(report.outputSuccessRate.map { String(format: "%.1f%%", $0 * 100) } ?? "미측정")")
                    ForEach(report.summaries, id: \.mode) { summary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.mode.label).font(.headline)
                            Text("실제 모드 일치 \(summary.effectiveModeMatchCount)/\(summary.sampleCount)")
                            Text("P@3 \(value(summary.meanPrecisionAt3)) · R@3 \(value(summary.meanRecallAt3)) · MRR \(value(summary.mrrAt3))")
                            Text("기초 근거 검사 \(value(summary.basicGroundingProxy)) · 사람 근거성 \(value(summary.humanGroundingRate))")
                            if let ms = summary.inferenceMedianMS { Text("생성 p50 \(ms, specifier: "%.0f")ms") }
                            if let mb = summary.sampledPeakProcessMB { Text("프로세스 표본 최대 \(mb, specifier: "%.1f")MB") }
                        }.font(.caption)
                    }
                    Button("원자료 + 집계 JSON 내보내기") {
                        do { exportData = RAGJSONDocument(data: try report.encoded()); exporting = true }
                        catch { self.error = error.localizedDescription }
                    }
                    Text("전체 평가셋·원문 발췌가 포함됩니다. 공유 전 비식별화하세요.").font(.caption)
                }
                Section("생성 원자료 및 사람 검수") {
                    TextField("검수자 식별자", text: $reviewer)
                    ForEach(report.samples) { sample in
                        DisclosureGroup("\(sample.queryID) · \(sample.run.search.requestedMode.label) · \(sample.repetition)회") {
                            Text(sample.run.question)
                            Text(sample.run.generation?.output ?? sample.run.failureReason ?? "생성 결과 없음").textSelection(.enabled)
                            if let failure = sample.run.failureReason { Text(failure).foregroundStyle(.red) }
                            ForEach(sample.run.evidence) { source in
                                Text("[\(source.id)] \(source.chunk.caseNumber)\n\(source.chunk.text)").font(.caption).textSelection(.enabled)
                            }
                            if !sample.run.claims.isEmpty {
                                Stepper("지지 문장 \(reviewCounts[sample.id, default: 0])/\(sample.run.claims.count)",
                                        value: reviewBinding(sample.id), in: 0...sample.run.claims.count)
                                Button("검수 반영") { review(sample) }
                                if let review = sample.run.humanReview {
                                    Text("검수됨: \(review.reviewer) · \(review.supportedClaims)/\(review.totalClaims)").font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("RAG 평가")
        .onDisappear { operation?.cancel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let imported = try JSONDecoder().decode(RAGEvaluationDataset.self, from: Data(contentsOf: url))
                try imported.validate()
                dataset = imported
                report = nil
                reviewCounts = [:]
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportData, contentType: .json, defaultFilename: "rag-evaluation") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
    }

    private func evaluate() {
        guard let dataset else { error = "평가셋을 먼저 선택해 주세요."; return }
        error = nil
        report = nil
        reviewCounts = [:]
        operation = Task { @MainActor in
            defer { operation = nil }
            do {
                report = try await RAGEvaluator.run(
                    dataset: dataset, repetitions: repetitions, modes: RAGRetrievalMode.allCases.filter { selectedModes.contains($0) },
                    service: RAGResearchService()
                ) {
                    progress = "\($0)/\($1)"
                }
            } catch is CancellationError { error = "평가를 중단했습니다. 미완료 배치는 집계하지 않습니다." }
            catch { self.error = error.localizedDescription }
        }
    }

    private func reviewBinding(_ id: UUID) -> Binding<Int> {
        Binding(get: { reviewCounts[id, default: 0] }, set: { reviewCounts[id] = $0 })
    }

    private func review(_ sample: RAGEvaluationSample) {
        guard let index = report?.samples.firstIndex(where: { $0.id == sample.id }) else {
            error = "검수할 실행 기록을 찾지 못했습니다."
            return
        }
        do { try report?.samples[index].run.review(reviewer: reviewer, supportedClaims: reviewCounts[sample.id, default: 0]) }
        catch { self.error = error.localizedDescription }
    }

    private func value(_ number: Double?) -> String { number.map { String(format: "%.3f", $0) } ?? "미측정" }
}
