# 基础框架与邮件模块本机验证

日期：2026年10月26日，Asia/Shanghai。开发版 0.1.0。环境：macOS 27.0 arm64，Swift 6.3.3，使用本机 Apple Development 身份签名。安装位置为 `/Applications/ApplePersonalMCP.app`，通过用户 LaunchAgent 运行宿主，stdio 入口经 XPC 调用，不使用 Docker。

本页为首阶段历史记录。后续0.2.0已按用户要求移除 npm 包与 Node 入口，旧无凭据配置停止工作；当前接入方式及验证见 [多 Agent 记录](2026-10-26-multi-agent.md) 和 [README](../../README.md)。下文 npm 一行为当时实际执行的历史结果，不是当前支持方式。

## 已执行结果

| 验证 | 实际结果 |
| --- | --- |
| Swift 构建 | `swift build` 与 app 打包成功；重复构建时发现并修复只读许可证文件覆盖问题 |
| 本机签名 | app 与桥接程序签名，`codesign --verify --deep --strict` 通过；未做正式公证 |
| 单元测试 | `swift test`：9 项通过、0 失败 |
| 真实协议 | Python 客户端通过安装后的 stdio 入口完成 initialize、tools/list、tools/call；协商 2025-11-25 |
| XPC | 合法入口可调用；同 Team、错误 identifier 的签名探针被拒绝，退出码 1 且无数据输出 |
| 权限拒绝 | 最初真实宿主报告 needs_permission；用户手工开启 FDA 后重启宿主，读取变为 ready |
| 邮件读取 | 本机读到 6 个账户、36 个邮箱；初始有效消息计数 3460，之后增加了本次验证创建的草稿 |
| 正文与查询 | 概览、元数据、全文、真实正文分页续读、线程、批量摘要通过；分批正文扫描报告未完成而非假空结果 |
| 未读状态 | 选择实际未读收件箱邮件，读取正文后再次查询仍未读 |
| 真实附件 | 导出一份已下载附件，长度 2,608,746 字节；通过 assets_read 检查 1024 字节片段长度。未在报告中保存名称和内容 |
| 草稿 | 创建无收件人测试草稿，更新正文并通过官方接口读回；宿主重启后仍可读取 |
| 收件人 | 另建使用保留域 example.invalid 的合成收件人草稿，读回地址正确；未发送 |
| 旗标 | 仅在本服务创建的测试草稿上修改旗标、读回确认并恢复原状态 |
| 移动 | 将同一测试草稿移入其账户废纸篓，再移回原邮箱，两次均按目标身份读回 verified |
| 只读模式 | 实际工具列表隐藏修改工具；直接调用缓存的 mail_create_draft 得到 read_only，未创建草稿 |
| npm | 临时目录中执行本地 npm install，安装生成的 bin 可调用原生宿主并返回 Mail ready；临时 npm 安装目录已清理 |

单元测试覆盖 Unicode 标量分页、只读拒绝及日志不含正文、资源范围/软链接、发送操作 ID 唯一性及 unknown 状态重开保持、活动 WAL 新记录、超过 40,000 字的正文末尾搜索、未下载/未扫描状态、MIME 附件与源字节保持，以及批量响应预算下完整续读。

本轮没有向外部收件人发送邮件，没有永久删除邮件，没有直接修改 Mail 私有数据库。普通 Mail 操作通过官方 Apple Events 完成；系统应用自身的数据库与同步变化属于该官方操作的自然结果。

## 测试对象与衍生文件

- 保留一封 `APM local verification` 开头的无收件人验证草稿，供用户检查；其旗标已恢复，移动后已回到原邮箱。
- `APM recipient verification` 开头、收件人为 `mcp-validation@example.invalid` 的草稿用于验证收件人创建，验证后移入废纸篓，不永久删除。
- 附件测试副本位于应用自有 Exports 目录，使用 UUID 命名。访问期限为 24 小时，自动删除尚未实现；用户可清理 `~/Library/Application Support/ApplePersonalMCP/Exports/`。日志不保存原邮件正文、收件人或附件内容。
- 本报告不包含真实邮件主题、地址、正文或附件字节。没有生成私人邮箱全库副本。

## 尚未验证或实现

1. 外部实发、送达、发送确认窗口的完整人工流程，以及发送中断故障注入尚未验证。发送代码不把 Mail 接受请求视为送达，结果未知不会自动重发。
2. 本机移动仅验证了本次测试对象所在的普通账户；Gmail 标签、重复 Message-ID、并发同步负载及批量操作仍需单独验证。当前修改工具只处理单封对象，Gmail 标签移动会拒绝。
3. 通用 undo、官方查询降级、长任务、MCP resources/prompts、完整动态状态界面与自动清理尚未实现，不能用这次通过替代整体设计的验收。
4. Calendar、Reminders、Notes、Messages、Voice Memos 返回 not_implemented。本次仅实现基础框架和 Mail 核心。
5. 当前为本机开发签名，不是可向其他机器直接分发的正式公证安装包；npm 也未发布到公共 registry。

## 重现

构建和权限步骤见 [README](../../README.md)。已有 app 与授权时，`swift test` 验证临时合成数据，`python3 Scripts/smoke.py` 验证真实读取和协议；加 `--draft` 会创建新的无收件人测试草稿。CLI `doctor` 与 `call` 使用同一个 XPC 宿主，不是绕过权限的独立读取实现。

喵～
