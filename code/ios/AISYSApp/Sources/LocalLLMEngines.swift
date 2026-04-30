import Foundation

#if canImport(LlamaSwift)
import LlamaSwift
#endif

protocol LocalLLMEngine {
    var name: String { get }
    func loadModel() async throws
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

enum LocalLLMModelLocator {
    private static let fallbackFileNames = [
        "llama-3.2-1b-instruct-q4_k_m.gguf",
        "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    ]

    static func resolveModelURL() -> URL? {
        let candidates = candidateFileNames()

        if let inDocuments = resolveFromDocuments(candidates: candidates) {
            return inDocuments
        }

        guard let bundled = resolveFromBundle(candidates: candidates) else {
            return nil
        }

        // 번들에 모델이 있을 경우 Documents/models로 복사해 두면 실기기에서 교체/업데이트가 쉬워집니다.
        if let copied = copyBundledModelToDocuments(
            bundledURL: bundled,
            preferredName: candidates.first ?? bundled.lastPathComponent
        ) {
            return copied
        }

        return bundled
    }

    private static func candidateFileNames() -> [String] {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "LLAMA_MODEL_FILE") as? String) ?? ""
        var result: [String] = []
        var seen = Set<String>()

        for name in [configured] + fallbackFileNames {
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
        #if canImport(LlamaSwift)
        if let sampler {
            llama_sampler_free(sampler)
        }
        if let context {
            llama_free(context)
        }
        if let model {
            llama_model_free(model)
        }
        #endif
    }

    func loadModel() async throws {
        if modelURL == nil {
            modelURL = LocalLLMModelLocator.resolveModelURL()
        }

        guard modelURL != nil else {
            throw LocalLLMEngineError.modelNotFound(
                "GGUF 모델 파일을 찾을 수 없습니다. Info.plist LLAMA_MODEL_FILE 또는 Documents/models 경로를 확인하세요."
            )
        }

        #if canImport(LlamaSwift)
        guard let modelURL else {
            throw LocalLLMEngineError.modelNotLoaded
        }

        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.use_mmap = true
        mparams.use_mlock = false
        mparams.n_gpu_layers = 0

        let modelPath = modelURL.path
        guard let loadedModel = modelPath.withCString({ llama_model_load_from_file($0, mparams) }) else {
            throw LocalLLMEngineError.runtimeUnavailable("모델 로딩에 실패했습니다: \(modelURL.lastPathComponent)")
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048
        cparams.n_batch = 512
        cparams.n_ubatch = 512
        let threads = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
        cparams.n_threads = Int32(threads)
        cparams.n_threads_batch = Int32(threads)

        guard let loadedContext = llama_init_from_model(loadedModel, cparams) else {
            llama_model_free(loadedModel)
            throw LocalLLMEngineError.runtimeUnavailable("추론 컨텍스트 초기화에 실패했습니다.")
        }

        let loadedVocab = llama_model_get_vocab(loadedModel)
        guard loadedVocab != nil else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            throw LocalLLMEngineError.runtimeUnavailable("어휘 사전 로딩에 실패했습니다.")
        }

        let chainParams = llama_sampler_chain_default_params()
        guard let loadedSampler = llama_sampler_chain_init(chainParams) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            throw LocalLLMEngineError.runtimeUnavailable("샘플러 초기화에 실패했습니다.")
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

        let memory = llama_get_memory(context)
        llama_memory_clear(memory, true)
        llama_sampler_reset(sampler)

        var promptTokens = try tokenize(text: prompt, vocab: vocab)
        guard !promptTokens.isEmpty else {
            throw LocalLLMEngineError.runtimeUnavailable("프롬프트 토큰화 결과가 비어 있습니다.")
        }

        // n_batch(512)를 초과하면 llama_decode가 SIGABRT로 크래시.
        // 뒤쪽(최신 내용)을 우선 보존하여 트리밍.
        let batchLimit = 480
        if promptTokens.count > batchLimit {
            promptTokens = Array(promptTokens.suffix(batchLimit))
        }

        let promptBatch = promptTokens.withUnsafeMutableBufferPointer {
            llama_batch_get_one($0.baseAddress, Int32($0.count))
        }
        let prefillResult = llama_decode(context, promptBatch)
        guard prefillResult == 0 else {
            throw LocalLLMEngineError.runtimeUnavailable("프롬프트 디코딩에 실패했습니다. code=\(prefillResult)")
        }

        let maxOut = max(1, min(maxTokens, 512))
        var generated: [llama_token] = []
        generated.reserveCapacity(maxOut)

        for _ in 0..<maxOut {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) || token == llama_vocab_eos(vocab) {
                break
            }

            generated.append(token)
            llama_sampler_accept(sampler, token)

            var one = [token]
            let nextBatch = one.withUnsafeMutableBufferPointer {
                llama_batch_get_one($0.baseAddress, 1)
            }
            let nextResult = llama_decode(context, nextBatch)
            if nextResult != 0 {
                break
            }
        }

        let text = decodeTokens(generated, vocab: vocab)
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "- one_line_summary: \(prompt.prefix(80))" : cleaned
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
