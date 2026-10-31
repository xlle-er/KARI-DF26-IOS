import SwiftUI
import UniformTypeIdentifiers

struct KariJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct KariPersonalityView: View {
    @ObservedObject var features: KariCompanionFeatures
    @State private var draft = PersonalityProfile()
    @State private var importing = false
    @State private var exporting = false
    @State private var document = KariJSONDocument()
    @State private var message = ""
    private let traits = [("curiosity", "好奇"), ("gentleness", "温柔"), ("playfulness", "玩心"), ("shyness", "害羞"), ("affection", "亲近"), ("independence", "独立"), ("talkativeness", "表达欲"), ("caution", "谨慎")]
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L("身份"))) {
                    TextField(L("名字"), text: $draft.name).accessibilityIdentifier("personalityName")
                    TextField(L("身份描述"), text: $draft.identity)
                    TextField(L("代词"), text: $draft.pronouns)
                }
                Section(header: Text(L("人格"))) {
                    ForEach(traits, id: \.0) { key, title in
                        KariParameterSlider(title: L(title), value: Binding(get: { draft.coreTraits[key] ?? 0.5 }, set: { draft.coreTraits[key] = $0 }))
                    }
                }
                Section(header: Text(L("语言风格"))) {
                    Toggle(L("简短回复"), isOn: $draft.speechStyle.shortReplies)
                    Toggle(L("避免过度解释"), isOn: $draft.speechStyle.avoidOverExplaining)
                    KariParameterSlider(title: L("温暖程度"), value: $draft.speechStyle.warmth)
                    KariParameterSlider(title: L("幽默程度"), value: $draft.speechStyle.humor)
                    KariParameterSlider(title: L("诗意表达"), value: $draft.speechStyle.poeticIdentity)
                }
                Section {
                    NavigationLink(L("行为与待机")) { KariBehaviorView(features: features) }.accessibilityIdentifier("behaviorSettingsLink")
                    NavigationLink(L("待机场景")) { KariIdleScenesView(features: features) }.accessibilityIdentifier("idleScenesLink")
                    NavigationLink(L("生命状态")) { KariLifeStateView(features: features) }.accessibilityIdentifier("lifeStateLink")
                    Button(L("保存人格")) { save() }.accessibilityIdentifier("savePersonality")
                    Button(L("重置人格"), role: .destructive) { draft = PersonalityProfile(); save() }
                    Button(L("导入人格 JSON")) { importing = true }
                    Button(L("导出人格 JSON")) { do { document = .init(data: try features.profile.exported()); exporting = true } catch { message = L("人格文件无效，原配置已保留") } }.accessibilityIdentifier("exportPersonality")
                    if !message.isEmpty { Text(message).font(.footnote).accessibilityIdentifier("personalityMessage") }
                }
            }.navigationTitle(L("人格"))
        }.navigationViewStyle(.stack)
        .onAppear { draft = features.profile }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65_536 else { throw PolicyError.invalidProfile }
                try features.importProfile(Data(contentsOf: url)); draft = features.profile; message = L("人格已保存")
            } catch { message = L("人格文件无效，原配置已保留") }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "KARI-personality") { result in if case .failure = result { message = L("导出未完成") } }
    }
    private func save() {
        do { try features.saveProfile(draft); draft = features.profile; message = L("人格已保存") }
        catch { message = L("人格文件无效，原配置已保留") }
    }
}

struct KariParameterSlider: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(value, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: $value, in: 0...1).accessibilityLabel(title)
        }.padding(.vertical, 4)
    }
}

struct KariBehaviorView: View {
    @ObservedObject var features: KariCompanionFeatures
    @State private var draft = PersonalityProfile()
    @State private var message = ""
    private let styles = [("movementSoftness", "动作柔和度"), ("reactionSpeed", "反应速度"), ("idleActivity", "待机活跃度"), ("emotionalExpressiveness", "情绪表达"), ("hesitation", "犹豫程度"), ("personalSpaceRespect", "空间尊重")]
    var body: some View {
        Form {
            Section { NavigationLink(L("待机场景")) { KariIdleScenesView(features: features) } }
            Section(header: Text(L("本地行为"))) {
                Toggle(L("启用规则待机"), isOn: $features.behavior.enabled)
                Toggle(L("允许待机身体动作"), isOn: $features.behavior.idleBody)
                Text(L("待机身体动作仍受本次运动许可限制")).font(.footnote)
                Stepper(value: $features.behavior.sleepAfter, in: 10...600, step: 10) { Text(L("静默休眠秒数") + ": \(Int(features.behavior.sleepAfter))") }
                VStack { Text(L("待机间隔倍率") + String(format: " %.2f", features.behavior.idleGapMultiplier)); Slider(value: $features.behavior.idleGapMultiplier, in: 0.25...5) }
            }
            Section(header: Text(L("主动 AI"))) {
                Toggle(L("启用主动思考"), isOn: $features.behavior.proactiveAI)
                Toggle(L("允许主动表达"), isOn: $features.behavior.proactiveExpression)
                Stepper(value: $features.behavior.thoughtsPerMinute, in: 1...12) { Text(L("每分钟思考上限") + ": \(features.behavior.thoughtsPerMinute)") }
                Stepper(value: $features.behavior.expressionInterval, in: 60...600, step: 30) { Text(L("主动表达最短间隔秒数") + ": \(Int(features.behavior.expressionInterval))") }
                Text(L("主动思考会额外调用当前 AI 服务；Live 使用语音，文字模式显示消息。表达欲越低，实际表达间隔越长。")).font(.footnote)
            }
            Section(header: Text(L("行为风格"))) {
                ForEach(styles, id: \.0) { key, title in KariParameterSlider(title: L(title), value: Binding(get: { draft.behaviorStyle[key] ?? 0.5 }, set: { draft.behaviorStyle[key] = $0 })) }
                Button(L("保存行为风格")) { do { var value = features.profile; value.behaviorStyle = draft.behaviorStyle; try features.saveProfile(value); message = L("人格已保存") } catch { message = L("人格文件无效，原配置已保留") } }
                if !message.isEmpty { Text(message) }
            }
        }.navigationTitle(L("行为与待机")).onAppear { draft = features.profile }
    }
}

struct KariVisionContent: View {
    @ObservedObject var app: KariAppModel
    @ObservedObject var features: KariCompanionFeatures
    @ObservedObject var vision: KariVisionService
    @ObservedObject var camera: KariCamera
    var body: some View {
                VStack(spacing: 18) {
                    ZStack(alignment: .topLeading) {
                        if camera.running {
                            KariCameraPreview(camera: camera)
                            GeometryReader { geometry in
                                ForEach(vision.detections) { detection in
                                    let box = detection.box.display(mirrored: camera.front)
                                    Button { features.select(detection) } label: {
                                        Rectangle().stroke(features.follow.target.map { $0.label == detection.label && $0.box.iou(detection.box) > 0.9 } == true ? Color.cyan : Color.white, lineWidth: 2)
                                            .overlay(Text(detection.label).font(.caption).padding(3).background(Color.black.opacity(0.7)), alignment: .topLeading)
                                    }
                                    .frame(width: max(1, CGFloat(box.width) * geometry.size.width), height: max(1, CGFloat(box.height) * geometry.size.height))
                                    .position(x: CGFloat(box.x + box.width / 2) * geometry.size.width, y: CGFloat(box.y + box.height / 2) * geometry.size.height)
                                    .accessibilityLabel(detection.label + L("选择目标"))
                                }
                            }
                        } else { Color.black; Image(systemName: "camera").font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.aspectRatio(camera.previewAspect, contentMode: .fit).clipped().clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityIdentifier("visionPreview")
                    Toggle(L("本地识别"), isOn: Binding(get: { vision.enabled }, set: features.setDetection)).accessibilityIdentifier("enableDetection")
                    HStack {
                        Button(L("开启相机")) { if !camera.running { app.toggleCameraIfNeeded() } }
                        Spacer(); Button(L("切换镜头"), action: app.switchCamera)
                    }
                    ForEach(vision.detections) { value in Button { features.select(value) } label: { HStack { Text(value.label); Spacer(); Text(value.score, format: .percent.precision(.fractionLength(0))) } } }
                    Text(LM(features.followMessage)).font(.callout).accessibilityIdentifier("followStatus")
                    Button(L("设为参考"), action: features.calibrate).disabled(features.follow.target == nil)
                    Toggle(L("陪伴时跟随此目标"), isOn: Binding(get: { features.followOnStart }, set: features.armFollow)).disabled(features.follow.reference == nil)
                    Text(L("实验性相对跟随，不测距、不避障、不防跌落。选好目标后，用底部播放按钮开始陪伴。")).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("visionFooter")
                    if !vision.message.isEmpty { Text(LM(vision.message)).foregroundStyle(.orange) }
                    if !features.message.isEmpty { Text(LM(features.message)).font(.footnote) }
                }.padding(20).buttonStyle(.borderless)
    }
}

struct KariDiagnosticsView: View {
    @ObservedObject var app: KariAppModel
    @ObservedObject var features: KariCompanionFeatures
    @State private var exporting = false
    @State private var document = KariJSONDocument()
    var body: some View {
        List {
            Section(header: Text(L("组件状态"))) {
                ForEach(features.diagnostics.keys.sorted(), id: \.self) { key in HStack { Text(L(key)); Spacer(); Text(features.diagnostics[key] ?? "—").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
            }
            Section(header: Text(L("测试"))) {
                Button(L("测试声音"), action: app.testSound)
                Button(L("AI 测试"), action: app.testAI)
                Button(L("动作测试"), action: app.testMotion).disabled(!app.body.isConnected)
                Text(L("规则和主动思考在陪伴时运行，结束后可在此查看决策记录。")).font(.footnote)
                Button(L("清理记录"), action: features.clearJournal)
                Button(L("导出脱敏诊断")) { if let data = try? features.diagnosticData() { document = .init(data: data); exporting = true } }
            }
            Section(header: Text(L("最近决策"))) {
                ForEach(features.decisions.reversed()) { item in VStack(alignment: .leading) { Text(item.kind); Text(item.detail).font(.caption).foregroundStyle(.secondary) } }
            }
            Section(header: Text(L("最近事件"))) {
                ForEach(features.events.reversed()) { item in Text(item.kind).font(.caption) }
            }
        }.navigationTitle(L("诊断"))
        .task { while !Task.isCancelled { features.refreshDiagnostics(); try? await Task.sleep(nanoseconds: 1_000_000_000) } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "KARI-diagnostics") { _ in }
    }
}
