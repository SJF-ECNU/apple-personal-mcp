## ADDED Requirements

### Requirement: Apple 私有数据只读

系统 SHALL 只读打开 Apple 私有数据库和媒体，不迁移、不创建缺失的源库、不 checkpoint，不使用私有 API 写入；衍生文件只写应用自有目录。

#### Scenario: 源库不存在
- **WHEN** 配置的源数据库不存在
- **THEN** 返回 not_found 或 not_configured，不在源位置创建空库

#### Scenario: 只读查询与音频导出
- **WHEN** 查询一个有界样本并导出音频
- **THEN** 查询与导出不改写源数据，副本仅出现在应用自有目录

### Requirement: 读取活动库的 WAL

系统 SHALL 在正常只读访问中包含可用 WAL 的提交，不得通过对活动库设置 immutable 绕过权限；不能取得一致视图时返回明确错误。

#### Scenario: 最新消息仅在 WAL
- **WHEN** 一条已提交的测试消息尚未 checkpoint
- **THEN** 正常只读查询能读取它，或明确返回访问错误，不能成功返回过时数据而不说明

#### Scenario: 需要副本
- **WHEN** 一个长任务需要源库副本
- **THEN** 通过 SQLite backup API 取得一致副本并标明时间，不逐个复制活动数据库文件冒充一致备份

### Requirement: 未知布局与安全解析

系统 SHALL 通过实际结构识别已支持的布局，对未知核心结构明确报错；二进制与归档解析 SHALL 有大小、深度和边界限制。

#### Scenario: 系统升级改变字段
- **WHEN** 必需的核心结构不再匹配任何已测试路径
- **THEN** 相关适配器返回 unsupported_schema，不猜测字段、不修改源库修复

### Requirement: 资源访问范围

系统 SHALL 只接受原生记录派生或应用自有的资源引用，校验实际文件位置；日志不得包含正文、转写全文或音频。

#### Scenario: 构造路径逃逸
- **WHEN** 资源引用或软链接指向允许范围外
- **THEN** 拒绝读取，不能暴露任意用户文件

#### Scenario: 导出资源过期
- **WHEN** 客户端读取已到期清理的资源
- **THEN** 返回过期/不存在状态并允许显式重新取得，不返回空文件作为成功

喵～
