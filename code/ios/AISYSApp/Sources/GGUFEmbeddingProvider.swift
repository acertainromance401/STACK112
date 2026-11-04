import Foundation
import CryptoKit
#if canImport(LlamaSwift)
import LlamaSwift
#endif

struct RAGSemanticResult {
    let scores: [Double?]
    let identity: [String: String]
    let warnings: [String]
}

final class GGUFEmbeddingProvider: @unchecked Sendable {
    static let fileName = "multilingual-e5-base-Q8_0.gguf"
    static let shared = GGUFEmbeddingProvider(modelURL: resolveModel())
    private let modelURL: URL?
    private let lock = NSLock()
    private var vectors: [String: [Float]] = [:]
    private var manifest: Manifest?
    #if canImport(LlamaSwift)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    #endif

    struct Manifest: Decodable {
        let model: String
        let fileName: String
        let sha256: String
        let revision: String
        let dimensions: Int
        let tokenizer: String
        let maxTokens: Int
        let pooling: String
        let normalization: String
        let queryPrefix: String
        let documentPrefix: String
    }

    init(modelURL: URL?) { self.modelURL = modelURL }

    deinit {
        #if canImport(LlamaSwift)
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        #endif
    }

    static func isEmbeddingFileName(_ name: String) -> Bool {
        name.lowercased().hasPrefix("multilingual-e5-") && name.lowercased().hasSuffix(".gguf")
    }

    private static func resolveModel() -> URL? {
        if let url = Bundle.main.url(forResource: fileName, withExtension: nil) { return url }
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = directory.appendingPathComponent("models").appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func scores(query: String, documents: [String]) throws -> RAGSemanticResult {
        lock.lock()
        defer { lock.unlock() }
        let wasReady = manifest != nil
        try load()
        guard let manifest else { throw RAGError.unavailable("임베딩 모델 설정이 준비되지 않았습니다.") }
        var hits = 0
        var misses = 0
        let queryVector = try vector(manifest.queryPrefix + query, hits: &hits, misses: &misses)
        var scores: [Double?] = []
        var warnings: [String] = []
        for (index, document) in documents.enumerated() {
            try Task.checkCancellation()
            do {
                let value = try vector(manifest.documentPrefix + document, hits: &hits, misses: &misses)
                scores.append(zip(queryVector, value).reduce(0.0) { $0 + Double($1.0) * Double($1.1) })
            } catch LocalLLMEngineError.promptTooLong(let actual, let limit) {
                scores.append(nil)
                warnings.append("청크 \(index)의 임베딩 입력이 \(actual)/\(limit)토큰으로 초과했습니다. 해당 청크의 의미 점수를 사용하지 않습니다.")
            }
        }
        return RAGSemanticResult(
            scores: scores,
            identity: [
                "provider": "GGUF multilingual-e5-base", "model": manifest.model,
                "file": manifest.fileName, "sha256": manifest.sha256, "revision": manifest.revision,
                "dimensions": String(manifest.dimensions), "pooling": manifest.pooling, "tokenizer": manifest.tokenizer,
                "normalization": manifest.normalization, "maxTokens": String(manifest.maxTokens),
                "queryPrefix": manifest.queryPrefix, "documentPrefix": manifest.documentPrefix,
                "warmBeforeSearch": String(wasReady), "vectorCacheHits": String(hits),
                "vectorCacheMisses": String(misses), "vectorCacheCapacity": "512"
            ], warnings: warnings
        )
    }

    func clearCachedQuery(_ query: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let manifest else { throw RAGError.unavailable("질문 캐시를 비우려면 임베딩 모델이 준비되어야 합니다.") }
        vectors.removeValue(forKey: Self.cacheKey(manifest.queryPrefix + query))
    }

    private static func cacheKey(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func load() throws {
        guard manifest == nil else { return }
        guard let modelURL else { throw RAGError.unavailable("임베딩 GGUF가 없습니다. 개발 환경에서 scripts/fetch_rag_embedding.sh를 실행하고 빌드해 주세요.") }
        guard let url = Bundle.main.url(forResource: "rag_embedding_model", withExtension: "json") else {
            throw RAGError.unavailable("임베딩 모델 manifest가 없습니다.")
        }
        let settings = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard settings.fileName == Self.fileName, settings.dimensions == 768, settings.tokenizer == "t5",
              settings.maxTokens == 512, settings.pooling == "mean", settings.normalization == "L2",
              settings.queryPrefix == "query: ", settings.documentPrefix == "passage: " else {
            throw RAGError.invalidInput("지원하지 않는 임베딩 모델 설정입니다.")
        }
        let handle = try FileHandle(forReadingFrom: modelURL)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let actualHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == settings.sha256 else { throw RAGError.invalidInput("임베딩 GGUF SHA-256 불일치: 파일을 확인해 주세요.") }
        #if canImport(LlamaSwift)
        llama_backend_init()
        var parameters = llama_model_default_params()
        parameters.use_mmap = true
        parameters.n_gpu_layers = 0
        guard let loaded = modelURL.path.withCString({ llama_model_load_from_file($0, parameters) }) else {
            throw RAGError.unavailable("임베딩 GGUF 모델을 열지 못했습니다.")
        }
        var architecture = [CChar](repeating: 0, count: 32)
        let architectureLength = llama_model_meta_val_str(loaded, "general.architecture", &architecture, architecture.count)
        guard architectureLength > 0, architectureLength < architecture.count,
              String(cString: architecture) == "bert", Int(llama_model_n_embd_out(loaded)) == settings.dimensions else {
            llama_model_free(loaded)
            throw RAGError.invalidInput("768차원 E5 인코더 모델이 아닙니다.")
        }
        var tokenizer = [CChar](repeating: 0, count: 32)
        let tokenizerLength = llama_model_meta_val_str(loaded, "tokenizer.ggml.model", &tokenizer, tokenizer.count)
        guard tokenizerLength > 0, tokenizerLength < tokenizer.count, String(cString: tokenizer) == settings.tokenizer else {
            llama_model_free(loaded)
            throw RAGError.invalidInput("원본 XLM-Roberta와 호환되는 SentencePiece 토크나이저가 아닙니다.")
        }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(settings.maxTokens)
        contextParameters.n_batch = UInt32(settings.maxTokens)
        contextParameters.n_ubatch = UInt32(settings.maxTokens)
        contextParameters.n_seq_max = 1
        contextParameters.n_threads = 2
        contextParameters.n_threads_batch = 2
        contextParameters.embeddings = true
        contextParameters.pooling_type = LLAMA_POOLING_TYPE_MEAN
        contextParameters.attention_type = LLAMA_ATTENTION_TYPE_NON_CAUSAL
        guard let loadedContext = llama_init_from_model(loaded, contextParameters) else {
            llama_model_free(loaded)
            throw RAGError.unavailable("임베딩 인코더 컨텍스트를 생성하지 못했습니다.")
        }
        guard let loadedVocab = llama_model_get_vocab(loaded) else {
            llama_free(loadedContext)
            llama_model_free(loaded)
            throw RAGError.unavailable("임베딩 토크나이저를 찾지 못했습니다.")
        }
        model = loaded
        context = loadedContext
        vocab = loadedVocab
        manifest = settings
        #else
        throw RAGError.unavailable("llama.cpp 임베딩 런타임을 사용할 수 없습니다.")
        #endif
    }

    private func vector(_ text: String, hits: inout Int, misses: inout Int) throws -> [Float] {
        try Task.checkCancellation()
        let key = Self.cacheKey(text)
        if let cached = vectors[key] { hits += 1; return cached }
        #if canImport(LlamaSwift)
        guard let context, let vocab, let manifest else { throw RAGError.unavailable("임베딩 엔진이 준비되지 않았습니다.") }
        let byteCount = text.utf8.count
        guard byteCount < Int(Int32.max) else { throw RAGError.invalidInput("임베딩 입력이 너무 큽니다.") }
        let required = text.withCString { llama_tokenize(vocab, $0, Int32(byteCount), nil, 0, true, false) }
        guard required < 0 else { throw RAGError.invalidInput("임베딩 입력을 토큰화하지 못했습니다.") }
        let count = Int(-required)
        guard count <= manifest.maxTokens else { throw LocalLLMEngineError.promptTooLong(actual: count, limit: manifest.maxTokens) }
        var tokens = [llama_token](repeating: 0, count: count)
        let tokenCount = tokens.withUnsafeMutableBufferPointer { buffer in
            text.withCString { llama_tokenize(vocab, $0, Int32(byteCount), buffer.baseAddress, Int32(count), true, false) }
        }
        guard tokenCount == count else { throw RAGError.invalidInput("임베딩 토큰 개수가 일치하지 않습니다.") }
        var batch = llama_batch_init(Int32(count), 0, 1)
        defer { llama_batch_free(batch) }
        guard let token = batch.token, let pos = batch.pos, let nseq = batch.n_seq_id,
              let sequences = batch.seq_id, let logits = batch.logits else {
            throw RAGError.unavailable("임베딩 토큰 배치를 할당하지 못했습니다.")
        }
        batch.n_tokens = Int32(count)
        for index in 0..<count {
            token[index] = tokens[index]
            pos[index] = Int32(index)
            nseq[index] = 1
            guard let sequence = sequences[index] else { throw RAGError.unavailable("임베딩 시퀀스가 없습니다.") }
            sequence[0] = 0
            logits[index] = 1
        }
        // llama.cpp의 BERT 임베딩은 non-causal decode 경로를 사용한다.
        if let memory = llama_get_memory(context) { llama_memory_clear(memory, true) }
        let status = llama_decode(context, batch)
        guard status == 0, let pointer = llama_get_embeddings_seq(context, 0) else {
            throw RAGError.unavailable("임베딩 인코딩 실패: \(status)")
        }
        let values = Array(UnsafeBufferPointer(start: pointer, count: manifest.dimensions))
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard values.allSatisfy(\.isFinite), norm.isFinite, norm > 0 else {
            throw RAGError.unavailable("임베딩 벡터가 유효하지 않습니다.")
        }
        let normalized = values.map { Float(Double($0) / norm) }
        if vectors.count >= 512 { vectors.removeAll(keepingCapacity: true) }
        vectors[key] = normalized
        misses += 1
        return normalized
        #else
        throw RAGError.unavailable("임베딩 런타임을 사용할 수 없습니다.")
        #endif
    }
}
