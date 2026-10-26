## ADDED Requirements

### Requirement: EventKit 日程读写

系统 SHALL 使用 EventKit 读取、创建、修改和删除事件，尊重访问级别和日历本身的可写性，不直接写 Calendar 私有库。

#### Scenario: 只读订阅日历
- **WHEN** 用户尝试修改只读订阅日历中的事件
- **THEN** 返回只读错误且事件不变

### Requirement: 事件实例与重复范围

系统 SHALL 区分重复系列与实例，重复事件修改和删除必须指定本次或未来范围。

#### Scenario: 仅修改本次会议
- **WHEN** 用户指定 occurrence 修改一场重复会议的时间
- **THEN** 只修改该实例，其他实例符合 EventKit 的本次修改语义

### Requirement: 日历时间语义

系统 SHALL 保留时区、全天日期和跨日语义，并在实际执行会向参与者发送通知的修改前说明影响。

#### Scenario: 全天事件跨夏令时
- **WHEN** 查询或修改跨夏令时边界的全天事件
- **THEN** 保持用户看到的日历日期，不以 UTC 零点转换造成前后偏一天

喵～
