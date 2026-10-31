import Foundation

actor KariEmbeddingService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func discover(endpoint: String, key: String) async throws -> [String] {
        guard let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else { throw KariError.message("服务地址无效") }
        try KariEmbeddingURL.validate(url)
        var request = URLRequest(url: url, timeoutInterval: 10)
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["id"] as? String }.filter { $0.lowercased().contains("embed") }.sorted()
    }
    func embed(_ text: String, query: Bool, configuration c: KariEmbeddingConfiguration) async throws -> [Float] {
        var url: URL?; var body: [String: Any]
        switch c.provider {
        case "gemini":
            url = URL(string: c.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1beta/models/\(c.model):embedContent")
            body = ["model": "models/\(c.model)", "content": ["parts": [["text": text]]], "taskType": query ? "RETRIEVAL_QUERY" : "RETRIEVAL_DOCUMENT"]
        case "vertex":
            let region = c.region.isEmpty ? "us-central1" : c.region
            let base = c.endpoint.isEmpty ? "https://\(region == "global" ? "" : region + "-")aiplatform.googleapis.com" : c.endpoint
            guard !c.project.isEmpty else { throw KariError.message("Vertex 向量化需要项目 ID") }
            url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/projects/\(c.project)/locations/\(region)/publishers/google/models/\(c.model):predict")
            body = ["instances": [["content": text, "task_type": query ? "RETRIEVAL_QUERY" : "RETRIEVAL_DOCUMENT"]], "parameters": ["autoTruncate": false]]
        case "ollama":
            url = URL(string: c.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/embed")
            body = ["model": c.model, "input": text, "truncate": false]
        default:
            url = URL(string: c.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/embeddings")
            body = ["model": c.model, "input": c.provider == "fireworks" && c.model.contains("nomic") ? (query ? "search_query: " : "search_document: ") + text : text, "encoding_format": "float"]
        }
        guard let url else { throw KariError.message("请填写有效的向量服务地址") }
        try KariEmbeddingURL.validate(url)
        var request = URLRequest(url: url, timeoutInterval: 20); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if c.provider == "gemini" || c.provider == "vertex" && c.auth != "oauth" { request.setValue(c.key, forHTTPHeaderField: "x-goog-api-key") }
        else if !c.key.isEmpty { request.setValue("Bearer " + c.key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reason: String
            switch status { case 401, 403: reason = "凭据或模型权限不可用"; case 404: reason = "未找到向量模型或接口"; case 429: reason = "请求限流或额度不足"; default: reason = "服务请求失败" }
            throw KariError.message("向量化：\(reason)（\(status)）。可重试、切换服务商或配置本地服务。")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw KariError.message("向量服务返回格式错误") }
        let raw: [NSNumber]?
        switch c.provider {
        case "gemini": raw = (object["embedding"] as? [String: Any])?["values"] as? [NSNumber]
        case "vertex": raw = (((object["predictions"] as? [[String: Any]])?.first)?["embeddings"] as? [String: Any])?["values"] as? [NSNumber]
        case "ollama": raw = (object["embeddings"] as? [[NSNumber]])?.first
        default: raw = (object["data"] as? [[String: Any]])?.first?["embedding"] as? [NSNumber]
        }
        guard let raw, raw.count <= 8192 else { throw KariError.message("向量服务未返回有效 embedding") }
        return try KariMemoryMath.normalized(raw.map(\.floatValue))
    }
}
