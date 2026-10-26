# Apple Mail MCP 设计借鉴

调研日期：2026年10月26日。参考项目：[mp-consulting/apple-mail-mcp](https://github.com/mp-consulting/apple-mail-mcp)。查阅时 main 指向提交 `4255bef5da220bcad96f4a0a3ea2df98856b4972`，代码内版本为 0.6.8，提交日期为2026年10月22日。本文依据 README、实际源码和测试文件；没有运行该项目，也没有复现其基准性能。

最有价值的设计是把 Mail 的本地只读查询与官方 Apple Events 修改分开，并围绕真实 Agent 使用补齐批量读取、线程、诊断和操作结果。六应用方案据此调整 Mail 路线，同时保留原生宿主集中处理权限和任务的架构。

## 已核对的实现

| 实现 | 源码依据 | 本项目的借鉴 |
| --- | --- | --- |
| 本地查询与官方修改分开 | [MailStore](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailStore/MailStore.swift)、[AppleEvents](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailAutomation/AppleEvents.swift) | 邮件元数据查询优先只读 Envelope Index，正文/附件读取 emlx/MIME；修改仍交给 Mail |
| 读模型、自动化、工具层与界面分离 | [Package.swift](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Package.swift) | 适配器内部区分读取、修改和结果表达；六应用共用 MCP 与宿主，避免复制六套基础设施 |
| 直接构造 Apple Event 描述符 | [AppleEvents.swift](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailAutomation/AppleEvents.swift) | Mail 使用官方脚本字典定义的 Apple Events，避免拼接 AppleScript；Notes/Messages 分别验证其字典，不复用 Mail 的硬编码描述符 |
| 账户、概览、线程、批量读取 | [Tools+Read](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailMCPKit/Tools%2BRead.swift) | 增加 mail_list_accounts、mail_overview、mail_get_many、mail_get_thread，减少 Agent 为一个问题来回调用 |
| 列表预览与按需正文 | [Tools+Read](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailMCPKit/Tools%2BRead.swift)、[MessageContent](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailStore/MessageContent.swift) | 元数据先返回；全文、HTML、头部按需读取。去引用正文仅作显式展示模式，原文仍可完整取得 |
| 查询覆盖范围可见 | [MailStore.bodyMatches](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailStore/MailStore.swift#L1056) | 正文扫描受预算限制时明确 search_complete=false，分开表达命中分页和未扫描候选 |
| 移动/废纸篓操作读回核对 | [VerifiedChange](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailMCPKit/VerifiedChange.swift)、[AppleEvents](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailAutomation/AppleEvents.swift) | 逐项串行修改并回读；返回完成、未知、未执行与新引用，不能用 Apple Event 无错误代替成功 |
| 只读工具目录 | [MailToolbox](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailMCPKit/MailToolbox.swift#L309) | 首版增加 --read-only，过滤修改工具并在调用时再次拒绝；只读模式仍允许受限资源导出 |
| 可操作的诊断与活动状态 | [Doctor](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailMCPKit/Doctor.swift)、[Activity](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Sources/MailMCPKit/Activity.swift) | CLI doctor 与 MCP 状态共用检查；记录开始、等待、执行、读回、结束及实际运行版本，定位超时发生在哪一段 |
| 合成数据与独立实机探针 | [MailStoreTests](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Tests/MailStoreTests/MailStoreTests.swift)、[TrashProbeTests](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/Tests/MailAutomationTests/TrashProbeTests.swift) | 解析与筛选用合成库测试，真实 Apple Events 与 IMAP 行为另做指定测试对象的真机验证 |

## 会改变现有方案的决定

### 邮件读取改为混合路线

原方案把 Mail 的查询和正文都交给 AppleScript。参考项目的源码表明，可以直接只读 Mail 已有的索引及媒体文件，并避免查询时启动 Mail。该路线值得在第一阶段验证，所以主方案调整为：

1. 发现本机 Mail 数据版本目录，检查必要结构，不能固定假设 V10 永远正确。
2. Envelope Index 只读取得账户/邮箱、日期、主题、旗标、会话与附件目录；正文和附件由匹配的 emlx/MIME 取得。
3. 本地布局不支持或内容未下载时，按明确能力退到官方通道；返回实际 backend、覆盖范围和不完整状态，不静默假装完整。
4. 所有修改通过公开字典中的 Apple Events；读取索引绝不意味着可以写该索引。

这些是本项目的设计选择，不是已经取得的速度提升。后续必须测本机实际邮箱和合成大邮箱，分别记录冷/热耗时、结果数、响应字节、扫描完成情况以及 Mail 是否被唤起。参考项目 README 的毫秒级数字和“最快”结论不能转写成本项目结果。

### 邮件定位要比一个数字 ID 更严谨

参考项目的历史问题记录描述了批量移入废纸篓时操作到相邻邮件及超时后继续执行的情况；该记录中的根因有待确认，本项目不能据此断言 Apple 已确认同一缺陷。本项目仍应把它作为明确失败场景，纳入测试。[问题记录](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/docs/plans/2026-10-trash-targets-wrong-message.md)

定位结合账户、邮箱、索引 ID、可用的 Message-ID 与关键头部。执行前再次核对，不把数据库 ROWID 未经验证转换成脚本对象 ID；尤其不能照搬 `Int32(truncatingIfNeeded:)` 而接受截断。Message-ID 重复、缺失或目标不唯一时不执行模糊批量修改。

移入废纸篓使用经真机验证的 move-to-Trash，不发送永久删除。每项操作等待读回源位置和目标位置，再执行下一项；超时、取消或异常即停止剩余项，并分清未执行和结果未知。Gmail 标签语义需要独立验证，不能简单套普通文件夹的减少一条/增加一条。

### 面向 Agent 降低调用与上下文成本

概览返回未读数量、最新摘要和旗标；线程读取保留顺序与稳定身份；批量读取有总响应预算，而非把 200 封全文一次塞进上下文。完整正文继续通过游标或资源读取。

通过可选 MCP Prompts 提供“邮件阅读与回复草稿”和“录音读取后整理待办”两个可审阅工作流示例。它们只是调用指导，不自动运行，不把工作流编排写死在数据服务内，也不自动安装到用户的全局 Skills。

原生界面按应用展示能力、授权、当前客户端版本、运行中的任务与最近活动；发送待确认项可集中显示。第一版提供可复制的 stdio 配置，不自动重写其他客户端已有设置。概览、全文、任务和审批均复用已有服务层。

## 保留取舍

| 参考项目机制 | 本项目处理 | 原因 |
| --- | --- | --- |
| 每个客户端的 server 直接持有 Mail 读取职责，菜单栏 app 也读取 | 保留本项目原生宿主集中访问的架构 | 六应用同时涉及授权、长音频和多客户端写入协调；不能假定参考项目采用了我们的 XPC 架构 |
| Keychain 加密钥哈希的正文索引 | 首版不引入 | 先使用有界正文扫描、原生元数据索引及短期内存缓存，测出瓶颈再决定是否需要持久化索引；不默认复制受保护正文到明文全文索引 |
| 文件队列和签名审批 | 采用已有 XPC + 原生宿主中的实际确认 | 没有跨进程写审批 JSON 文件的路径，不需要再增加另一套签名文件协议；保留现有 XPC 身份检查 |
| 未公开的 responsibility 查询符号 | 不直接移植 | doctor 给出实际执行组件及检查证据；无法确定隐私归属时明确标为推测，最终由真实调用确认 |
| SDK 请求解码 fast path、手写传输与 JSON 优化 | 首版使用官方 SDK 路径 | 先测端到端瓶颈；不能为复制一个微基准结果增加协议分支 |
| 自动恢复疑似误移动的其他邮件 | 首版不自动恢复 | 可能是用户、规则或其他设备同时修改；仅报告精确可用的异常证据，停止后续修改，由用户指定是否恢复 |
| 移动和旗标的 undo | 仅设计受限恢复 | 返回普通 change_id 与前后状态；执行恢复前确认当前对象仍匹配，不撤销其他人后续修改，不宣称发送可撤销 |
| 规则、退订、定时发送、snooze、发票抽取、自动更新 | 后续候选 | 当前需求是六应用通用接入，首版不扩成专门邮件管理产品 |

## 复用方式与验证

项目采用 MIT License。[许可证](https://github.com/mp-consulting/apple-mail-mcp/blob/4255bef5da220bcad96f4a0a3ea2df98856b4972/LICENSE)。如果后续复制或分发实质性代码，应保留其版权与许可说明；本轮仅修改设计，没有引入第三方源码或依赖。

Package.swift 公开了 MailStore 和 MailMCPKit library product；MailAutomation 是内部 target，没有同名公开 product。不能把它描述为直接通过 SPM 引入的公开库。实施时先验证最小读取原型，再决定依赖 MailStore、提取少量许可允许的解析代码，还是自己实现所需子集。现成 MailMCPKit 包含对方特定的策略、文件审批和规则功能，不整套接入本项目。

新增验证重点：Mail 关闭时读取、活动 WAL、emlx 长度与 MIME 编码、中文长正文末尾、附件未下载、多账户/重名邮箱、Message-ID 重复、移入废纸篓的目标身份、批量取消及回执不明。所有真实修改只使用用户指定的测试邮件，不运行参考项目的实机探针脚本来改动个人邮箱。

喵～
