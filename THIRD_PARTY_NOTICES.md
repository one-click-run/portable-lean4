# 第三方软件说明

本仓库的启动器、安装器和构建脚本使用 MIT License。

发布包包含下列第三方软件，其权利仍归各自上游所有：

| 组件 | 上游 | 许可证 |
|---|---|---|
| Lean 4 | https://github.com/leanprover/lean4 | Apache-2.0 |
| elan | https://github.com/leanprover/elan | MIT OR Apache-2.0 |
| Lean 4 VS Code extension | https://github.com/leanprover/vscode-lean4 | Apache-2.0 |
| Tombi | https://github.com/tombi-toml/tombi | MIT |
| Mathlib | https://github.com/leanprover-community/mathlib4 | Apache-2.0 |

Mathlib 完整版还包含固定在 `lake-manifest.json` 中的第三方 Lean 包。各包源码目录内保留其上游许可证文件；`MATHLIB-SOURCE-MANIFEST.json` 和 `MATHLIB-SBOM.spdx.json` 记录实际提交与来源。

Lean 官方工具链还包含其运行所需的编译器、求解器和其他第三方组件。上游归档中的许可证文件与声明会原样保留在工具链目录中。构建生成的 `SOURCE-MANIFEST.json` 与 `SBOM.spdx.json` 记录实际打包版本和来源。

Microsoft Visual Studio Code 不包含在发布包中。

