# 六应用方案的调研依据

调研日期：2026年10月26日。本文区分官方能力、本机观察和第三方公开实现，不把它们混作已经运行通过的产品结果。

## 本机观察

| 检查 | 结果 | 能证明什么 |
| --- | --- | --- |
| `sw_vers` 与架构 | macOS 27.0，build 26A5406e，arm64 | 当前验证目标；不等于其他版本兼容 |
| 仓库 | 初始为空，没有项目根 `.codegraph/` | 没有可调查的已有产品代码；按仓库规则不创建 CodeGraph 索引 |
| Mail 脚本字典 | 有邮箱、正文、附件、草稿、reply、send 等声明 | 官方自动化路线存在；未执行邮件读取和发送 |
| Calendar / Reminders 字典 | 均存在 | 与官方 EventKit 文档一致的接入候选；未实际请求授权 |
| Notes 脚本字典 | 有账户/文件夹、body、plaintext、附件、password protected | 普通笔记可规划脚本接入；锁定与富内容边界仍需实测 |
| Messages 脚本字典 | 有 chat、participant、send，没有历史正文对象 | 发送可走脚本；历史正文需要另一来源 |
| Voice Memos 公开动作声明 | 有录音、停止、播放、搜索、选择、删除、文件夹等动作；录音实体有 name、creationDate、duration | 动作存在；不证明快捷指令已能无交互工作，也不证明音频/转写可由动作直接取得 |
| 聊天库结构只读查询 | SQLite 返回 `authorization denied` | 当前执行上下文不能打开源库；没有取得本机 schema 或聊天正文 |
| Voice Memos 共享容器目录 | `Operation not permitted` | 当前上下文不能枚举录音；没有取得原始音频或转写 |

本机脚本依据来自 `/System/Applications/<App>.app/Contents/Resources/*.sdef`。Voice Memos 动作依据来自应用包内 `Contents/Resources/Metadata.appintents/extract.actionsdata`。这些都是应用随包定义，不是用户个人内容。没有改动系统权限或尝试通过其他进程绕过拒绝。

## 官方资料

| 来源 | 支持的设计判断 |
| --- | --- |
| [Apple 自动化脚本字典说明](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AboutScriptingTerminology.html) | 应用各自声明脚本能力，版本更新后需要测试 |
| [EventKit](https://developer.apple.com/documentation/eventkit) 与 [访问 event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store) | 日历和提醒事项由 EventKit 读取/修改；访问授权需要分清事件与提醒事项 |
| [MailKit](https://developer.apple.com/documentation/mailkit) | 面向 Mail 扩展，不等于任意邮箱查询服务 |
| [Shortcuts 命令行](https://support.apple.com/en-au/guide/shortcuts-mac/apd455c82f02/mac) | 可传入输入并运行快捷指令；交互动作可能等待用户 |
| [Voice Memos 分享与导出](https://support.apple.com/guide/voice-memos/share-a-recording-vm05f9fa82d4/mac) | 系统应用可分享或拖拽导出单条录音；不证明存在批量数据 API |
| [SpeechAnalyzer WWDC25](https://developer.apple.com/videos/play/wwdc2025/277/) | 公开的本地语音处理路线，适合显式生成转写；不同设备/语言仍要检查 |
| [MCP SDK 列表](https://modelcontextprotocol.io/docs/sdk)、[Swift SDK 源项目](https://github.com/modelcontextprotocol/swift-sdk) | 有官方 Swift SDK；目录当前把 Swift 列为 Tier 3。读取的 README 声明实现 2025-11-25 规格，不能直接推断其支持官网全部新规格 |
| [MCP tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) | 输入输出 schema、结构化结果、音频与资源引用、工具注解 |
| [SMAppService](https://developer.apple.com/documentation/servicemanagement/) 与 [agent 注册](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)) | 通过 app 包内用户 LaunchAgent 承载登录用户的服务 |
| [XPC 签名要求](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)) | 系统支持对 XPC 对端执行代码签名要求检查 |
| [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) | Hardened Runtime 应用请求向其他应用发送 Apple Events 的相关配置；不直接授予用户同意 |
| [SQLite WAL](https://sqlite.org/wal.html)、[SQLite backup](https://sqlite.org/backup.html) | 只读 WAL 的条件、活动数据库的一致备份方式；不能以普通文件逐个复制替代一致读取 |

## 公开实现提供的候选路线

以下项目只作为其作者实际实现方式的一手依据，不构成 Apple 官方兼容承诺。本轮没有安装或运行这些项目，也没有直接引入代码。

- [Madrid](https://github.com/mattt/Madrid)：Swift 项目，提供只读 Messages 访问及独立 TypedStream 解码。其 README 说明可能按配置退化为 immutable 读取；本方案不采用活动源库上的该退化方式。许可证和实际选用模块在实施前复核。
- [macos-voice-memo-tools 的 db.js](https://github.com/grmartin/macos-voice-memo-tools/blob/main/src/db.js)：以只读 SQLite 读取 CloudRecordings.db，使用 Core Data 时间纪元；标题字段仅代表该实现支持的布局。
- [macos-voice-memo-tools 的 mp4.js](https://github.com/grmartin/macos-voice-memo-tools/blob/main/src/mp4.js)：按 MP4 box 层级取得 `moov/trak/udta/tsrp` 的 JSON，不读取大音频负载。
- [voice-memos 的 Transcript.swift](https://github.com/harryf/voice-memos/blob/main/Sources/voice-memos/Transcript.swift)：展示 `attributedString/runs/attributeTable` 的转写结构。其样例只保留带 timeRange 的 run；本方案要求无时间戳的文字也保留，不能照搬后宣称全文完整。
- [voice-memos-skill](https://github.com/grapeot/voice-memos-skill)：提供 `.m4a/.qta`、删除记录与本地音频状态方面的实现参考。该项目还包含私有 API 重命名及内容摘要等机制，**不在本方案采纳范围内**；删除字段和媒体表示仍需核对本机实际布局。

不同项目对标题字段的选择不完全一致，正说明不能依靠某篇说明硬编码所有版本。当前结论是已有可借鉴的解析路线，不是本机六应用全部已打通。

## 本轮交付的验证范围

后续参考项目调研见 [Apple Mail MCP 设计借鉴](apple-mail-mcp-reference.md)。已查阅其读写分离、直接 Apple Events、工具层、诊断、测试及批量操作问题记录，主设计据此改为 Mail 混合读取路线；本轮未安装或执行该参考服务，未新增第三方源码依赖，未复现其性能与实机修改结果。

初始设计轮只验证了 OpenSpec、链接与图形。随后基础框架与 Mail 核心已实现，实际构建、协议、本机读取及测试草稿/旗标/移动结果见[首阶段验证记录](validation/2026-10-26-framework-mail.md)。其他五应用、外部发送、录音和生成转写不能沿用 Mail 的结果宣称通过。

喵～
