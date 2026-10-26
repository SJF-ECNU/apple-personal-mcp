## ADDED Requirements

### Requirement: 实际协议与原生宿主

服务 SHALL 通过真实 stdio/XPC 提供 MCP，跨进程校验签名和用户，支持 doctor/call，stdout 仅承载协议。

#### Scenario: 真实客户端调用
- **WHEN** 客户端初始化并调用 system_status
- **THEN** 通过原生宿主返回实际状态和已实现能力

### Requirement: 邮件完整只读访问

服务 SHALL 查询实际索引及 MIME，支持账户、邮箱、搜索、正文分页、线程、批量与附件；正文搜索不得静默漏掉长正文末尾。

#### Scenario: 分批完整匹配
- **WHEN** 关键词只在长邮件末尾
- **THEN** 能匹配或返回尚未扫描完成及继续游标

### Requirement: 只读模式与源数据边界

服务 SHALL 在只读模式隐藏并拒绝修改工具，不直接写入 Apple 源库；资源引用不得读取允许范围外的文件。

#### Scenario: 使用缓存修改工具
- **WHEN** 只读客户端调用 mail_create_draft
- **THEN** 服务拒绝，源应用没有新增草稿

### Requirement: 官方修改及实际结果

服务 SHALL 使用官方通道操作草稿/旗标/移动并读回核验，发送需真人确认，未知结果不得重发。

#### Scenario: 本机草稿验证
- **WHEN** 创建无收件人的测试草稿并读取
- **THEN** Mail 中可见相同正文，测试不产生外部发送

### Requirement: 本机验证证据

交付 SHALL 分开记录构建、离线测试、协议集成、本机真实读取和真实修改，不能把权限拒绝写成通过。

#### Scenario: 隐私权限不足
- **WHEN** 真实宿主访问 Mail 被系统拒绝
- **THEN** 返回 needs_permission 并明确未通过的验证项，不通过其他进程复制数据绕过

喵～
