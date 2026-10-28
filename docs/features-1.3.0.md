# iOS 1.3.0（12）功能说明

**语言 / Language:** [简体中文](#简体中文) · [English](#english)

## 简体中文

> 本文保留原版本功能/自动验收基线；当前正式发布、构建号和维护者真机确认见[统一验证记录](https://github.com/xlle-er/KARI-DF26/blob/main/docs/validation.md)。历史“待测”不代表最新总体验收状态。

基于 1.2.0，新增以下功能。业务源码位于 `Native/Sources/KariNative/`，最低兼容目标 iOS 15。

## 场景与生命状态

人格 → 待机场景：6 个表情、11 个底盘场景；首次、静默、对话间隙时间范围；全局与单场景速度／时长倍率、权重、冷却、适用状态、启用和单次预览。默认只启用表情待机，身体动作仍需独立许可。全部场景关闭时不强制动作。

人格 → 生命状态：模拟精力、无聊、好奇、亲近、孤独、舒适度、情绪、注意力、休眠与最近决策。唯一自动调度入口按单调时间差更新，后台暂停、不补算后台衰减；每次开始重置运行状态。生命状态不代表真实传感器测量，不推断距离、障碍或用户身份。

安全与人工控制优先。语音播放、遥控、跟随、显式动作、升级、断线及后台会限制或取消身体待机；旧任务不能恢复运动。

## 前台本地唤醒

设置 → 语音与唤醒：默认关闭；仅用于 Gemini／标准 Vertex Live。中英预设“你好卡里”／“Hey KARI”。必须具备所选语言的本地 Speech 能力和权限；不回退网络识别，不可用时保留手动唤醒。

等待时不建立 Live，不上传麦克风或画面；本地相机可继续预览／检测。复用单一音频采集链路；保留命中前约 1 秒，连接阶段最多缓冲 8 秒，交接只发送一次，超限明确提示重说。

默认静默超时 60 秒，可调 30–300 秒；连接、用户讲话、模型处理和播放期间不计入退出。返回等待关闭 Live、清空音频和恢复句柄，取消跟随与身体待机。失败保留陪伴，显示原因并提供手动重试。停止、后台、电话中断取消采集；回前台需显式恢复。不是锁屏后台唤醒助手。

## 界面与配置

使用系统 UITabBarController：机器人、人格、中央播放操作、视觉、设置。四页面及二级页面由系统安全区避免底部遮挡。陪伴期间隐藏标签栏；停止在右上角，与控制层同步显隐。iOS 26+ 标签栏及悬浮面板采用系统 Liquid Glass，旧系统使用原生材质。表单内容仍采用系统标准控件。

人格 JSON 保持兼容。新增 schemaVersion=1 的陪伴配置 JSON，包含人格、行为、场景及唤醒；完整校验后一次应用，失败保留原值。运行生命状态、识别文本、原始音视频和凭据不持久化到配置。诊断导出继续排除私人内容。

## 验证边界

相同业务源码在个人签名版完成 17 项单元与 6 项真机界面检查；公开工程只做编译、测试目标编译、静态分析、本地化、资源与隐私检查，不重复安装到手机。真实中英唤醒命中率、噪声误唤醒、30 分钟温升耗电和真实机器人运动／OTA仍需人工验收，不以自动检查替代。

原有语音完整播放验证保留；本轮迁移没有重新运行云端语音测试。iOS 15 为最低编译目标，不代表覆盖所有系统和机型。眼睛及动作编排继续复用本地 Web 组件，设置、导航与文件操作为原生实现。

## English

Based on 1.2.0, with business sources in `Native/Sources/KariNative/` and minimum target iOS 15. The heading records the build-12 feature baseline; the current KARI stable build is 13.

### Scenes and life state

Personality → Idle scenes exposes six expressions and eleven chassis scenes; first/quiet/conversation-gap ranges; global/per-scene speed/duration, weight, cooldown, states, enablement and one-shot preview. Expressions alone are enabled by default; body actions need separate permission. Disabling all scenes does not force a replacement.

Personality → Life state shows simulated energy, boredom, curiosity, closeness, loneliness, comfort, mood, attention, sleep and decisions. One monotonic-time scheduler pauses in the background without catch-up decay and resets each start. These are not physical sensor readings and do not infer distance, obstacles or identity. Safety and manual control override automation; speech, remote, following, actions, upgrades, disconnect and background constrain/cancel body idle. Old tasks cannot restore motion.

### Foreground local wake

Settings → Voice and wake is off by default, for Gemini / standard Vertex Live. Presets are “你好卡里” / “Hey KARI”. On-device Speech capability and permissions must exist for the selected language. There is no network-recognition fallback; manual wake remains available.

Waiting creates no Live connection and uploads no microphone/video; local preview/detection may continue. One capture chain retains about 1 s pre-roll and up to 8 s connection buffering, handing over once in order. Overflow asks the user to repeat.

Silence timeout defaults to 60 s, configurable 30–300; connection, speech, processing and playback do not count. Returning to waiting closes Live and clears audio/resumption, following and body idle. Failures preserve companionship with reasons and manual retry. Stop/background/calls cancel capture; foreground resumption is explicit. This is not lock-screen wake.

### Interface and configuration

System UITabBarController hosts Robot, Personality, a central play action, Vision and Settings. Four pages/subpages respect native safe areas. Companionship hides tabs; the upper-right stop follows control visibility. iOS 26+ uses system Liquid Glass for tabs/floating panels; older systems use native materials and forms remain standard controls.

Personality JSON stays compatible. Full companion schemaVersion=1 includes personality, behavior, scenes and wake; validate all before atomic application and preserve old values on failure. Exports exclude runtime life state, transcripts, raw media and credentials; diagnostics remain redacted.

### Validation boundary

The historical build-12 baseline recorded 17 unit and 6 physical UI checks in the personal app; the public project used compile/static/localization/resource/privacy checks rather than a duplicate phone installation. See [current validation](https://github.com/xlle-er/KARI-DF26/blob/main/docs/validation.md) for migration results and maintainer confirmation. Synthetic tests do not establish real-speaker/noise accuracy or 30-minute thermals and robot motion/OTA results.

Existing complete-speech checks were retained; migration did not repeat cloud voice tests. Minimum iOS 15 does not imply every OS/device was tested. Local Web resources retain eyes/choreography; settings/navigation/files are native.
