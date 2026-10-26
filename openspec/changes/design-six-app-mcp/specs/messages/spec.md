## ADDED Requirements

### Requirement: 本地历史正文

系统 SHALL 只读查询当前 Mac 的聊天历史，解码 text 与受支持的 attributedBody，保留会话、参与者、时间和正文可用状态。

#### Scenario: 正文只在 attributedBody
- **WHEN** 一个测试消息的 text 为 NULL 且归档正文有效
- **THEN** 返回正确完整正文，不漏报为空消息

#### Scenario: 正文解析失败
- **WHEN** 归档布局超出支持范围
- **THEN** 返回 decode_failed 或 partial，不用乱码猜测出一段正文

### Requirement: 群聊线程及当前消息语义

系统 SHALL 保留可用的回复、反应和附件关联，并识别编辑/撤回状态；不能把恢复的撤回旧文作为当前正文。

#### Scenario: 群聊含回复与附件
- **WHEN** 读取一段有回复和图片的群聊
- **THEN** 能定位正确聊天和参与者，并保留回复/附件关联而非串到同名联系人

#### Scenario: 已撤回消息
- **WHEN** 原生数据标记消息已撤回
- **THEN** 返回撤回状态，不提供取证恢复的旧正文

### Requirement: 搜索不漏归档正文

系统 SHALL 对解码后的正文进行搜索，区分完整扫描和部分扫描，并支持继续遍历全部本地范围。

#### Scenario: 本批无匹配但后续有数据
- **WHEN** 当前有界扫描未发现结果且扫描尚未完成
- **THEN** 返回 search_complete=false 和继续游标，不能报告全库无结果

### Requirement: 官方发送与精确目标

系统 SHALL 仅通过官方 AppleScript 发送消息，精确验证目标与服务类型，不直接写聊天库；历史读取不得顺带标为已读。

#### Scenario: 无法唯一映射会话
- **WHEN** 数据库聊天不能唯一映射到脚本发送目标
- **THEN** 返回需要明确目标的状态，不选择名字最接近的聊天发送

#### Scenario: 发送超时
- **WHEN** 官方发送已经调用但结果未知
- **THEN** 沿用 runtime 的 unknown 状态，不自动重发也不承诺对端送达

喵～
