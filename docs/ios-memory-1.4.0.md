# iOS 1.4.0（16）：记忆库

## 入口与使用

底部为「机器人 / 人格 / 开始陪伴 / 记忆库 / 设置」。机器人页包含「马达测试 / 视觉 / 网络及OTA」，视觉可在未连接实体机器人时使用。配网与升级共用原设备会话与运动锁定。

记忆库支持 PDF（无文字页自动执行本机中英文 OCR）、TXT、Markdown、DOCX、XLSX、PPTX。单文件最大 50 MB，PDF 最大 500 页，提取文字最大 10 MB，全库最大 20,000 个片段。不执行 Excel 公式，不解析旧二进制 Office、内嵌图片或图表语义。

1. 在「向量服务与本机模型」确认服务。默认跟随聊天服务；独立向量服务不改变聊天配置。
2. 导入资料。列表显示处理状态，详情可查看提取内容、启停和删除。
3. 在「问问记忆」、文字陪伴或 Live 语音里提问，展开「检索资料」查看原文与位置。
4. 模型或服务变化后重建索引。原索引保留至新索引成功提交，不同模型不能混用。

导入与重建在前台串行执行；后台暂停，前台恢复。提取文本与每 16 个向量的检查点保存到本机，重启可继续，减少重复计费。失败资料可停用后重新构建。索引与源资料在手机共用，不绑定 BLE 身份，不跨设备同步。

## 向量服务

默认复用 Gemini、标准 Vertex、百炼、Fireworks 或 Ollama 配置。自定义兼容服务尝试从 `/models` 发现 embedding 模型；不能发现时需要手动配置。Groq、规则、模拟模式没有默认向量模型，显示替代服务入口。Vertex Express 不使用标准项目的向量路径。

独立服务支持 Gemini、Vertex OAuth、百炼、Fireworks、Ollama 和兼容接口。服务密钥按提供商和地址隔离保存在 Keychain，不写进索引、导出或 URL。连接失败不会自动向另一个服务上传资料。

本地文本、索引与检查点位于 Application Support/KARI/Memory。SQLite 事务提交文档及向量，向量以 Float32 BLOB 保存；检索计算在后台执行，并使用 Accelerate 点积。

本机模式不上传资料做向量化；云端聊天和 Live 仍会收到检索命中的原文片段。离线规则模式仅展示检索原文，不冒充模型生成的资料回答。聊天、音频、画面不自动加入长期记忆。

## 本机模型与下载

| 模型 | 定位 | 本次固定文件大小 | 已核验下载来源 |
| --- | --- | ---: | --- |
| EmbeddingGemma-300M QAT Q4_0 | 多语言推荐 | 277,852,192 字节 | Hugging Face / ModelScope |
| Qwen3-Embedding-0.6B Q8_0 | 多语言进阶 | 639,150,592 字节 | Hugging Face / ModelScope |
| BGE-small-zh-v1.5 Q8_0 | 中文轻量 | 26,472,640 字节 | Hugging Face |
| multilingual-e5-small Q8_0 | 多语言轻量 | 131,953,504 字节 | Hugging Face |
| all-MiniLM-L6-v2 Q8_0 | 英文轻量 | 25,008,064 字节 | Hugging Face / ModelScope |

所有模型按需下载。使用固定 GGUF 权重和 llama.cpp 原生引擎，分词器随 GGUF 保留；分别实现各模型的查询/文档前缀、CLS/mean/last 池化和归一化。MiniLM 输入限制为 256 tokens，BGE/E5 为 512，EmbeddingGemma 为 2048；Qwen 的移动端实现限制为 512，以控制内存。本机文档按实际模型分词切块，超长问题提示缩短，不静默截断。

用户点击下载后，探测实际文件的连通性和响应时间；自动或手动选择 Hugging Face / ModelScope。仅在清单中收录固定版本、大小及 SHA-256 一致的魔搭镜像。BGE/E5 暂无匹配的已核验魔搭 GGUF 镜像，不能用原始 PyTorch 权重替代。网络失败尝试另一可用源；同源支持保存断点，换源重新下载，避免拼接不一致的响应。

下载校验和加载测试通过后才安装；支持暂停、继续、删除和计费网络确认。模型条目包含来源与许可证链接。Google 模型遵守 Gemma 条款，其他许可证随清单展示。

资料问答按只读处理；引入资料后的 Live 会话只接受用户单独下达的直接动作口令，资料内容或模型工具参数不能授权运动。文字模式同样在执行端验证，不仅依赖模型提示词。

## 构建与测试

```sh
npm run build:embedding
npm run test:memory
# 可选：使用已下载文件执行五款模型的本机运行检查
npm run test:memory -- Native/Sources/KariNative/Resources/Models/embedding-catalog.json /absolute/path/to/models
```

规范源码为 `Native/Sources/KariNative`，Xcode 直接使用此源码。模型清单刷新脚本为 `scripts/update-embedding-catalog.py`，会重新验证魔搭哈希，不猜测镜像地址。

llama.cpp 固定为 b11998 / 78feec062d50ec9e8940244cac918ac4480b60cb。官方预编译包最低 iOS 16.4，因此本地重新编译 iOS 15 的 device/simulator slices；重建脚本为 `scripts/build-local-embedding-runtime.sh`，许可证保存在 Vendor。macOS slice 用于隔离测试。App 的最低版本维持 iOS 15。

`Tests/memory` 覆盖事务回滚、向量与来源持久化、检查点隔离、禁用/删除、排序去重、端点与凭据隔离、各服务请求及错误处理。`Tests/device-native/MemoryRegressionTests.swift` 覆盖原生格式提取、扫描 PDF OCR、本机模型和资料问答闭环；UI 测试覆盖新子页面和模型列表。

本次公开工程的验证结果见 `validation-1.4.0.md`。云端提供商实际账户权限、Live 资料问答的真实语音体验、10,000 片段检索 P95、40 条资料问题/20 条无关问题的质量指标，以及 30 分钟温升耗电需要单独实测，不能从编译或模型加载测试推断通过。
