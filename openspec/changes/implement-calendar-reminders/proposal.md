## Why

统一 App 多 Agent 基础完成后，按用户要求逐步接入剩余应用。Calendar 和 Reminders 使用官方 EventKit，先交付可验证的读取切片。

## What Changes

- 新增日历清单、区间搜索、事件读取与提醒清单、搜索、详情六工具。
- 原生 App 请求系统权限；MCP 不能触发授权或修改 Agent 权限。
- 使用既有 Agent 权限检查和读取调度，不增加 npm 或网络服务。

## Capabilities

### New Capabilities
- `eventkit-read`: 日历和提醒事项的本机官方读取。

### Modified Capabilities

无。

## Impact

增加 EventKit 链接和用途声明。修改、邀请、重复事件编辑等仍按整体设计后续实施，不通过读取切片宣称已验证。

喵～
