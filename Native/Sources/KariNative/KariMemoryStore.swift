import Foundation
import SQLite3

actor KariMemoryStore {
    let root: URL
    init(root: URL) { self.root = root }
    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("memory.sqlite").path, &pointer) == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }; throw KariError.message("无法打开记忆库")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS chunks (id TEXT PRIMARY KEY, payload BLOB NOT NULL, embedding BLOB NOT NULL); CREATE TABLE IF NOT EXISTS metadata (id TEXT PRIMARY KEY, value TEXT NOT NULL);", nil, nil, nil) == SQLITE_OK else { throw KariError.message("无法初始化记忆库") }
        return try body(db)
    }
    private func rows(_ db: OpaquePointer, sql: String, body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw KariError.message("无法读取记忆库") }
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw KariError.message("记忆库读取失败") }
            try body(statement)
        }
    }
    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
    func load() throws -> KariMemorySnapshot {
        try database { db in
            var result = KariMemorySnapshot()
            try rows(db, sql: "SELECT payload FROM documents ORDER BY rowid") { statement in result.documents.append(try JSONDecoder().decode(KariMemoryDocument.self, from: blob(statement, 0))) }
            try rows(db, sql: "SELECT payload, embedding FROM chunks ORDER BY rowid") { statement in
                var chunk = try JSONDecoder().decode(KariMemoryChunk.self, from: blob(statement, 0))
                let bytes = blob(statement, 1)
                guard bytes.count % MemoryLayout<Float>.size == 0 else { throw KariError.message("向量数据损坏") }
                chunk.vector = bytes.withUnsafeBytes { data in stride(from: 0, to: data.count, by: 4).map { data.loadUnaligned(fromByteOffset: $0, as: Float.self) } }
                result.chunks.append(chunk)
            }
            try rows(db, sql: "SELECT value FROM metadata WHERE id='fingerprint'") { statement in if let value = sqlite3_column_text(statement, 0) { result.fingerprint = String(cString: value) } }
            return result
        }
    }
    // All documents and vectors switch together. Float blobs avoid JSON's vector-size and parsing overhead.
    func save(_ value: KariMemorySnapshot) throws {
        try database { db in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE; DELETE FROM documents; DELETE FROM chunks; DELETE FROM metadata;", nil, nil, nil) == SQLITE_OK else { throw KariError.message("无法开始记忆库写入") }
            var committed = false
            defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
            func insert(_ sql: String, id: String, payload: Data, vector: Data? = nil) throws {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw KariError.message("无法保存记忆库") }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
                _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
                if let vector { _ = vector.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), transient) } }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw KariError.message("无法保存记忆库，请检查剩余空间") }
            }
            for document in value.documents { try insert("INSERT INTO documents VALUES(?,?)", id: document.id.uuidString, payload: JSONEncoder().encode(document)) }
            for chunk in value.chunks {
                var metadata = chunk; metadata.vector = []
                let bytes = chunk.vector.withUnsafeBytes { Data($0) }
                try insert("INSERT INTO chunks VALUES(?,?,?)", id: chunk.id.uuidString, payload: JSONEncoder().encode(metadata), vector: bytes)
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO metadata VALUES('fingerprint',?)", -1, &statement, nil) == SQLITE_OK else { throw KariError.message("无法保存索引版本") }
            defer { sqlite3_finalize(statement) }
            _ = value.fingerprint.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw KariError.message("记忆库提交失败") }
            committed = true
        }
    }
}

extension KariMemoryStore {
    private func checkpointURL(_ fingerprint: String, document: UUID) -> URL {
        // Fingerprint is encoded as a hex directory name by the caller.
        root.appendingPathComponent("Checkpoints").appendingPathComponent(fingerprint).appendingPathComponent(document.uuidString, isDirectory: true)
    }
    func checkpoint(_ fingerprint: String, document: UUID) throws -> [KariMemoryChunk] {
        let folder = checkpointURL(fingerprint, document: document)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result: [KariMemoryChunk] = []
        for file in files {
            guard Int(file.deletingPathExtension().lastPathComponent) == result.count else { break }
            result += try JSONDecoder().decode([KariMemoryChunk].self, from: Data(contentsOf: file))
        }
        return result
    }
    func saveCheckpoint(_ fingerprint: String, document: UUID, chunks: [KariMemoryChunk], offset: Int = 0) throws {
        let folder = checkpointURL(fingerprint, document: document)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(String(format: "%08d.json", offset))
        try JSONEncoder().encode(chunks).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func removeCheckpoints(document: UUID? = nil) throws {
        let folder = root.appendingPathComponent("Checkpoints")
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if let document {
            for directory in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                let file = directory.appendingPathComponent(document.uuidString, isDirectory: true)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
        } else { try FileManager.default.removeItem(at: folder) }
    }
}
