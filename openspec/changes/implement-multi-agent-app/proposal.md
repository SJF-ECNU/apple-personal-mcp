# 统一 App 的多 Agent 接入

## Why

六应用由一个 macOS App 提供。现有入口只验证程序签名，同用户的多个 Agent 无法独立授权或撤销，共享串行队列阻塞读取。用户要求去掉 npm。

## What Changes

- 删除 npm 包与 Node 启动脚本，使用 App 内原生 stdio 入口。
- 原生 App 管理每个 Agent 的随机凭据、六应用权限、配置复制和撤销。
- 宿主逐请求验证权限，工具目录动态过滤；附件与操作状态按 Agent 隔离。
- 最多四个读取并行，每个应用的官方自动化串行，限制待执行请求；排队后再次验证权限。
- 本阶段用 Mail 真机验证两个独立 MCP 客户端；其他五应用按原总体设计后续分批接入，不在本变更宣称已完成。

## Capabilities

### New Capabilities
- `multi-agent-access`: 独立 Agent 凭据和权限、隔离、调度、原生管理。

### Modified Capabilities

无。

## Impact

旧无凭据配置需要在 App 内重新生成；不迁移旧共享附件和发送记录给任何 Agent。保持 XPC 签名/用户验证、发送原生确认与私有数据只读约束。

喵～
