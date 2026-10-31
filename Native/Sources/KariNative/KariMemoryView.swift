import SwiftUI
import UniformTypeIdentifiers

struct KariMemoryView: View {
    @ObservedObject var app: KariAppModel
    @ObservedObject var memory: KariMemoryService
    @State private var importing = false
    @State private var clearing = false
    @State private var question = ""
    @State private var answer = ""
    @State private var asking = false
    @State private var request: Task<Void, Never>?
    @State private var filter = ""
    var body: some View {
        NavigationView {
            Form {
                Section {
                    NavigationLink { KariMemorySettingsView(app: app, memory: memory, downloads: memory.downloads) } label: { Label(L("向量服务与本机模型"), systemImage: "cpu") }.accessibilityIdentifier("memoryModelSettings")
                    Text(L("资料保存在当前手机，所有机器人共用。本机向量化不上传全文；云端聊天会收到检索命中的片段。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(header: Text(L("资料"))) {
                    Button { importing = true } label: { Label(L("导入资料"), systemImage: "doc.badge.plus") }.disabled(!memory.mayEdit).accessibilityIdentifier("memoryImport")
                    Text(L("PDF（含扫描件）、TXT、Markdown、DOCX、XLSX、PPTX。单文件最多 50 MB，PDF 最多 500 页。"))
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(L("搜索资料"), text: $filter)
                    ForEach(memory.documents.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { document in
                        NavigationLink { KariMemoryDocumentView(memory: memory, documentID: document.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(document.name)
                                Text(L(document.status) + (document.enabled ? "" : " · " + L("已停用"))).font(.caption).foregroundStyle(.secondary)
                                if !document.error.isEmpty { Text(document.error).font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                    if memory.documents.isEmpty { Text(L("导入资料后，KARI 就可以根据这些记忆回答问题。")) }
                }
                Section(header: Text(L("问问记忆"))) {
                    TextField(L("根据资料提问…"), text: $question).submitLabel(.send).onSubmit(ask)
                    Button(asking ? L("正在回答…") : L("提问"), action: ask).disabled(asking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !memory.hasEnabledDocuments || !memory.mayEdit).accessibilityIdentifier("memoryAsk")
                    if !answer.isEmpty { Text(answer).textSelection(.enabled).accessibilityIdentifier("memoryAnswer") }
                    KariMemorySources(hits: memory.hits)
                }
                Section {
                    if memory.busy { ProgressView(value: memory.progress); Button(L("暂停处理"), action: memory.pause) }
                    Button(L("重试／重建索引")) { memory.rebuild(app.settings.configuration) }.disabled(!memory.mayEdit || memory.documents.isEmpty)
                    if !memory.message.isEmpty { Text(LM(memory.message)).font(.footnote).textSelection(.enabled).accessibilityIdentifier("memoryStatus") }
                    Button(L("清空记忆库"), role: .destructive) { clearing = true }.disabled(!memory.mayEdit || memory.documents.isEmpty).accessibilityIdentifier("memoryClear")
                    Text(L("记忆库不会自动记录聊天或音视频。")).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("memoryFooter")
                }
            }
            .navigationTitle(L("记忆库"))
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, .text, .data], allowsMultipleSelection: true) { result in
                do { memory.importFiles(try result.get(), chat: app.settings.configuration) } catch { memory.message = error.localizedDescription }
            }
            .alert(L("清空记忆库？"), isPresented: $clearing) {
                Button(L("清空"), role: .destructive) { Task { await memory.clear() }; answer = "" }
                Button(L("取消"), role: .cancel) {}
            } message: { Text(L("将删除本机导入的所有资料和索引，已下载模型保留。")) }
        }.navigationViewStyle(.stack)
        .onDisappear { request?.cancel(); request = nil; asking = false }
    }
    private func ask() {
        guard !asking, memory.mayEdit, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        asking = true; answer = ""; let text = question
        request = Task {
            defer { asking = false }
            do {
                let result = try await app.textRequest(text, useMemory: true)
                try Task.checkCancellation(); answer = result
            } catch is CancellationError {} catch { answer = KariAIRequest.redact(error.localizedDescription) }
        }
    }
}

struct KariMemorySources: View {
    let hits: [KariMemoryHit]
    var body: some View {
        if !hits.isEmpty {
            DisclosureGroup(L("检索资料")) {
                ForEach(hits) { hit in
                    DisclosureGroup(hit.documentName + " · " + hit.chunk.location) {
                        Text(hit.chunk.text).font(.footnote).textSelection(.enabled)
                    }
                }
            }.font(.caption).accessibilityIdentifier("memorySources")
        }
    }
}

private struct KariMemoryDocumentView: View {
    @ObservedObject var memory: KariMemoryService
    let documentID: UUID
    @State private var deleting = false
    @State private var preview: [KariExtractedPart] = []
    @Environment(\.dismiss) private var dismiss
    private var document: KariMemoryDocument? { memory.documents.first { $0.id == documentID } }
    var body: some View {
        Form {
            if let document {
                Section {
                    Toggle(L("参与问答"), isOn: Binding(get: { document.enabled }, set: { value in Task { await memory.setEnabled(documentID, enabled: value) } })).disabled(!memory.mayEdit)
                    Text(L(document.status)); if !document.error.isEmpty { Text(document.error).foregroundStyle(.orange) }
                    Text(document.created, style: .date)
                }
                Section(header: Text(L("提取内容"))) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, part in VStack(alignment: .leading) { Text(part.location).font(.caption).foregroundStyle(.secondary); Text(part.text).textSelection(.enabled) } }
                }
                Button(L("删除资料"), role: .destructive) { deleting = true }.disabled(!memory.mayEdit)
            }
        }.navigationTitle(document?.name ?? L("资料"))
        .task(id: documentID) { preview = await memory.preview(documentID) }
        .alert(L("删除资料？"), isPresented: $deleting) {
            Button(L("删除"), role: .destructive) { Task { await memory.delete(documentID); dismiss() } }
            Button(L("取消"), role: .cancel) {}
        }
    }
}

private struct KariMemorySettingsView: View {
    @ObservedObject var app: KariAppModel
    @ObservedObject var memory: KariMemoryService
    @ObservedObject var downloads: KariModelDownloads
    @State private var draft = KariMemoryConfiguration()
    @State private var key = ""
    @State private var cellularModel: KariLocalEmbeddingModel?
    @State private var deletingModel: KariLocalEmbeddingModel?
    var body: some View {
        Form {
            Section(header: Text(L("向量化方式"))) {
                Picker(L("模式"), selection: $draft.mode) {
                    Text(L("跟随 AI 服务商")).tag("follow")
                    Text(L("其他向量服务／Ollama")).tag("service")
                    Text(L("手机本机模型")).tag("phone")
                }
                Text(L("当前索引") + ": " + memory.indexedModel).font(.footnote).foregroundStyle(.secondary)
                if draft.mode == "follow" {
                    Text(app.settings.configuration.preset.title)
                    Text(L("复用当前 AI 配置；无法启用时，可在此选择其他服务或本机模型，不影响聊天服务。"))
                }
                if draft.mode == "service" {
                    Picker(L("服务商"), selection: $draft.provider) {
                        Text("Gemini").tag("gemini"); Text("Vertex AI").tag("vertex"); Text("百炼 / Qwen").tag("qwen"); Text("Ollama").tag("ollama"); Text("Fireworks").tag("fireworks"); Text(L("兼容服务")).tag("openai-compatible")
                    }.onChange(of: draft.provider) { value in
                        key = ""
                        switch value {
                        case "gemini": draft.endpoint = "https://generativelanguage.googleapis.com"; draft.model = "gemini-embedding-001"
                        case "vertex": draft.endpoint = ""; draft.model = "gemini-embedding-001"
                        case "qwen": draft.endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1"; draft.model = "text-embedding-v4"
                        case "ollama": draft.endpoint = "http://"; draft.model = "embeddinggemma"
                        case "fireworks": draft.endpoint = "https://api.fireworks.ai/inference/v1"; draft.model = "accounts/fireworks/models/nomic-embed-text-v1"
                        default: draft.endpoint = "https://"; draft.model = ""
                        }
                    }
                    TextField(L("服务地址"), text: $draft.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L("向量模型"), text: $draft.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if draft.provider == "vertex" {
                        TextField(L("Google Cloud 项目"), text: $draft.project).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField(L("区域"), text: $draft.region).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text(L("使用已有 Google OAuth 授权。"))
                    } else { SecureField(L("API Key（留空保留）"), text: $key) }
                    if draft.provider == "ollama" { Text(L("填写电脑的局域网地址；模型需先在电脑安装。iPhone 的 localhost 不指向电脑。")) }
                }
                if draft.mode == "phone" {
                    Picker(L("模型"), selection: $draft.localModel) { ForEach(downloads.catalog) { Text($0.name).tag($0.id) } }
                }
                Button(L("保存配置")) {
                    do { try memory.saveServiceKey(key, for: draft); memory.configuration = draft; key = ""; memory.message = "配置已保存，修改向量模型后请重建索引" }
                    catch { memory.message = error.localizedDescription }
                }
                Button(L("测试已保存配置")) { Task { await memory.test(app.settings.configuration) } }
            }.disabled(!memory.mayEdit)
            Section(header: Text(L("手机模型下载")), footer: Text(L("自动按实际连通性选择来源，只使用版本及哈希一致的镜像。模型下载完成后需要通过加载测试。"))) {
                Picker(L("下载来源"), selection: $draft.source) { Text(L("自动")).tag("auto"); Text("Hugging Face").tag("hf"); Text("魔搭 ModelScope").tag("ms") }
                ForEach(downloads.catalog) { model in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.name).font(.headline).accessibilityIdentifier("localModel_" + model.id)
                        Text(L(model.subtitle) + " · " + ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file) + " · \(model.dimensions) " + L("维")).font(.caption).foregroundStyle(.secondary)
                        Text(model.license + (model.mirrors.isEmpty ? " · " + L("暂无核验通过的魔搭镜像") : " · Hugging Face / ModelScope")).font(.caption2).foregroundStyle(.secondary)
                        Link(L("模型来源与许可证"), destination: URL(string: "https://huggingface.co/\(model.repository)")!).font(.caption)
                        if downloads.activeID == model.id {
                            ProgressView(value: downloads.progress)
                            Button(L("暂停下载"), action: downloads.pause)
                        } else if downloads.installed(model) {
                            HStack {
                                Button(L("使用此模型")) { draft.mode = "phone"; draft.localModel = model.id; memory.configuration = draft; memory.message = "已选择本机模型，请重建索引" }
                                Spacer()
                                Button(L("删除"), role: .destructive) { deletingModel = model }
                            }.disabled(!memory.mayEdit)
                        } else {
                            Button(L("下载／继续")) { if downloads.cellular { cellularModel = model } else { downloads.download(model, source: draft.source) } }
                                .disabled(!memory.mayEdit || !downloads.activeID.isEmpty)
                        }
                    }.padding(.vertical, 4)
                }
                if !downloads.status.isEmpty { Text(downloads.status).font(.footnote).foregroundStyle(.secondary) }
            }
            if !memory.message.isEmpty { Text(LM(memory.message)).font(.footnote) }
        }.buttonStyle(.borderless).navigationTitle(L("向量服务与模型"))
        .onAppear { draft = memory.configuration }
        .alert(item: $cellularModel) { model in Alert(title: Text(L("使用蜂窝网络下载？")), message: Text(model.name + " · " + ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)), primaryButton: .default(Text(L("下载"))) { downloads.download(model, source: draft.source) }, secondaryButton: .cancel(Text(L("取消")))) }
        .confirmationDialog(L("删除已下载模型？"), isPresented: Binding(get: { deletingModel != nil }, set: { if !$0 { deletingModel = nil } }), titleVisibility: .visible) {
            Button(L("删除"), role: .destructive) { if let model = deletingModel { Task { do { try await downloads.remove(model) } catch { memory.message = error.localizedDescription } } }; deletingModel = nil }
            Button(L("取消"), role: .cancel) { deletingModel = nil }
        } message: { Text(L("资料保留。再次使用此模型前需要重新下载。")) }
    }
}
