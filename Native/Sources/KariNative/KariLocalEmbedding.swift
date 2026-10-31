import Foundation
import llama

actor KariLocalEmbedding {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loaded = ""
    private static let initialized: Void = { llama_log_set({ _, _, _ in }, nil); llama_backend_init() }()
    deinit { if let context { llama_free(context) }; if let model { llama_model_free(model) } }
    func unload() { if let context { llama_free(context) }; context = nil; if let model { llama_model_free(model) }; model = nil; loaded = "" }
    private func load(_ config: KariLocalEmbeddingModel, url: URL) throws {
        guard loaded != url.path else { return }
        unload(); _ = Self.initialized
        for gpuLayers: Int32 in [99, 0] {
            var parameters = llama_model_default_params(); parameters.n_gpu_layers = gpuLayers
            var devices: [OpaquePointer?] = [ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nil]
            let candidate = devices.withUnsafeMutableBufferPointer { pointers -> OpaquePointer? in
                if gpuLayers == 0 { parameters.devices = pointers.baseAddress }
                return llama_model_load_from_file(url.path, parameters)
            }
            guard let model = candidate else { continue }
            var settings = llama_context_default_params()
            settings.n_ctx = UInt32(config.maxTokens); settings.n_batch = UInt32(config.maxTokens); settings.n_ubatch = UInt32(config.maxTokens)
            settings.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)); settings.n_threads_batch = settings.n_threads
            settings.embeddings = true
            if gpuLayers == 0 { settings.offload_kqv = false; settings.op_offload = false }
            switch config.pooling {
            case "last": settings.pooling_type = LLAMA_POOLING_TYPE_LAST
            case "cls": settings.pooling_type = LLAMA_POOLING_TYPE_CLS
            default: settings.pooling_type = LLAMA_POOLING_TYPE_MEAN
            }
            guard let context = llama_init_from_model(model, settings) else { llama_model_free(model); continue }
            guard Int(llama_model_n_embd_out(model)) == config.dimensions else { llama_free(context); llama_model_free(model); throw KariError.message("模型向量维度与清单不符") }
            self.model = model; self.context = context; loaded = url.path; return
        }
        throw KariError.message("设备内存不足或模型不兼容，请选择更小的模型")
    }

    private func tokens(_ text: String, model: OpaquePointer) throws -> [llama_token] {
        let vocab = llama_model_get_vocab(model)
        let count = text.utf8.count
        var values = [llama_token](repeating: 0, count: count + 16)
        let n = text.withCString { llama_tokenize(vocab, $0, Int32(count), &values, Int32(values.count), true, true) }
        guard n > 0 else { throw KariError.message("模型分词失败") }
        return Array(values.prefix(Int(n)))
    }
    func split(_ text: String, config: KariLocalEmbeddingModel, url: URL) throws -> [String] {
        try load(config, url: url)
        guard let model else { throw CancellationError() }
        // Preserve the source text, and use the actual tokenizer to avoid silently truncated Chinese input.
        let chars = Array(text); var start = 0; var result: [String] = []
        let limit = min(400, config.maxTokens - 48)
        while start < chars.count {
            try Task.checkCancellation()
            var low = start + 1, high = min(chars.count, start + 1600), end = start
            while low <= high {
                let mid = (low + high) / 2
                if try tokens(config.input(String(chars[start..<mid]), query: false), model: model).count <= limit { end = mid; low = mid + 1 } else { high = mid - 1 }
            }
            guard end > start else { throw KariError.message("文本无法按模型长度切分") }
            result.append(String(chars[start..<end]))
            if end == chars.count { break }
            start = max(start + 1, end - min(60, (end - start) / 5))
        }
        return result
    }
    func embed(_ text: String, query: Bool, config: KariLocalEmbeddingModel, url: URL) throws -> [Float] {
        try Task.checkCancellation(); try load(config, url: url)
        guard let model, let context else { throw CancellationError() }
        let values = try tokens(config.input(text, query: query), model: model)
        guard values.count <= config.maxTokens else { throw KariError.message("输入超过所选模型长度，请缩短问题或重新切块") }
        if let memory = llama_get_memory(context) { llama_memory_clear(memory, true) }
        var batch = llama_batch_init(Int32(values.count), 0, 1); defer { llama_batch_free(batch) }
        batch.n_tokens = Int32(values.count)
        for i in values.indices {
            batch.token[i] = values[i]; batch.pos[i] = Int32(i); batch.n_seq_id[i] = 1; batch.seq_id[i]![0] = 0; batch.logits[i] = 1
        }
        let code = llama_model_has_encoder(model) ? llama_encode(context, batch) : llama_decode(context, batch)
        guard code == 0, let output = llama_get_embeddings_seq(context, 0) else { throw KariError.message("本机向量化失败，请检查设备内存") }
        let vector = Array(UnsafeBufferPointer(start: output, count: config.dimensions))
        try Task.checkCancellation()
        return try KariMemoryMath.normalized(vector)
    }
}
