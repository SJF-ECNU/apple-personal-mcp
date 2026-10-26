## Decisions

每请求独立EKEventStore。只接受fullAccess；writeOnly或未授权不当作空数据。系统权限与Agent权限分开检查。App按钮及本机管理命令通过签名App专用owner XPC通道，要求实际后台宿主发起原生请求；授权不暴露给Agent。Hardened Runtime包含Calendar entitlement。实际授权后已完成本机清单、事件、提醒和备注读取。

事件搜索要求明确带时区的起止时间、最多一年，返回按时间与原生 ID 排序的有界分页。重复实例同时返回 occurrence_start；单对象读取需要精确匹配实例，不保证 eventIdentifier 跨同步永久稳定。正文独立分页，搜索结果不附全部正文。

提醒 fetch 使用官方谓词和完成回调，超时取消；结果按原生 ID 排序分页，支持清单、完成状态和关键词过滤。提醒的无时区到期日期保留 DateComponents 的日历分量，不强转绝对 UTC。

真实读取必须等用户授予系统权限。合成参数测试、构建、权限拒绝验证均不能替代授权后的实际读取。后续顺序：Notes 官方脚本、Messages 只读历史、Voice Memos 音频与原始转写；各自使用独立变更和验证记录。

喵～
