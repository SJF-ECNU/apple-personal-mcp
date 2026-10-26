## Why

将六应用设计中的基础框架与 Mail 先变成可运行、可本机验证的服务，验证原生宿主权限、MCP 接入及只读邮件路线，而不是停留在文档。

## What Changes

- Swift 原生宿主、XPC、stdio MCP、只读模式、doctor/call 和最小设置界面。
- 复用参考项目的 MailStore 公开库读取索引及 MIME，封装本项目的分页和工具结果；不引入其完整工具策略。
- 实现邮件账户、邮箱、概览、搜索、全文、线程、批量读取和附件；官方 Apple Events 支持草稿及受控修改，外部发送需要真人确认。
- 添加离线合成测试、真实 stdio/XPC 集成检查及本机验证记录。缺少隐私授权时如实记录并继续完成能独立验证的部分。

## Capabilities

### New Capabilities

- `framework-mail-slice`：第一阶段可运行框架、邮件读写与本机验证要求。

### Modified Capabilities

无。整体设计仍位于未归档的 design-six-app-mcp，本阶段不宣称实现其全部八项能力。

## Impact

新增 Swift Package、app 打包/签名脚本、用户会话 LaunchAgent 配置与运行说明。使用现有本机签名身份，开发安装不冒充已公证正式分发。只读 Apple 私有库，衍生文件仅存本项目目录或应用自有目录。

喵～
