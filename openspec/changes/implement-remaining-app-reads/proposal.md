## Why

多 Agent 和 EventKit 读取完成后，继续接入备忘录、信息历史、语音备忘录已有录音和原始转写。官方不足的读取使用本地只读数据，不修改私有数据库。

## What Changes

- Notes 使用本机官方脚本字典读取文件夹、搜索和正文。
- Messages 读取本机聊天、参与者、正文、归档正文与附件；未支持格式明确返回不完整状态。
- Voice Memos 根据本机 schema 读取录音清单、已有媒体和原始转写，全文分页。
- 原生宿主内固定来源诊断仅向签名 App 所有者通道开放，用于核实 schema；不提供任意路径或 SQL 工具。

## Capabilities

### New Capabilities
- `remaining-app-reads`: 其余三应用的本机读取切片。

### Modified Capabilities

无。

## Impact

扩展六应用目录与 Agent 独立授权。尚未同步、未知私有格式或缺少原始转写必须保留真实状态，不用新生成转写替代已有全文。修改/发送/录音控制后续单独验证。

喵～
