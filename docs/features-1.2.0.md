# iOS 1.2.0 功能说明

**语言 / Language:** [简体中文](#简体中文) · [English](#english)

## 简体中文

业务源码位于 `Native/Sources/KariNative/`，眼睛与动作桥接来源位于 `FaceSource/`。iOS 15+；iOS 26+ 使用原生 Liquid Glass，旧系统使用系统材质。

## 页面与功能

| 页面 | 功能 |
| --- | --- |
| 机器人 | 电机点动与方向校准、接线、配网、OTA、连接引导；右上角遥控器 |
| 人格 | 名字、身份、代词、八项人格、语言风格；保存/重置；系统文件 JSON 导入与导出；行为与待机二级页面 |
| 视觉 | 共用相机预览、切镜头、本地目标检测、检测框与列表选目标、参考面积、实验性跟随预设 |
| 设置 | 机器人连接、AI 服务、语言、权限、诊断与组件测试、脱敏导出 |

底栏顺序：机器人、人格、▶、视觉、设置。播放按钮是操作按钮；悬浮胶囊四边 8pt 留白，五项基础高度 54pt。开始后横屏显示原有眼睛，隐藏配置页面与底栏；点按显示控制，中央停止按钮结束后回到原页面。陪伴中的遥控使用覆盖层。

## 八项新增能力

1. **人格**：与 Web 的身份、八项特征、行为和语言 JSON 字段对齐。校验类型、范围和大小；错误导入不会覆盖当前配置。安全边界固定执行。文字与 Live 都注入同一份已保存人格；保存后清除旧 Live 恢复句柄。
2. **行为调参**：待机活跃度调整间隔，反应速度和犹豫调整延迟，动作柔和度与空间尊重降低速度并增加缓动，情绪表达决定规则表情，表达欲影响主动表达间隔。
3. **待机调度**：默认规则待机开启，默认身体动作关闭。静默休眠和交互唤醒；语音、遥控、显式动作、跟随、升级或后台让位。
4. **事件决策**：会话、用户活动、视觉类别变化、规则与 AI 结果记录为有限事件；高频视觉事件合并。动作必须通过同一会话的运动仲裁。
5. **可选主动 AI**：默认关闭，使用当前提供商文字接口；默认最多两次/分钟、串行，失败回退规则。主动表达另设开关且默认关闭；最小 60 秒间隔，Live 走现有语音通道，文字模式显示消息。
6. **本地检测**：Android 相同 EfficientDet-Lite0 int8，置信度 0.6、最多 12 框、最高 10 Hz。单一相机，独立串行推理、忙时丢帧；温度高降到 2 Hz 并停止跟随。关闭、切镜头和后台清理结果。模型及 SPM 固定 revision 见 `model-manifest.json`。
7. **实验性跟随**：选目标→设参考→开启跟随预设→播放。14% 横向阈值；面积小于参考 0.8 前进，达到 0.95 停止；不倒车。150ms 有限脉冲；检测超过 300ms、歧义、断线、切镜头、手动接管或停止均取消且不自动恢复。旋转转换目标框，等新方向帧，未及时重获同一目标则取消。
8. **集中诊断**：会话、Live、录放音、路由、缓冲、相机、检测、跟随、运动来源、事件与原因。最多每秒刷新；最近 500 事件、100 决策。导出不含密钥、密码、原始音视频或聊天原文。

## 运动与取消

停止优先，其余为手动遥控、测试、显式动作、跟随、待机。每次取得控制权先通过停止屏障；租约带代数；旧 ACK、旧 JS 回调和旧响应不能恢复已取消运动。跟随不接受 AI 或待机身体动作争用。未确认停止时拒绝新动作。

## 验证与限制

测试覆盖人格与 JSON 校验、调度、停止屏障、慢 ACK、目标歧义与过期、模型样本、真实相机共用、诊断隐私、原生导航、错误提示与保留陪伴。设备测试需自行设置签名并指定设备；网络与麦克风测试单独显式启用。

本地跟随是实验功能，不测距、不避障、不防跌落。iOS 15 为最低编译目标，不代表已在所有系统和机型上完成运行验收。高音量、环境噪声、耳机路由、BLE/配网/OTA 及长期温升仍需在实际硬件上验证。

Live 使用 LOW 语音起止敏感度、300 ms 前置保留和 700 ms 静默结束阈值，降低误打断；保留真实插话。错误会明确显示，实时 AI 连接失败或重试失败不退出陪伴。音频诊断只记录计数、时长和声级，不保存原始音视频或聊天原文。

## English

Business source is `Native/Sources/KariNative/`; eyes and action bridges originate in `FaceSource/`. Minimum iOS target is 15. iOS 26+ uses native Liquid Glass where appropriate; older versions use system materials.

### Pages and navigation

| Page | Features |
| --- | --- |
| Robot | Motor tests/calibration, wiring, network, OTA, connection guide and remote |
| Personality | Name, identity, pronouns, eight traits, language style, save/reset, native JSON files and behavior/idle subpages |
| Vision | Shared camera, lens switching, detection, target selection, reference area and experimental following |
| Settings | Robot connection, AI, language, permissions, diagnostics, tests and redacted export |

The bottom order is Robot, Personality, play, Vision, Settings; play is an action, not a fifth page. The floating capsule uses 8 pt outer spacing and 54 pt base items. Companionship shows eyes in landscape and hides setup/navigation. Tap for controls; stopping returns to the previous page. The companion remote is an overlay.

### Eight capabilities

1. Personality aligns identity, eight traits, behavior and language JSON with Web. Validate type/range/size; failed imports preserve settings and cannot weaken safety. Text/Live share saved personality; saving clears old resumption.
2. Behavior tuning affects idle gaps, reaction/hesitation delay, motion gentleness/space-respect speed and ramp, emotional expressions and proactive-expression spacing.
3. Rule idle is on; body idle is off. Quiet sleep/interaction wake yields to speech, remote, explicit actions, following, upgrades and backgrounding.
4. Bounded events record sessions, user activity, visual class changes and rule/AI outcomes. High-frequency vision events coalesce; actions use the same session arbiter.
5. Optional proactive thought/expression are separately off. Thought uses the current text provider, serialized at most twice/minute by default, with rule fallback. Expression has at least a 60 s gap and uses existing Live speech or text messages.
6. EfficientDet-Lite0 int8 matches Android: confidence 0.6, at most 12 boxes / 10 Hz. One camera and serial inference drop busy frames. High thermal state reduces detection to 2 Hz and stops following. Disable/lens changes/background clear results. Model/SPM pins are in model-manifest.json.
7. Following requires select target → set reference → enable preset → play. Horizontal threshold 14%, forward below area ratio 0.8, stop at 0.95, no reverse; pulses 150 ms. Over-300 ms age, ambiguity, disconnect, lens change, takeover or stop cancels without auto-resume. Rotation transforms boxes and waits for matching fresh frames.
8. Central diagnostics cover session, Live, audio/routes/buffers, camera, detection, following, motion owners and reasons, refreshing at most once/sec. Retain 500 events/100 decisions; export no keys/passwords/raw media/conversation text.

### Motion and cancellation

Stop has priority, followed by remote, tests, explicit actions, following and idle. A stop barrier precedes each ownership change; generation leases prevent stale ACK/JS/provider callbacks from restoring cancelled motion. Following excludes AI/idle body contention. Unconfirmed stops reject new movement.

### Validation limits

Tests cover JSON/personality, scheduling, stop barriers, slow ACKs, ambiguity/staleness, model fixtures, shared camera, diagnostics, navigation and errors that preserve companionship. Configure your own signing/device; explicitly enable network/microphone tests. Central validation distinguishes maintainer hardware confirmation from automated checks.

Following does not measure distance, avoid obstacles or detect drop-offs. A minimum iOS 15 build target does not establish acceptance on every OS/device. Loudness, noise, headphones, BLE/provisioning/OTA and sustained thermal behavior need suitable hardware tests.

Live uses LOW start/end speech sensitivity, 300 ms prefix padding and a 700 ms silence threshold while retaining real interruptions. Errors are explicit and failed/retried Live connections do not exit companionship. Audio diagnostics retain counts/durations/levels, not raw media or conversation text.
