# portable-lean4

在当前目录生成固定版本、可移动、可离线运行的 Windows Lean 4 开发环境。提供精简 Core 版和包含官方构建缓存的 Mathlib 完整版。

Core 包包含 Lean 4、Lake、标准库、官方自带的 C/LLVM 工具链、隔离的 elan，以及固定版本的 Lean 4、Even Better TOML 和 Tombi VS Code 扩展。它不会永久修改系统 `PATH`，也不会使用用户原有的 `%USERPROFILE%\.elan`。整个目录可以复制、改名或删除。

目前仅支持 Windows x86-64，固定使用 Lean **4.35.0**。完整版固定使用 Mathlib **v4.35.0**。

## 使用

在希望创建环境的目录中打开 PowerShell：

```powershell
irm "https://raw.githubusercontent.com/one-click-run/portable-lean4/main/init.ps1" | iex
```

安装器会像 portable-idris2 一样显示版本选择器：

- **Core**：Lean、Lake、编译工具链和离线 VS Code 扩展，约 0.9 GB。
- **Full (Mathlib)**：Core 加 Mathlib 源码、固定依赖和官方构建缓存，约 3.0 GB。

有 `Out-GridView` 时使用图形选择窗口，否则在终端输入编号。完整版会分别下载并校验 Core 与 Mathlib 离线层，最终合并成一个可移动目录；VS Code 默认打开 `examples\mathlib`。

完整版首次自检可能因 Mathlib 缓存和 Windows Defender 扫描而持续数分钟。安装器会在同一行显示旋转状态和已用时间，不会反复刷屏；若检查失败，则会保留并显示 Lean 的原始输出。

无人值守安装可设置 `ONE_CLICK_RUN_PORTABLE_LEAN4_EDITION=core` 或 `full`。本地脚本也可使用 `-Edition core` / `-Edition full`。

完成后会生成两个入口：

- `OCR-portable-lean4-<版本>.cmd`：进入便携命令行环境。
- `OCR-portable-lean4-<版本>-VSCode.cmd`：使用隔离配置打开对应示例。

VS Code 入口需要机器上已有 Microsoft Visual Studio Code。Lean 4、其固定依赖 Even Better TOML 与 Tombi 扩展均从包内 VSIX 离线安装，不访问 Marketplace，不读写用户的全局扩展目录。

完整版命令行进入后，可构建随包示例：

```cmd
cd examples\mathlib
lake build
```

第一次构建需要加载 Mathlib，在 Windows 上通常需要数十秒。Lake 会保存 `Main.olean` 增量构建产物；源文件未改变时，后续 `lake build` 会复用缓存，通常只需几秒。直接运行 `lake env lean Main.lean` 会在每次调用时重新检查根文件，不适合作为重复构建入口。

## 完全离线安装

完全离线安装时，复制 Core ZIP、Mathlib 的全部 `.partNNN` 分片，以及所有相邻的 `.sha256` 文件。将 `-MathlibArchive` 指向第一个分片，安装器会逐片校验并自动拼接：

```powershell
.\init.ps1 -Edition full `
  -CoreArchive .\portable-lean4-core-4.35.0-windows-x86_64.zip `
  -MathlibArchive .\portable-lean4-mathlib-4.35.0-windows-x86_64.zip.part001
```

Core 离线安装只需 Core ZIP 和相邻校验文件：

```powershell
.\init.ps1 -Edition core `
  -Archive .\portable-lean4-core-4.35.0-windows-x86_64.zip `
  -Checksum .\portable-lean4-core-4.35.0-windows-x86_64.zip.sha256
```

## Core 包内容

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

## Mathlib 完整版额外包含

- Mathlib v4.35.0 源码与官方预编译缓存
- Mathlib 固定依赖图及所有依赖源码
- 可离线增量构建并由 Lean Language Server 加载的 Mathlib 示例；默认使用窄模块导入和 `lake build` 缓存以缩短重复检查，用户仍可按需使用 `import Mathlib`

## 不在离线承诺范围内

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

构建 Mathlib 离线层：

```powershell
.\scripts\build-full.ps1
```

