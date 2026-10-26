## ADDED Requirements

### Requirement: 公开源码分发

仓库 SHALL 包含构建所需源码、依赖版本、合成测试样本、配置模板及现有第三方许可说明，并排除私密运行数据、构建缓存、CodeGraph 索引和原始 Instruments 采样。

#### Scenario: 首次公开推送

- **WHEN** 当前实现按功能导入 Git 并推送 GitHub
- **THEN** main 包含可构建的完整实现，仓库公开可见，远端提交与本地一致，且已提交对象中没有真实凭据、个人内容或本机采样文件

喵～
