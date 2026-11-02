# 构建说明

## 环境

- Windows x86-64
- PowerShell 5.1 或更高版本
- Git
- Core 约需 8 GB、完整版建议至少 20 GB 可用磁盘空间
- 可访问 GitHub Releases

不需要预装 Lean 或 elan。

## 构建

```powershell
.\scripts\test.ps1
.\scripts\build-core.ps1
```

构建 Mathlib 完整版离线层：

```powershell
.\scripts\build-full.ps1 -OutputDirectory .\dist-full
```

完整版构建会先构建 Core，固定 Mathlib v4.35.0 的完整 Git 依赖图，获取 Mathlib 官方缓存，删除不需要的 Git 元数据，再断网代理条件下编译示例。输出是与 Core 叠加安装的 Mathlib ZIP，而不是重复包含 Core。

构建脚本会：

1. 下载并校验固定版本的 Lean 与 elan。
2. 在临时 payload 中建立隔离的 `ELAN_HOME`。
3. 将 Lean 放入 elan 期望的固定工具链目录。
4. 下载并校验固定 VSIX。
5. 编译并运行 Hello World。
6. 验证 VS Code 工作区和隔离配置。
7. 生成来源清单和 SPDX SBOM。
8. 压缩并生成 SHA-256 文件。

下载文件缓存在 `.cache`，重复构建时会先校验再复用。临时目录位于 `.build`。

## 更换版本

修改 `scripts/versions.psd1`、`vscode-extensions/manifest.json` 和示例的 `lean-toolchain` 后，必须重新执行完整构建与测试。禁止只修改显示版本而复用旧工具链。

