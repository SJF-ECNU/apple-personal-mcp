## ADDED Requirements

### Requirement: 提醒事项独立授权与读写

系统 SHALL 通过 EventKit 和独立提醒事项授权查询清单与任务，并支持创建、更新、完成和删除；不根据标题猜测唯一目标。

#### Scenario: 同名任务
- **WHEN** 两个清单有相同标题的任务
- **THEN** 服务使用精确任务引用修改指定项，不能随机选择

### Requirement: 指定完成状态

系统 SHALL 使用明确 completed 布尔值而非翻转，完成重复任务后返回实际系统结果。

#### Scenario: 重试完成动作
- **WHEN** 同一任务被再次设置 completed=true
- **THEN** 不因为重试把任务变回未完成

### Requirement: 保留未修改字段

系统 SHALL 仅修改请求指定字段，保留无时区到期日期和已支持的重复规则；未验证的高级字段不能被描述为完整支持。

#### Scenario: 只改标题
- **WHEN** 用户只更新任务标题
- **THEN** 到期日期、提醒和其他已有字段不被清空

喵～
