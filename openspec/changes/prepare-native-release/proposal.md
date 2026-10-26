## Why

用户要求发布 Release，并在发布前确定了简约黑白的「入口与工作空间」App 图标。

## What Changes

- 将用户选定的 GPT Image 图形生成完整尺寸 ICNS，加入应用包与原生侧栏。
- 增加 Release 优化构建与项目许可证打包，统一版本号为 0.5.0。
- 验证优化构建、签名、图标、既有 MCP 接入及公开文件范围，发布 GitHub 开发预览 Release。

## Capabilities

### New Capabilities
- `native-distribution`: 带原生图标的开发预览分发。

## Impact

保留现有 XPC 签名要求、权限与确认机制，不包含用户数据、凭据或诊断文件。当前只有 Development 签名身份，不具备 Developer ID 签名与公证条件，发布页明确说明该限制，不以修改隐私权限或关闭系统保护来使安装通过。

喵～
