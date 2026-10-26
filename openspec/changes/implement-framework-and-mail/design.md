## Context

实现范围为基础框架与邮件模块；整体方案见前一变更。当前仓库无根 .codegraph，按仓库规则不创建索引。工具链为本机 Xcode/Swift，已有 Apple Development 签名身份；实际系统隐私权限仍以运行结果判断。

## Goals / Non-Goals

目标是构建可运行 app 和 MCP 入口，真实验证协议、XPC、邮件读取、附件、草稿及可恢复修改。其他应用显示 not_implemented，不伪造功能。正式 Developer ID 公证与未知格式的完整兼容留在后续。

## Decisions

- 原生宿主单实例，入口只负责 MCP 编码与 XPC；用户 LaunchAgent 运行同一个 app 主程序。XPC 验证同一用户和签名 identifier/Team ID。
- MailStore 仅使用只读公开 product，通过 Swift Package 正常依赖指定 Git 版本，保留 MIT 许可。Mail 源库从不创建/迁移/写入；自己的状态库独立。
- 元数据查询复用库；全文搜索自己按候选分批读取完整正文，避免参考库的正文前缀限制。正文分页和批量总预算归本项目管理。
- 官方修改使用 Apple Events 描述符；首次本机测试先操作本服务创建的无收件人草稿和可恢复旗标，不向未知收件人发送测试邮件。
- 先用合成目录验证解析、WAL、分页和资源，再在原生签名宿主取得权限后读取用户本地数据；模拟检查不能替代本机结果。

## Risks / Trade-offs

- 隐私权限可能属于宿主或启动客户端：提供实际 app 路径和真实错误，不改系统隐私数据库、不绕过拒绝。
- Development 签名不等于正式分发：记录本机开发用途，保留后续公证任务。
- 发送超时无法证明未发送：操作状态记录 unknown，禁止自动重发。

喵～
