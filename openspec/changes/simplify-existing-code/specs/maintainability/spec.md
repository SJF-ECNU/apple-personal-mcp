## ADDED Requirements

### Requirement: 精简保持既有行为
系统 SHALL 在合并等价实现时保留当前工具目录、schema、权限检查、逐次授权、确认、路径与资源隔离、取消和状态持久化行为。

#### Scenario: 已授权请求在执行前撤销
- **WHEN** 排队请求执行前失去授权
- **THEN** 精简后的实现仍拒绝执行，且不触发外部效果

#### Scenario: 私有JSON写入
- **WHEN** 应用写入自身JSON状态或资源元数据
- **THEN** 仍使用原子替换并设置0600文件权限

#### Scenario: 原生适配器错误
- **WHEN** Apple Events返回错误或传输失败
- **THEN** 原适配器继续使用原有错误码与未知效果处理
