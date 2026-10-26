## ADDED Requirements

### Requirement: 原生图标
App SHALL 包含用户选定的黑白入口图标及标准尺寸 ICNS，窗口品牌与应用包使用同一图形，不改变六个接入应用的原生图标。

#### Scenario: 构建应用
- **WHEN** 用户构建并打开 App
- **THEN** 应用包声明图标资源，侧栏显示同一品牌符号，图形外缘保留透明度

### Requirement: 可复现的开发预览分发
项目 SHALL 支持优化构建，发布的 app、MCP 版本与标签保持一致，并附带本项目与第三方许可。发布说明 SHALL 如实说明平台、签名、公证和验证范围。

#### Scenario: 无发行证书
- **WHEN** 当前仅有 Development 身份且没有完成公证
- **THEN** Release 标注为开发预览，不声称可直接在所有 Mac 通过 Gatekeeper，提供源码构建方式并保留现有签名校验

### Requirement: 发布内容范围
公开分发 SHALL 只包含源码和构建所得的应用资源，不打包本机 App Support、凭据、活动日志、数据库、采样或录音。

#### Scenario: 上传 Release 资产
- **WHEN** app 被压缩并上传 GitHub
- **THEN** 校验资产仅包含预期应用包、签名和许可文件，标签对应已提交源代码，且已执行优化构建测试

喵～
