# 离线能力边界

## 承诺离线可用

在 Release ZIP 已完整下载并通过 SHA-256 校验后，以下功能不需要网络：

- `lean`、`lake`、`leanc` 和 elan 代理启动。
- Lean 4 标准库与源码访问。
- 编译并运行包内 Hello World。
- Lean 4 与 Tombi VSIX 安装到包内独立扩展目录。
- VS Code 中的 Lean 语言服务器、诊断、补全和 Infoview。
- 整体目录移动或改名后的上述功能。

Mathlib 完整版还承诺：

- `import Mathlib` 无需联网。
- 使用包内固定依赖和官方构建缓存编译 Mathlib 项目。
- VS Code 中加载包内 Mathlib 工作区、诊断、补全、悬停和 Infoview。

启动器不会检查更新，也不会自动下载其他 Lean 版本。

## 不承诺离线

以下行为由用户主动触发，可能访问网络：

- `lake update`
- 添加或更新第三方 Lake 包
- 打开要求 Lean 4.35.0 以外工具链的项目
- 安装其他 VS Code 扩展
- 更新 VS Code 本体

Core 包不包含 Mathlib；上述 Mathlib 能力仅适用于在统一 `init.ps1` 入口中选择 Full 安装的完整版。

## 系统影响

- 不永久修改系统 `PATH`。
- 不写入用户真实的 `%USERPROFILE%\.elan`。
- 不读写用户全局 VS Code 扩展目录和用户设置。
- 运行时数据保存在包内 `data`。
- 删除整个便携目录即可移除运行环境。

Microsoft Visual Studio Code 本体不是 Core 或 Mathlib 离线层的一部分。IDE 入口需要目标机器已有 VS Code；命令行功能不需要 VS Code。

