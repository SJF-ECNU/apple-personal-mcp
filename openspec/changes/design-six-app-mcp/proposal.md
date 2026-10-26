## Why

Agent 需要统一访问 Mac 上的六类个人应用，包括信息历史正文、已有录音和已有转写全文。现有官方接口分散，信息历史和语音备忘录内容存在缺口，需要把官方读写与本地只读解析组合成可验证的 MCP 服务。

## What Changes

- 设计一个 Swift 原生应用，承载系统权限、六个应用适配器、音频处理和任务状态；一个轻量 stdio 入口负责与 Agent 连接。
- Mail 采用 Envelope Index 与 emlx/MIME 的本地只读查询、官方 Apple Events 修改；Calendar、Reminders 使用 EventKit，Notes 使用官方脚本。
- Messages 使用本地聊天数据库只读访问历史，使用官方 AppleScript 发送消息。
- Voice Memos 只读录音元数据、音频和已有转写，使用公开快捷指令动作控制录音；缺少已有转写时提供独立的本地转写任务。
- 定义工具目录、分页、资源访问、来源标注、权限诊断、错误和未知发送结果的处理方式。
- 借鉴 apple-mail-mcp 的读写分离、概览/线程/批量读取、只读模式、诊断和修改后核验；不引入其整套邮件管理功能。
- 形成中文设计、可编辑架构图、能力规格和实施任务。本变更只交付设计文档，不执行个人数据写入，不实现或安装服务。

## Capabilities

### New Capabilities

- `mcp-runtime`：本地 stdio 接入、原生宿主、工具与资源、权限状态、任务生命周期、外部副作用处理。
- `local-read-access`：私有数据只读访问、WAL 一致读取、有限解析、资源与缓存管理。
- `mail`：邮箱、邮件、附件、草稿与发送。
- `calendar`：日历与日程查询、创建、修改、删除。
- `reminders`：清单、提醒事项查询、创建、更新、完成与删除。
- `notes`：文件夹和普通笔记查询、全文读取、创建、更新与整理。
- `messages`：聊天历史、正文、线程、附件与发送。
- `voice-memos`：已有录音、音频、原始转写、独立生成转写与录音控制。

### Modified Capabilities

无。仓库此前为空，没有既有规格或产品行为。

## Impact

计划采用 Swift、官方 MCP Swift SDK、EventKit、Foundation Apple Events、SQLite、AVFoundation、Speech 与 Shortcuts。正式分发涉及 Developer ID 签名、公证、用户会话内的后台服务与系统隐私授权。私有数据格式需限定已验证版本；当前本机聊天数据库及录音目录受权限保护，尚未验证个人样本内容解析。

喵～
