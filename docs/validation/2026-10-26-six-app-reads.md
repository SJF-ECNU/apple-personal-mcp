# 六应用读取切片的本机验证

日期：2026年10月26日，Asia/Shanghai。版本0.2.0。已安装签名的统一App；全部调用通过App内置stdio/CLI入口和实际用户XPC宿主，不使用Docker、npm或Node。测试不保存真实正文、标题、音频或转写到仓库。

## 实际读取

| 应用 | 本机结果 | 覆盖范围 |
| --- | --- | --- |
| Mail | 6账户、36邮箱；正文、未读保持、线程、批量和2,608,746字节附件读取回归通过 | 初始草稿/旗标/移动见首阶段记录；本轮未实发 |
| Calendar | 7日历，360天区间51个事件实例 | 清单、区间查询、精确实例详情和备注分页；无修改 |
| Reminders | 1清单、125条提醒 | 搜索、详情、备注重组、原生到期日期分量；无修改 |
| Notes | 6文件夹、120条笔记；样本1260 Unicode标量完整重组 | 官方Apple Events；纯文本和原始HTML读取、标题搜索；受保护笔记拒绝读取 |
| Messages | 观察时2295消息；1000条样本777来自text、223走typedstream；实际337标量归档正文完整分页读回 | 聊天/参与者、按聊天分页、正文分页、归档正文路径、回复/编辑/撤回元数据；选定归档样本没有附件，真实附件导出待样本验证 |
| Voice Memos | 51条录音、51份本地媒体；导出一份3,749,663字节原始m4a | 一份Apple原始嵌入转写1906 Unicode标量，127标量分页完整重组；没有生成替代转写 |

这些是当前Mac的观察值，期间信息库从2294增至2295，语音库在打开系统App后自然同步；不宣称云端历史已全部同步。源码没有写Apple私有数据库，源App自身同步产生的变化不等于本服务修改。

## 原始转写和归档格式

语音先观察到系统App显示“正在下载”，工具如实返回not_downloaded；同步完成后才执行音频和转写读取。实际样本均为m4a，解析容器内的原始tsrp JSON，按runs次序保留全部文本。支持返回原始JSON资源和多个转写索引，但本次不是全部51条转写或全部轨道的逐一验收。

qta的QuickTime keys/ilst键控布局完成合成测试，本机没有qta样本，不能宣称真机兼容已通过。转写与剪辑后音频的对齐未验证；数据库删除flags未解释，列表明示包含所有本地库行。未知结构明确unsupported_format，不扫音频字节猜JSON，不把摘要或新生成文本冒充已有全文。

信息结构解析使用Madrid 0.4.0的TypedStream产品；避免其stringValue便利过滤器，因为其会丢弃含NS/Attribute和纯表情的合法文本。系统公开NSArchiver生成的合成归档包含中文、表情、占位符、元数据样式词和超过64KiB文本，均精确重组。真实500份归档全部解析成功；与499条非空text比较，492条相同，7条相差1标量，移除占位符及首尾空白后均相同。原始输出不做这种归一化，差异形状保留在机器记录中；没有逐条与系统UI比对，不能把解析成功率等同于全库语义验收。

## 权限与测试

系统FDA、日历/提醒fullAccess及Notes自动化和Agent应用read scopes分别验证。Calendar缺少Hardened Runtime entitlement时观察到false/notDetermined；加入[Apple要求的Calendar entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.calendars)后，由实际宿主请求并得到fullAccess。原生App专用owner XPC负责显示管理窗口和系统授权，MCP入口不提供授权方法。

27项单元测试通过，覆盖授权/撤销、排队和并发、跨Agent/应用资源、发送ID全局唯一及旧状态迁移、WAL新记录、嵌入NUL、typedstream、MIME、原始文件保持、MP4原始/键控转写及无声假JSON拒绝。队列串行和旧发送状态由合成测试验证；本轮没有向外部收件人发送邮件或信息。

## 尚未完成

- 非邮件五应用的修改、删除、邀请/发送、录音控制，以及服务新生成转写。
- Messages的复杂编辑历史、反应细分、富卡片和所有私有格式；撤回旧正文不返回。真实附件样本覆盖以机器结果为准。
- 全部录音/轨道的转写对照、qta真机样本、剪辑后对齐及删除flags解释。
- 长任务、完整MCP resources/prompts、自动清理、其他Agent产品的配置兼容矩阵与正式公证发布。

## 重现与机器结果

系统授权已具备时，依次执行Scripts/multi-agent-smoke.py、Scripts/eventkit-smoke.py、Scripts/remaining-app-smoke.py。三个脚本创建临时Agent、只输出数量/状态，结束后撤销凭据；有导出的验证Agent副本会清理，撤销元数据保留。

- [多Agent机器结果](2026-10-26-multi-agent.json)
- [EventKit机器结果](2026-10-26-eventkit.json)
- [其余应用机器结果](2026-10-26-remaining-reads.json)
- [启动与接入方法](../../README.md)

喵～
