import Foundation

#if canImport(LlamaSwift)
import LlamaSwift
#endif

protocol LocalLLMEngine: AnyObject {
    var name: String { get }
    func loadModel() async throws
    func resetModel() async
    func generate(prompt: String, maxTokens: Int) async throws -> String
}

enum LocalLLMEngineError: LocalizedError {
    case runtimeUnavailable(String)
    case modelNotFound(String)
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let message):
            return message
        case .modelNotFound(let message):
            return message
        case .modelNotLoaded:
            return "로컬 모델이 로드되지 않았습니다."
        }
    }
}

enum LocalLLMModelSource: String {
    case bundle = "번들"
    case documents = "Documents/models"
}

struct LocalLLMModelResolution {
    let selectedURL: URL?
    let selectedSource: LocalLLMModelSource?
    let bundleURL: URL?
    let documentsURL: URL?
    let configuredFileName: String?
    let selectionReason: String
}

enum LocalLLMModelLocator {
    private static let model1BFileNames = [
        "llama-3.2-1b-instruct-q4_k_m.gguf",
        "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    ]

    private static let model3BFileNames = [
        "llama-3.2-3b-instruct-q4_k_m.gguf",
        "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        "Llama-3.2-3B-Instruct-Q4_K_L.gguf"
    ]

    private static let modelLargeFileNames = [
        "llama-3.1-8b-instruct-q4_k_m.gguf",
        "Llama-3.1-8B-Instruct-Q4_K_M.gguf"
    ]

    private enum DeviceTier: String {
        case low = "low"
        case balanced = "balanced"
        case high = "high"
    }

    static func resolveModel(ignoreDocuments: Bool) -> LocalLLMModelResolution {
        let candidates = candidateFileNames()
        let configuredFileName = candidates.first
        let bundleURL = resolveFromBundle(candidates: candidates)
        let documentsURL = resolveFromDocuments(candidates: candidates)
        let tierReason = "device=\(deviceTier().rawValue)/\(deviceMemoryGB())GB"

        if ignoreDocuments {
            return LocalLLMModelResolution(
                selectedURL: bundleURL,
                selectedSource: bundleURL == nil ? nil : .bundle,
                bundleURL: bundleURL,
                documentsURL: documentsURL,
                configuredFileName: configuredFileName,
                selectionReason: bundleURL == nil
                    ? "Documents 무시 설정이 켜져 있고 번들 모델을 찾지 못했습니다. (\(tierReason))"
                    : "Documents 무시 설정이 켜져 있어 번들 모델을 선택했습니다. (\(tierReason))"
            )
        }

        if let bundleURL, let documentsURL {
            if isDocumentsModelPreferred(documentsURL: documentsURL, bundleURL: bundleURL) {
                return LocalLLMModelResolution(
                    selectedURL: documentsURL,
                    selectedSource: .documents,
                    bundleURL: bundleURL,
                    documentsURL: documentsURL,
                    configuredFileName: configuredFileName,
                    selectionReason: "Documents 모델이 번들 모델보다 최신이라 선택했습니다. (\(tierReason))"
                )
            }

            return LocalLLMModelResolution(
                selectedURL: bundleURL,
                selectedSource: .bundle,
                bundleURL: bundleURL,
                documentsURL: documentsURL,
                configuredFileName: configuredFileName,
                selectionReason: "번들 모델이 더 최신이거나 동일하여 선택했습니다. (\(tierReason))"
            )
        }

        if let bundled = bundleURL {
            return LocalLLMModelResolution(
                selectedURL: bundled,
                selectedSource: .bundle,
                bundleURL: bundled,
                documentsURL: documentsURL,
                configuredFileName: configuredFileName,
                selectionReason: "번들 모델만 발견되어 선택했습니다. (\(tierReason))"
            )
        }

        if let inDocuments = documentsURL {
            return LocalLLMModelResolution(
                selectedURL: inDocuments,
                selectedSource: .documents,
                bundleURL: bundleURL,
                documentsURL: inDocuments,
                configuredFileName: configuredFileName,
                selectionReason: "번들 모델이 없어 Documents 모델을 선택했습니다. (\(tierReason))"
            )
        }

        return LocalLLMModelResolution(
            selectedURL: nil,
            selectedSource: nil,
            bundleURL: bundleURL,
            documentsURL: documentsURL,
            configuredFileName: configuredFileName,
            selectionReason: "번들과 Documents 어디에서도 GGUF 모델을 찾지 못했습니다. (\(tierReason))"
        )
    }

    private static func deviceMemoryGB() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory / 1_073_741_824
    }

    private static func deviceTier() -> DeviceTier {
        let memory = deviceMemoryGB()
        // 8GB 이하 기기는 3B에서 prefill 단계 abort 가능성이 있어 low로 취급
        if memory <= 8 { return .low }
        if memory <= 12 { return .balanced }
        return .high
    }

    private static func isDocumentsModelPreferred(documentsURL: URL, bundleURL: URL) -> Bool {
        let documentsDate = modificationDate(of: documentsURL)
        let bundleDate = modificationDate(of: bundleURL)

        guard let documentsDate else {
            return false
        }
        guard let bundleDate else {
            return true
        }
        return documentsDate > bundleDate
    }

    private static func modificationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate
    }

    private static func candidateFileNames() -> [String] {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "LLAMA_MODEL_FILE") as? String) ?? ""
        let tierPreferred: [String]
        switch deviceTier() {
        case .low:
            tierPreferred = model1BFileNames
        case .balanced:
            // 기본은 3B 우선, 없으면 1B 자동 다운그레이드
            tierPreferred = model3BFileNames + model1BFileNames
        case .high:
            // 고성능 기기는 3B 우선, 8B가 있을 때만 선택 가능
            tierPreferred = model3BFileNames + modelLargeFileNames + model1BFileNames
        }

        var result: [String] = []
        var seen = Set<String>()

        // configured 파일명을 최우선으로 강제하면 저사양에서도 3B를 먼저 잡아 크래시가 날 수 있어
        // tierPreferred를 우선하고 configured은 마지막 후보로만 둡니다.
        for name in tierPreferred + [configured] {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || seen.contains(trimmed) {
                continue
            }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private static func resolveFromDocuments(candidates: [String]) -> URL? {
        guard let modelsDir = documentsModelsDirectory(createIfNeeded: false) else {
            return nil
        }

        for fileName in candidates {
            let url = modelsDir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // 파일명이 다르더라도 첫 GGUF를 사용합니다.
        let files = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return files?
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private static func resolveFromBundle(candidates: [String]) -> URL? {
        for fileName in candidates {
            if let bundled = Bundle.main.url(forResource: fileName, withExtension: nil) {
                return bundled
            }
        }

        return Bundle.main
            .urls(forResourcesWithExtension: "gguf", subdirectory: nil)?
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private static func documentsModelsDirectory(createIfNeeded: Bool) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let modelsDir = documents.appendingPathComponent("models", isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        }
        return modelsDir
    }

    private static func copyBundledModelToDocuments(bundledURL: URL, preferredName: String) -> URL? {
        guard let modelsDir = documentsModelsDirectory(createIfNeeded: true) else {
            return nil
        }

        let destination = modelsDir.appendingPathComponent(preferredName)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        do {
            try FileManager.default.copyItem(at: bundledURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}

/// llama.cpp 연결 엔진.
/// 실제 연결 전까지는 runtimeUnavailable 에러를 반환하고, 앱은 폴백 엔진을 사용합니다.
final class LlamaCppEngine: LocalLLMEngine {
    let name = "llama.cpp"
    private(set) var isLoaded = false
    private var modelURL: URL?
    var ignoreDocumentsModel = true
    private(set) var modelResolution = LocalLLMModelResolution(
        selectedURL: nil,
        selectedSource: nil,
        bundleURL: nil,
        documentsURL: nil,
        configuredFileName: nil
        ,selectionReason: "초기 상태"
    )

    #if canImport(LlamaSwift)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var vocab: OpaquePointer?
    #endif

    init(modelURL: URL? = nil) {
        self.modelURL = modelURL
    }

    deinit {
        cleanupRuntime()
    }

    func resetModel() async {
        cleanupRuntime()
        modelURL = nil
    }

    private func cleanupRuntime() {
        #if canImport(LlamaSwift)
        if let sampler {
            llama_sampler_free(sampler)
            self.sampler = nil
        }
        if let context {
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        self.vocab = nil
        #endif
        isLoaded = false
    }

    func loadModel() async throws {
        if modelURL == nil {
            modelResolution = LocalLLMModelLocator.resolveModel(ignoreDocuments: ignoreDocumentsModel)
            modelURL = modelResolution.selectedURL
        }

        guard let modelURL else {
            let configured = modelResolution.configuredFileName ?? "LLAMA_MODEL_FILE 미설정"
            let bundlePath = modelResolution.bundleURL?.path ?? "없음"
            let documentsPath = modelResolution.documentsURL?.path ?? "없음"
            throw LocalLLMEngineError.modelNotFound(
                "GGUF 모델 파일을 찾을 수 없습니다. configured=\(configured) / bundle=\(bundlePath) / documents=\(documentsPath) / reason=\(modelResolution.selectionReason)"
            )
        }

        #if canImport(LlamaSwift)
        // llama.cpp 런타임 초기화 -> 모델 로드 -> 컨텍스트 생성 -> 샘플러 구성 순서입니다.
        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.use_mmap = true
        mparams.use_mlock = false
        mparams.n_gpu_layers = 0

        let modelPath = modelURL.path
        guard let loadedModel = modelPath.withCString({ llama_model_load_from_file($0, mparams) }) else {
            throw LocalLLMEngineError.runtimeUnavailable(
                "모델 로딩에 실패했습니다: \(modelURL.lastPathComponent) / source=\(modelResolution.selectedSource?.rawValue ?? "알 수 없음") / path=\(modelPath)"
            )
        }

        var cparams = llama_context_default_params()
        let memoryGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        // 보수 설정: 발열/메모리 급증을 막고 저사양에서는 자동 축소
        if memoryGB <= 4 {
            cparams.n_ctx = 256
            cparams.n_batch = 64
            cparams.n_ubatch = 64
            cparams.n_threads = 2
            cparams.n_threads_batch = 2
        } else if memoryGB <= 6 {
            cparams.n_ctx = 320
            cparams.n_batch = 64
            cparams.n_ubatch = 64
            cparams.n_threads = 2
            cparams.n_threads_batch = 2
        } else if memoryGB <= 8 {
            cparams.n_ctx = 384
            cparams.n_batch = 96
            cparams.n_ubatch = 96
            cparams.n_threads = 2
            cparams.n_threads_batch = 2
        } else {
            cparams.n_ctx = 512
            cparams.n_batch = 128
            cparams.n_ubatch = 128
            cparams.n_threads = 3
            cparams.n_threads_batch = 2
        }

        guard let loadedContext = llama_init_from_model(loadedModel, cparams) else {
            llama_model_free(loadedModel)
            throw LocalLLMEngineError.runtimeUnavailable(
                "추론 컨텍스트 초기화에 실패했습니다. source=\(modelResolution.selectedSource?.rawValue ?? "알 수 없음") / path=\(modelPath)"
            )
        }

        let loadedVocab = llama_model_get_vocab(loadedModel)
        guard loadedVocab != nil else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            throw LocalLLMEngineError.runtimeUnavailable(
                "어휘 사전 로딩에 실패했습니다. source=\(modelResolution.selectedSource?.rawValue ?? "알 수 없음") / path=\(modelPath)"
            )
        }

        let chainParams = llama_sampler_chain_default_params()
        guard let loadedSampler = llama_sampler_chain_init(chainParams) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            throw LocalLLMEngineError.runtimeUnavailable(
                "샘플러 초기화에 실패했습니다. source=\(modelResolution.selectedSource?.rawValue ?? "알 수 없음") / path=\(modelPath)"
            )
        }
        llama_sampler_chain_add(loadedSampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(loadedSampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(loadedSampler, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(loadedSampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))

        model = loadedModel
        context = loadedContext
        sampler = loadedSampler
        vocab = loadedVocab
        isLoaded = true
        #else
        throw LocalLLMEngineError.runtimeUnavailable(
            "llama.cpp iOS 라이브러리가 프로젝트에 연결되지 않았습니다."
        )
        #endif
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        guard isLoaded else {
            throw LocalLLMEngineError.modelNotLoaded
        }

        #if canImport(LlamaSwift)
        guard let context, let sampler, let vocab else {
            throw LocalLLMEngineError.modelNotLoaded
        }

        // 무거운 llama_decode 연산을 백그라운드 스레드에서 실행하여 메인 스레드 블로킹 방지
        // 이는 Objective-C 타입 정보 경고를 해결하고 UI 렉을 개선합니다.
        let result = try await Task.detached(priority: .userInitiated) { () -> String in
            // 현재 연결된 llama.swift 버전에는 llama_kv_cache_clear 심볼이 없어 sampler만 초기화합니다.
            // 컨텍스트 누적 이슈는 프롬프트/생성 토큰 상한으로 방지합니다.
            llama_sampler_reset(sampler)

            // 1. 프롬프트 전체를 토큰화
            // 2. prefill decode로 컨텍스트에 주입
            // 3. sampler가 다음 토큰을 하나씩 선택
            // 4. 선택한 토큰을 다시 decode 하며 maxTokens까지 반복
            var promptTokens = try self.tokenize(text: prompt, vocab: vocab)
            guard !promptTokens.isEmpty else {
                throw LocalLLMEngineError.runtimeUnavailable("프롬프트 토큰화 결과가 비어 있습니다.")
            }

            let memoryGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
            // 안전장치: 8GB 이하 환경에서 3B는 prefill 단계에서 abort가 발생할 수 있어 즉시 폴백 유도
            let modelName = self.modelURL?.lastPathComponent.lowercased() ?? ""
            if memoryGB <= 8 && modelName.contains("3b") {
                throw LocalLLMEngineError.runtimeUnavailable("현재 기기 메모리에서는 3B 모델이 불안정하여 1B로 자동 폴백합니다.")
            }

            let contextBudget = memoryGB <= 4 ? 320 : (memoryGB <= 6 ? 384 : (memoryGB <= 8 ? 448 : 512))
            let reservedForGeneration = memoryGB <= 6 ? 72 : 96
            let promptBudget = max(64, contextBudget - reservedForGeneration - 8)
            if promptTokens.count > promptBudget {
                promptTokens = Array(promptTokens.prefix(promptBudget))
            }

            // prefill 청크는 loadModel()에서 설정한 n_batch를 넘지 않도록 맞춥니다.
            // n_batch보다 큰 값이 들어가면 llama_decode 내부 assert로 SIGABRT가 날 수 있습니다.
            let batchLimit: Int
            if memoryGB <= 6 {
                batchLimit = 64
            } else if memoryGB <= 8 {
                batchLimit = 96
            } else {
                batchLimit = 120
            }
            var start = 0
            while start < promptTokens.count {
                let end = min(start + batchLimit, promptTokens.count)
                var chunk = Array(promptTokens[start..<end])
                let prefillResult = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    guard let base = buffer.baseAddress, buffer.count > 0 else { return -1 }
                    let batch = llama_batch_get_one(base, Int32(buffer.count))
                    return llama_decode(context, batch)
                }
                guard prefillResult == 0 else {
                    throw LocalLLMEngineError.runtimeUnavailable("프롬프트 디코딩에 실패했습니다. code=\(prefillResult)")
                }
                start = end
            }

            // 모바일 환경에서 최대 토큰 생성 수 대폭 제한 (배터리/CPU/메모리 최소화)
            let hardMaxOut = memoryGB <= 6 ? 96 : 128
            let availableGenerationBudget = max(1, contextBudget - promptTokens.count - 4)
            let maxOut = max(1, min(maxTokens, hardMaxOut, availableGenerationBudget))
            var generated: [llama_token] = []
            generated.reserveCapacity(maxOut)

            for _ in 0..<maxOut {
                // 현재 컨텍스트를 바탕으로 다음 토큰 1개를 샘플링합니다.
                let token = llama_sampler_sample(sampler, context, -1)
                if llama_vocab_is_eog(vocab, token) || token == llama_vocab_eos(vocab) {
                    break
                }

                generated.append(token)
                llama_sampler_accept(sampler, token)

                // 방금 뽑은 토큰을 다시 컨텍스트에 반영해야 다음 토큰을 이어서 생성할 수 있습니다.
                var one = [token]
                let nextResult = one.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    let batch = llama_batch_get_one(buffer.baseAddress, 1)
                    return llama_decode(context, batch)
                }
                if nextResult != 0 {
                    break
                }
            }

            let text = self.decodeTokens(generated, vocab: vocab)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? "- one_line_summary: \(prompt.prefix(80))" : cleaned
        }.value

        return result
        #else
        throw LocalLLMEngineError.runtimeUnavailable(
            "llama.cpp 생성 루틴이 아직 연결되지 않았습니다."
        )
        #endif
    }

    #if canImport(LlamaSwift)
    private func tokenize(text: String, vocab: OpaquePointer) throws -> [llama_token] {
        var bytes = Array(text.utf8).map { CChar(bitPattern: $0) }
        return try bytes.withUnsafeMutableBufferPointer { textBuffer in
            let textLen = Int32(textBuffer.count)
            var tokenBuffer = [llama_token](repeating: 0, count: max(256, textBuffer.count + 16))

            let firstCount = tokenBuffer.withUnsafeMutableBufferPointer { tokenPtr in
                llama_tokenize(
                    vocab,
                    textBuffer.baseAddress,
                    textLen,
                    tokenPtr.baseAddress,
                    Int32(tokenPtr.count),
                    true,
                    true
                )
            }

            if firstCount >= 0 {
                return Array(tokenBuffer.prefix(Int(firstCount)))
            }

            let needed = Int(-firstCount)
            guard needed > 0 else {
                throw LocalLLMEngineError.runtimeUnavailable("토큰화에 실패했습니다.")
            }

            tokenBuffer = [llama_token](repeating: 0, count: needed)
            let secondCount = tokenBuffer.withUnsafeMutableBufferPointer { tokenPtr in
                llama_tokenize(
                    vocab,
                    textBuffer.baseAddress,
                    textLen,
                    tokenPtr.baseAddress,
                    Int32(tokenPtr.count),
                    true,
                    true
                )
            }

            guard secondCount >= 0 else {
                throw LocalLLMEngineError.runtimeUnavailable("토큰화 버퍼 재시도에 실패했습니다.")
            }
            return Array(tokenBuffer.prefix(Int(secondCount)))
        }
    }

    private func decodeTokens(_ tokens: [llama_token], vocab: OpaquePointer) -> String {
        guard !tokens.isEmpty else { return "" }

        var output = ""
        output.reserveCapacity(tokens.count * 3)

        for token in tokens {
            var pieceLength = 16
            var piece = ""

            while pieceLength <= 4096 {
                var buffer = [CChar](repeating: 0, count: pieceLength)
                let written = llama_token_to_piece(
                    vocab,
                    token,
                    &buffer,
                    Int32(pieceLength),
                    0,
                    false
                )

                if written > 0 {
                    piece = String(bytes: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
                    break
                }

                if written < 0 {
                    pieceLength = max(pieceLength * 2, Int(-written) + 8)
                } else {
                    pieceLength *= 2
                }
            }

            output += piece
        }

        return output
    }
    #endif
}

/// 폴백용 경량 로컬 엔진.
final class RuleBasedLocalEngine: LocalLLMEngine {
    let name = "rule-based"

    func loadModel() async throws {
        // 별도 모델 로딩 없음
    }

    func resetModel() async {
        // 재설정할 상태 없음
    }

    /// 프롬프트에서 필드 값을 추출해 구조화된 응답을 생성합니다.
    func generate(prompt: String, maxTokens: Int) async throws -> String {
        _ = maxTokens
        
        // 프롬프트의 마지막 부분에서 필드 추출 (정규식 대신 간단한 string 처리)
        func extractField(_ keyword: String) -> String {
            // "case_name:" 또는 "caseName:" 형식으로 검색
            let lowerPrompt = prompt.lowercased()
            let lowerKeyword = keyword.lowercased()
            
            guard let range = lowerPrompt.range(of: lowerKeyword + ":") else {
                return ""
            }
            
            // 키워드 이후의 텍스트 추출
            let afterKeyword = String(prompt[range.upperBound...])
            
            // 첫 번째 줄 또는 쉼표까지의 텍스트
            let endCharacters = CharacterSet(charactersIn: "\n,;]}")
            let components = afterKeyword.components(separatedBy: endCharacters)
            let value = components.first ?? ""
            
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let caseName = extractField("case_name").isEmpty
            ? extractField("caseName")
            : extractField("case_name")
        
        let issue = extractField("issue")
        let keywords = extractField("keywords")
        let keySentences = extractField("key_sentences").prefix(200)
        
        // 모두 빈 경우를 대비한 폴백
        if caseName.isEmpty && issue.isEmpty && keywords.isEmpty {
            return """
            - one_line_summary: 기본 요약 (데이터 미제공)
            - key_issue: 쟁점 정보가 제공되지 않았습니다
            - ruling_point: 판결 결론 정보가 제공되지 않았습니다
            - exam_takeaway: 시험 포인트 정보가 제공되지 않았습니다
            """
        }
        
        // 항상 파싱 가능한 형식으로 반환
        let summaryText = caseName.isEmpty
            ? "기본 요약"
            : "\(caseName)은(는) \(issue.isEmpty ? "중요한 판례" : issue)입니다."
        
        return """
        - one_line_summary: \(summaryText)
        - key_issue: \(issue.isEmpty ? "쟁점이 제공되지 않았습니다" : issue)
        - ruling_point: \(keySentences.isEmpty ? (issue.isEmpty ? "판결 결론 미제공" : "주요 내용: \(issue)") : keySentences)
        - exam_takeaway: \(keywords.isEmpty ? "시험 포인트: 개념 확인" : "시험 포인트: \(keywords)")
        """
    }
}
