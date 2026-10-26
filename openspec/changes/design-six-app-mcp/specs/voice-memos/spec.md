## ADDED Requirements

### Requirement: 现有录音与本地状态

系统 SHALL 只读解析录音元数据，按原生 ID 关联有效媒体，并区分活跃/已删除及本地/未下载等状态。

#### Scenario: 遗留删除文件
- **WHEN** 文件仍在磁盘上但对应原生记录已删除
- **THEN** 不将它作为默认活跃录音列出或导出

#### Scenario: 音频未下载
- **WHEN** 录音元数据存在但媒体不在本机
- **THEN** 返回 not_downloaded，不调用内部云接口，也不宣称录音不存在

### Requirement: 当前有效音频

系统 SHALL 按媒体实际格式提供资源，正确处理或明确拒绝剪辑/多文件表示，不把旧素材或更名文件当作当前标准音频。

#### Scenario: 非 M4A 录音
- **WHEN** 录音原生格式为 qta 或其他受支持表示
- **THEN** 返回实际格式，或经验证转换为标准媒体；不通过改扩展名冒充 M4A

### Requirement: 原始转写全文

系统 SHALL 优先读取已有 Apple 转写，保留全部文本 run、可用时间段与语言，按需分页并明确 origin=apple_existing。

#### Scenario: 文字段缺少时间戳
- **WHEN** 一个有效转写的部分 run 没有 timeRange
- **THEN** 仍保留该段文字，时间标记未知，不能过滤后声称全文完整

#### Scenario: 存在多轨候选
- **WHEN** 同一媒体存在多个候选转写
- **THEN** 分别标注并返回，不无条件拼接成重复全文

### Requirement: 原始缺失与新生成分开

系统 SHALL 区分 not_present、not_downloaded、unsupported_format 和 decode_failed；读取原始转写不隐式生成，新生成只能由显式工具启动并标注 generated_on_device。

#### Scenario: 没有原始转写
- **WHEN** 用户读取一条明确没有原始转写的录音
- **THEN** 返回 not_present，不自动改用新生成文本

#### Scenario: 显式本地生成
- **WHEN** 用户启动转写且设备、语言和模型支持
- **THEN** 在本地生成并保存应用自有结果，不覆盖 Apple 转写或上传音频

#### Scenario: 本地识别不可用
- **WHEN** 当前设备或语言缺少可用模型
- **THEN** 返回不支持或模型下载需求，不悄悄调用云端语音识别

### Requirement: 原始媒体与转写对应关系

系统 SHALL 标记转写与当前音频的对应状态，对无法确认的剪辑后对应关系不能宣称完全对齐。

#### Scenario: 录音经过剪辑
- **WHEN** 读到原始转写但无法验证它与当前剪辑音频一致
- **THEN** 返回 alignment=unverified，不把旧时间戳说成当前精确位置

### Requirement: 公开录音动作独立启用

系统 SHALL 只执行固定、已验证的公开快捷指令动作，不能通过私有写入实现录音管理；录音控制可用性不影响已有内容的只读能力。

#### Scenario: 快捷指令需要用户交互
- **WHEN** 目标动作无法可靠后台完成或无法定位目标实体
- **THEN** 返回需要交互或不可用状态，已有录音读取仍正常工作

#### Scenario: 不能确认正在录制的归属
- **WHEN** stop 无法确认目标由本服务启动
- **THEN** 不停止其他用户录音，指引用户在系统应用中操作

喵～
