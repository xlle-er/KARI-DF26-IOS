# iOS native architecture

**语言 / Language:** [简体中文](#简体中文) · [English](#english)

## English

The iOS app now starts in a programmatic UIKit scene hosting SwiftUI. It does not
start Capacitor, the frontend application, a backend server, or a JavaScript
provider/state/lifecycle layer. Its only WKWebView is an isolated local eyes and
motion component, packaged as approximately 144 KB of JavaScript/CSS/HTML.

## Ownership

| Module | Responsibility |
| --- | --- |
| `KariAppModel` | Main-actor companion lifecycle, cancellation, service coordination |
| `KariNativeShell`, `KariCompanionControls` | Native portrait/landscape companion UI |
| `KariRobotList` | Native nearby-device list, explicit selection, aliases and ownership bookmark |
| `KariBluetooth` | Main-actor Core Bluetooth discovery, connection, GATT writes, ACK matching, timeouts |
| `KariBodyProtocol` | Native command boundaries, stop framing, fragmented notification decoder |
| `KariCamera` | Serial-queue AVCaptureSession, preview, orientation, bounded JPEG sampling |
| `KariAudioOutput` | One AVAudioEngine for microphone and playback, PCM conversion and interruption handling |
| `KariPlaybackQueue` | Bounded PCM buffering, short scheduling window, completion accounting and recovery ordering |
| `KariLiveConfiguration` | Isolated, short audio-test setup without companion history or tools |
| `KariLiveService` | Direct URLSession WebSocket, setup acknowledgment, continuous media, tools and resumption |
| `KariAIRequest` | Native Gemini/Vertex/compatible/Ollama text and image requests |
| `KariSettings`, `KariCredentials` | Local public settings, Keychain credentials, native Google authorization |
| `KariFaceHost` | Local-only WebKit presentation and narrow command/photo bridge |

Root ownership is stable. Services are event driven; there is no 500 ms JS-to-Swift
UI polling. Camera setup and frame conversion run on a dedicated queue. High-rate
PCM counters do not publish SwiftUI changes. BLE RSSI is smoothed and updated at
most about once per second per device. Scanning stops after 15 seconds, on sheet
exit, on connect and on backgrounding.

### Portrait setup and landscape companion

The portrait home is a native setup screen with robot selection, AI configuration,
camera controls and tests. The original eye host retains its identity for motion
execution, but is invisible and excluded from accessibility in portrait.
Starting or connecting requests landscape through the hosting controller's supported
orientation mask and `UIWindowScene.requestGeometryUpdate` (iOS 16+). A failed start,
exit or background stop restores the portrait setup mask; UIKit updates camera
orientation after the transition. On iOS 15 the legacy supported-orientation
rotation path applies, and physical rotation can be necessary.

Landscape companion retains a small native live-camera preview at the upper left
while the camera is running, even after the controls fade. It uses the existing
AVCaptureSession, not the one-frame-per-second AI JPEG feed. The preview disappears
when capture stops and does not consume taps intended to reveal controls. Tapping the
screen reveals a native **退出陪伴** button and media controls. Exit stops the session
and requests portrait immediately while body-stop acknowledgment completes. Controls
remain visible for text conversations and VoiceOver. Settings and device lists are
opened from portrait. Orientation denial leaves an actionable notice and the exit
button available. Physical scene rotation still needs iPhone verification.

### Speech buffering and recovery

Both AI testing and normal Live conversations use the same playback queue. Incoming
24 kHz PCM is split into slices of at most 200 ms. An 80 ms initial prebuffer absorbs
small arrival variations; only 600 ms is scheduled on AVAudioPlayerNode at a time.
The remaining audio is held in a bounded queue (60 seconds, approximately 5.8 MB
of Float32 samples). A 30-second burst no longer trips the former 20-second guard.
This buffer does not deliberately delay the start until the full reply arrives.

A main-run-loop watchdog checks playback every 250 ms while audio is pending.
After two seconds without a playback completion, or if the engine/player stops,
it attempts to restart output while retaining the microphone tap and Live socket.
Only the unconfirmed scheduling window is replayed, so recovery can repeat up to
600 ms of speech. Old completion callbacks are invalidated before stopping the
node. Recovery is limited to two attempts per continuously buffered episode.

If output cannot recover or the memory bound is reached, the remaining audio for
that reply is discarded and a single actionable error is shown; microphone,
camera and Live connection are not torn down. OS audio interruptions still follow
AVAudioSession interruption handling. This is not a guarantee of uninterrupted
playback under every route or system interruption.

AI testing uses an independent one-sentence system instruction, no tools or
conversation resumption, and a 256-token output limit. Switching between test and
companion sessions clears the resume handle. Queue ordering, bounded scheduling,
burst draining, stale callbacks, recovery, cancellation and test configuration are
covered by the native Swift checks. Device speaker/microphone behavior still
requires testing on iPhone.

## Preserved code

`FaceSource/mobile/face/entry.js` imports the original `FaceSource/frontend/js/ui/faceCanvas.js`, eye styles,
`scenarioCatalog.js`, scenario actions, `ScenarioFrameSequencer`, `CommandQueue`,
`ESP32Client` protocol builder and motion safety validator. These remain the source
of eye behavior and movement choreography. The transport adapter forwards
commands to native Core Bluetooth and only resolves a write after a matching
firmware ACK. Native validation bounds physical commands independently.

The resource builder bundles only those imports. The page has no AI, microphone,
camera, account, BLE scanning, application lifecycle or settings implementation.
Its CSP disallows network connections, navigation stays within the resource
directory, and the bridge supports only body commands and camera snapshots.

## Bluetooth identity and connection

Each discovered device is a stable Core Bluetooth UUID row with advertising name,
an eight-character identifier suffix, smoothed RSSI, signal label and connection
state. RSSI is not presented as a measured physical distance. Rows keep their
identity and discovery order so fluctuating signal strength does not move a
connect button under a finger.

Users explicitly choose a row; the app does not auto-connect to the strongest
signal. A local alias, explicit **设为我的机器人** bookmark, and a separate **上次连接**
label help identify devices with the same advertising name. The UUID and alias
are local to that phone; no Bluetooth MAC address is claimed. The current two-motor chassis does not use identification nods or obsolete head-pitch commands. Device identification uses the list and local aliases.

Connection includes service/characteristic discovery, notifications and ping/config
requests. It has a 12-second connection timeout, cancellation, serialized MTU-sized
writes, a bounded queue, five-second command confirmation timeouts and notification
reassembly across UTF-8 byte boundaries. Emergency stop cancels queued motion,
separates a partially written JSON frame, and coalesces simultaneous stop requests.
Movement faults disarm motion while leaving the AI conversation available.

## Manual remote

`KariRemoteControl` coordinates a native joystick/direction pad, a single gesture
owner, short motion leases and stop barriers. Its transport closures are main-actor
isolated and injectable for deterministic tests. Standalone remote is a portrait
sheet and starts no AI/camera; companion remote is an inline landscape panel that
keeps the eyes, existing media and camera preview alive. The panel never auto-hides.

Taking manual control cancels the previous scenario and clears AI movement
permission. Native JS/body and AI scenario entry points reject body actions while
manual control is presented. Voice stop requests also invalidate manual input;
closing the panel does not restore AI movement permission automatically.

Joystick input uses a 12% radial dead zone and scales the combined linear/angular
magnitudes to the selected relative speed (default 0.15, range 0.05–0.30). Positive
linear is forward and positive angular is right, matching the original scenarios.
Each command has a 400 ms duration and 60 ms ramp. Commands wait for their ACK,
then wait 100 ms before sampling the newest input; no intermediate target queue
is kept. This limits frequency rather than guaranteeing an exact 10 Hz rate.

Remote commands and stops use 250 ms deadlines. BLE deadlines start when queued,
including a stop waiting behind an in-flight GATT write. A cancelled write callback
releases its barrier without completing an unrelated replacement command. On
transport timeout the app disconnects, requests no more motion and relies on the
firmware's finite command duration and disconnect-stop behavior. Firmware stopping
of motor output is not proof of an instantaneous physical stop.

Release, cancelled touches, mode changes, close, backgrounding and faults invalidate
the control epoch. A held finger or late ACK cannot restart cancelled motion. A
new gesture is required after a stop; connection failure requires retry. UI handles
multitouch ownership and prevents a finger held during preparation from arming
itself when preparation completes. VoiceOver actions issue short bounded pulses.

Tests cover mapping, bounds, stop admission, cancellation, latest-target behavior,
late ACKs, mode changes, connection loss and failed preparation using a fake robot.
Core Bluetooth radio timing, physical directions and stopping remain device tests.
No firmware changes or flashing are part of this implementation.

## Media and lifecycle

Start/stop/testing are explicit native phases. A generation token invalidates old
asynchronous startup, test and provider responses. Temporary inactive states do
not stop the app; actual backgrounding cancels capture, invalidates tools, releases
the idle timer and sends body stop. Each new companion session enables motion permission for the connected robot by default; disconnect, body failure, companion stop or manual takeover revoke it. Body idle remains separately disabled by default.

The camera samples JPEG at no more than one frame per second. Native microphone
input and playback share an AVAudioEngine with voice processing; incoming speech
does not replace or deactivate the recording session. Camera frames continue
during model output and tool turns. Capture can be restored without opening a new
AI connection when the existing socket is healthy. Camera permission refusal can
fall back to voice-only companionship.

AI starts sending microphone data only after setupComplete. Speech interruption
clears only the output buffers, preserving capture. Cancelled tool IDs do not
receive late responses. The socket writer is ordered and bounded; video is dropped
before a backlog can grow indefinitely. Explicit stop and provider changes close
the socket and deactivate audio. Credentials use request headers, not URLs.

Text conversations attach an image only after an explicit image-button selection;
text-only model defaults therefore work with the camera enabled. Text-provider
action responses are decoded in Swift against the original scenario allowlist and
still pass through native motion permission and command validation. AI connection
tests never execute model-requested movement. Stop phrases disarm body movement
without ending the conversation.

## Localization and conversation language

`KariLocalization` owns a persisted System default / Simplified Chinese / English
selection. Standard `.lproj/Localizable.strings` resources live in the Swift Package;
localized permission descriptions live in the application target. Native views
observe language changes without recreating the app model or discarding a settings
draft. Services retain source messages; known status and error strings are translated
when displayed. Model replies, user text, custom model IDs and robot aliases remain
opaque. System permission sheets follow iOS system/per-app language preferences.

`KariConversationLanguage` builds a shared policy for Live and text providers:
explicit user language requests take precedence, followed by the latest spoken or
typed input; UI language is only the fallback. The policy applies on every turn.
Live setup removes the previous language block and any pinned speech language code,
while retaining identity, tool and safety rules. Text providers send policy as a
system instruction separately from user content. Changing interface language clears
resumption across subsequent Live sessions; it does not tear down a running call.
Language selection is disabled outside the idle phase. Offline mode recognizes
Chinese/English for fixed greetings; other languages require an AI provider.

## Models and migration

Provider presets fill a default model and offer a menu plus custom input. Existing
custom models are preserved when migrating `CapacitorStorage.kari.providers.v1` to
native version-2 preferences. The standalone copy uses a neutral Keychain service namespace and ships no saved
credentials or preference files. Users configure their own keys. Public preferences
contain no keys. Local provider models still need installation on the host.

Presets checked on 2026-10-15:

| Provider | Default text model | Default Live model |
| --- | --- | --- |
| Gemini | `gemini-3.8-flash` | `gemini-3.8-live` |
| Vertex | `gemini-3.8-flash` | `gemini-3.8-live` (`us-central1` for a fresh profile) |
| Qwen | `qwen-plus` | — |
| Groq | `openai/gpt-oss-120b` | — |
| Fireworks | `accounts/fireworks/models/llama-v3p3-70b-instruct` | — |
| Ollama | `qwen3:8b` | — |

References: [Gemini Flash](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash),
[Gemini Live](https://ai.google.dev/gemini-api/docs/live-api/capabilities),
[Vertex Live](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-8-live),
[Qwen](https://help.aliyun.com/zh/model-studio/qwen-plus),
[Groq](https://console.groq.com/docs/models),
[Fireworks](https://fireworks.ai/models/fireworks/llama-v3p3-70b-instruct),
[Ollama](https://ollama.com/library/qwen3).
These are convenience presets, not evidence that every account has model access.

## Build and validate

```sh
npm run build:resources
python3 scripts/test-native.py
npm run test:face
xcodebuild -project KARI.xcodeproj -scheme KARI \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath build/ios-native CODE_SIGNING_ALLOWED=NO build
```

The canonical Swift sources are under `Native/Sources/KariNative`; Xcode compiles
them directly. Bundled resources are committed so Node.js is optional for normal
Xcode builds. Only changes to `FaceSource/` require `npm ci` followed by
`npm run build:resources`. Resource generation never copies credentials or settings.

Native Swift tests exercise migration, default models, request building, response
validation, secret redaction, motion boundaries, stop framing and notification
decoding. Browser tests exercise the actual preserved eye/motion bundle with a
simulated native ACK transport. Unsigned device compilation verifies Swift and
resource linkage. These do not validate real BLE radio behavior, physical movement,
on-device audio/camera operation or measured cold-launch timing. Verify those on
an iPhone after installing your own signed build.

## 简体中文

### 当前 iOS 原生架构

应用通过程序化 UIKit Scene 承载 SwiftUI，不启动 Capacitor、完整前端应用、后端或 JavaScript 提供商/状态/生命周期层。唯一 WKWebView 是隔离的本地眼睛与动作组件；资源体积以构建产物为准。

### 所有权

| 模块 | 职责 |
| --- | --- |
| KariAppModel | 主 actor 上的陪伴生命周期、取消和服务协调 |
| KariNativeShell / KariCompanionControls | 竖屏设置及横屏陪伴原生界面 |
| KariRobotList | 附近设备、明确选择、别名和“我的机器人”书签 |
| KariBluetooth | Core Bluetooth 扫描、连接、串行写入、ACK 关联及超时 |
| KariBodyProtocol | 命令边界、停止分帧、通知重组 |
| KariCamera | 独立串行队列上的 AVCaptureSession、预览、方向及有界 JPEG 采样 |
| KariAudioOutput | 共用 AVAudioEngine 的麦克风、播放、PCM 转换和中断 |
| KariPlaybackQueue | 有界 PCM 缓冲、短调度窗口、完成统计和恢复顺序 |
| KariLiveConfiguration | 无历史/工具的独立短音频测试配置 |
| KariLiveService | 直接 URLSession WebSocket、setup 确认、连续媒体、工具和恢复 |
| KariAIRequest | Gemini / Vertex / 兼容服务 / Ollama 的文字与图片请求 |
| KariSettings / KariCredentials | 普通本地设置、Keychain 凭据、原生 Google 授权 |
| KariFaceHost | 仅本地 WebKit 与窄命令/照片桥接 |

根所有权稳定，服务由事件驱动，不使用每 500 ms 的 JS→Swift UI 轮询。相机配置与转换在专用队列，高频 PCM 计数不直接发布 SwiftUI 变更。RSSI 平滑后每设备最多约每秒更新；扫描在 15 秒、离开列表、连接或进入后台时停止。

### 竖屏设置与横屏陪伴

原生设置页提供设备选择、AI 配置、相机与测试。眼睛承载保持动作执行身份，在竖屏时不可见并排除无障碍。启动/连接通过控制器方向掩码与 iOS 16+ 的 UIWindowScene.requestGeometryUpdate 请求横屏；启动失败、退出或后台停止恢复竖屏，转场后更新相机方向。iOS 15 使用旧方向路径，可能需要实际旋转。

横屏左上角的原生相机预览共享 AVCaptureSession，不是每秒一帧的 AI JPEG。控制层淡出后仍可预览；停采集时隐藏，不截获唤出控制的点击。点击显示退出和媒体控制；退出立即停止会话并请求竖屏，身体停止 ACK 可随后完成。文字和 VoiceOver 保持控制可见；方向请求被拒绝时保留可操作提示与退出入口。真实旋转行为需设备验证。

### 语音缓冲与恢复

AI 测试与普通 Live 共用播放队列。24 kHz PCM 分片最多 200 ms，初始预缓冲 80 ms，一次仅向播放器安排 600 ms；其余队列最多 60 秒（Float32 约 5.8 MB）。30 秒连续到达不再触发旧 20 秒限制，也不会等待整段回复才开始播放。

有待播音频时主运行循环每 250 ms 检查。两秒无完成回调或引擎停止会尝试恢复输出，保留麦克风 tap 与 Live socket。恢复只重播尚未确认的调度窗口，最多可能重复 600 ms；停止节点前使旧回调失效。每个连续缓冲阶段最多尝试两次。无法恢复或超出内存上限时丢弃该回复剩余音频并提示一次，保留麦克风、相机和 Live；系统音频中断仍遵守 AVAudioSession。不能保证所有路由/中断下绝不中断。

AI 测试使用独立单句系统指令，无工具与恢复句柄，输出上限 256 token；切换测试/陪伴清除恢复。原生检查覆盖顺序、有界调度、突发排空、旧回调、恢复和取消；真实扬声器/麦克风需手机验证。

### 保留的眼睛与动作

FaceSource/mobile/face/entry.js 从原始眼睛样式、faceCanvas、scenarioCatalog、动作、ScenarioFrameSequencer、CommandQueue、ESP32Client 和安全校验构建资源。适配器转发给原生蓝牙，仅匹配固件 ACK 后完成写入；原生再次限制物理命令。

资源页不实现 AI、麦克风、相机、账号、扫描、生命周期或设置。CSP 禁止网络连接，导航限制在资源目录；桥接仅处理身体命令和快照。

### 蓝牙身份与连接

列表以稳定 Core Bluetooth UUID 标识每个设备，显示广播名、八字符 ID 后缀、平滑 RSSI、信号标签和连接状态。RSSI 不等于实测距离；保持发现顺序，避免信号变化使连接按钮移动。

用户明确选择设备，不自动连接最强信号。本机别名、“设为我的机器人”和“上次连接”标签帮助区分同名设备；不声称 UUID 是蓝牙 MAC。当前底盘仅有双电机，不通过自动点头识别，也不使用已废弃的俯仰舵机命令。

连接包含服务/特征发现、通知与 ping/config。连接超时 12 秒、命令确认超时 5 秒，写入串行按 MTU 分块，队列有界，UTF-8 通知跨字节重组。急停取消排队动作、分隔部分 JSON 帧并合并并发停止。身体故障撤销运动，但可保留 AI 对话。

### 手动遥控

KariRemoteControl 在主 actor 协调摇杆/方向键、单一手势、短租约与停止屏障；可注入传输用于确定性测试。独立遥控为竖屏 sheet，不启动 AI/相机；陪伴遥控为横屏内联覆盖，保留眼睛、媒体与预览，面板不自动隐藏。

接管取消旧场景并清除 AI 运动许可，遥控显示期间拒绝 JS/AI 身体入口；语音停止也撤销手动输入。关闭不会自动恢复 AI 许可。

摇杆径向死区 12%，线性/角向总量不超过相对速度（0.05–0.30，默认 0.15）；正线性向前、正角向向右。单命令 400 ms、ramp 60 ms；ACK 后再等 100 ms 采样最新输入，不排历史目标，因此不保证严格 10 Hz。

遥控命令和停止截止时间为 250 ms，从进入 BLE 队列计时，包含等待正在进行写入的时间。取消回调仅释放自己的屏障，不完成替代命令。超时断连并停止继续发送，最终依赖固件有限时长/断连停止；输出停止不证明机械瞬停。

松手、取消、模式变化、关闭、后台、故障使代次失效；按住的手指/旧 ACK 不能恢复旧动作。准备中按住不能自行解锁，停止后需新手势，连接失败需重试。VoiceOver 使用短脉冲。测试覆盖映射、边界、取消、最新目标、旧 ACK、模式、断连与准备失败；真实无线时序和机械方向仍需实体设备。

### 媒体与生命周期

启动/停止/测试是原生明确阶段；代次丢弃旧异步启动、测试与提供商响应。短暂 inactive 不结束会话，实际后台取消采集/工具、释放常亮锁并请求停止。新陪伴会话默认允许已连接机器人的动作；断线、身体故障、停止陪伴或手动接管撤销许可。身体待机动作仍默认关闭。

JPEG 最多每秒一帧；麦克风和播放共享启用语音处理的 AVAudioEngine，播放不替换录音会话。模型输出和工具执行期间相机继续。socket 健康时恢复采集不建立第二连接，拒绝相机可降级纯语音。

仅 setupComplete 后上传声音。插话只清播放缓冲；已取消工具不接收迟到响应。socket 写入有序有界，拥塞优先丢视频；明确停止/切提供商关闭 socket 并停音频。凭据放请求头，不放 URL。

文字仅在明确选择图片后附图；Swift 校验模型动作白名单、运动许可和参数，连接测试不执行动作。停止短语只撤销身体运动而不必终止对话。

### 本地化和对话语言

KariLocalization 持久化“跟随系统/简体中文/English”；SPM 的 .lproj/Localizable.strings 承载界面文案，应用 target 承载权限说明。语言变更不重建 AppModel 或丢弃草稿。服务保存源消息，已知状态/错误显示时翻译；用户文字、模型回复、自定义模型 ID 和别名保持原样。权限弹窗遵循系统/单 App 语言。

KariConversationLanguage 每轮优先明确语言要求，其次最新语音/文字，最后界面语言。Live setup 去掉旧语言块及固定 speech language code，保留身份/工具/安全规则。文字模式把语言策略作为独立系统指令。改界面语言清除后续 Live 恢复句柄，不拆除正在通话的连接；非 idle 阶段禁用语言选择。离线固定问候支持中英，其他语言需要 AI。

### 模型与配置迁移

预设提供默认模型、菜单和自定义输入。内部同身份配置格式迁移可保留自定义模型，但 KARI 新应用身份不读取历史品牌的凭据；请重新配置。普通设置不含密钥，凭据进 Keychain；本地模型仍需在模型主机安装。

代码中的便利预设如下，不保证每个账户都能调用；以当前源码与提供商账户权限为准：

| 提供商 | 文字模型 | Live 模型 |
| --- | --- | --- |
| Gemini | gemini-3.8-flash | gemini-3.8-live |
| Vertex | gemini-3.8-flash | gemini-3.8-live；新配置默认 us-central1 |
| Qwen | qwen-plus | — |
| Groq | openai/gpt-oss-120b | — |
| Fireworks | accounts/fireworks/models/llama-v3p3-70b-instruct | — |
| Ollama | qwen3:8b | — |

对应提供商参考链接保留在英文模型章节中；默认模型名是代码配置值，不是远程可用性验证结果。

### 构建与验证

```sh
npm run build:resources
python3 scripts/test-native.py
npm run test:face
xcodebuild -project KARI.xcodeproj -scheme KARI -destination 'generic/platform=iOS' -configuration Debug -derivedDataPath build/ios-native CODE_SIGNING_ALLOWED=NO build
```

规范业务源码位于 Native/Sources/KariNative，Xcode 直接编译。资源已提交，普通构建不必安装 Node；修改 FaceSource 后才需 npm ci 与资源重建。生成流程不复制凭据/个人设置。

原生测试覆盖内部配置格式迁移、模型预设、请求/响应校验、脱敏、运动边界、停止分帧及通知重组；浏览器使用真实眼睛资源和模拟 ACK；无签名编译验证链接。这些不能替代 BLE、机械运动、音视频、冷启动实测，应使用自己的签名安装到 iPhone 后验收。
