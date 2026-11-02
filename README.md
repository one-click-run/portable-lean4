# portable-lean4

在当前目录生成固定版本、可移动、可离线运行的 Windows Lean 4 Core 开发环境。

Core 包包含 Lean 4、Lake、标准库、官方自带的 C/LLVM 工具链、隔离的 elan，以及固定版本的 Lean 4 和 Tombi VS Code 扩展。它不会永久修改系统 `PATH`，也不会使用用户原有的 `%USERPROFILE%\.elan`。整个目录可以复制、改名或删除。

目前仅支持 Windows x86-64，固定使用 Lean **4.35.0**。Mathlib 不包含在 Core 包中，后续将作为单独的大型发行包提供。

## 使用

在希望创建环境的目录中打开 PowerShell：

```powershell
irm "https://raw.githubusercontent.com/one-click-run/portable-lean4/main/init.ps1" | iex
```

完成后会生成两个入口：

- `OCR-portable-lean4-<版本>.cmd`：进入便携命令行环境。
- `OCR-portable-lean4-<版本>-VSCode.cmd`：用隔离配置打开包内示例。

VS Code 入口需要机器上已有 Microsoft Visual Studio Code。Lean 4 与 Tombi 扩展均从包内 VSIX 离线安装，不访问 Marketplace，不读写用户的全局扩展目录。可通过 `ONE_CLICK_RUN_VSCODE` 指定 `code.cmd` 或 `Code.exe`。

完全离线的机器可以同时复制 ZIP 与相邻的 `.sha256` 文件，然后执行：

```powershell
.\init.ps1 `
  -Archive .\portable-lean4-core-4.35.0-windows-x86_64.zip `
  -Checksum .\portable-lean4-core-4.35.0-windows-x86_64.zip.sha256
```

## 包内内容

- Lean 4.35.0
- Lake
- Lean 标准库及源码
- `leanc` 与官方编译工具链
- elan 4.2.4，仅管理包内固定工具链
- `leanprover.lean4` 0.0.240
- `tombi-toml.tombi` 1.9.8
- 可编译、可运行的 Hello World Lake 项目

## 便携与隔离

启动器会固定：

```text
ELAN_TOOLCHAIN=leanprover/lean4:v4.35.0
ELAN_HOME=<便携目录>\data\home\.elan
```

VS Code 进程还会获得包内专用的 `USERPROFILE`。这样 Lean 扩展即使主动探测 `%USERPROFILE%\.elan\bin`，看到的也只会是包内 elan，而不是用户真实配置。

完整离线边界见 [`OFFLINE-GUARANTEE.md`](OFFLINE-GUARANTEE.md)。构建来源、校验值和复现方法见 [`REPRODUCING.md`](REPRODUCING.md)。

## 不在 Core 承诺范围内

- Mathlib
- 自动切换多个 Lean 版本
- 自动更新 Lean 或扩展
- 任意第三方 Lake 依赖离线安装
- 打开要求其他 Lean 版本的项目
- 用户主动执行 `lake update` 等联网操作

## 开发

轻量验证：

```powershell
.\scripts\test.ps1
```

构建完整 Core 包：

```powershell
.\scripts\build-core.ps1
```

完整构建需要下载约 900 MB 的官方 Lean Windows 归档，并在 `dist` 中生成 ZIP、SHA-256、来源清单与 SPDX SBOM。

