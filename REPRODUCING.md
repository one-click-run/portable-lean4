# 发布复现

当前 Core 发布固定以下输入：

| 组件 | 版本 | SHA-256 |
|---|---:|---|
| Lean Windows ZIP | 4.35.0 | `5fc033e93e1a7bc59c5ebf311103d2c9cd18d4b3eddda4ffa3414e8adb0ef79e` |
| elan Windows ZIP | 4.2.4 | `fad2e980a191c15884cc1d80d170ffc5fa84f3774541020145b66d1a644c6111` |
| Lean 4 VSIX | 0.0.240 | `8b1910a174c7b07441eb07f9be6909d29f22d4dacdc8ce94e7de4d6350af6c11` |
| Tombi Windows x64 VSIX | 1.9.8 | `2c9988f6bdddcfe1a8d4753b7aec16f7751d22c552351333fd5bcba9bdbceef2` |

权威机器可执行定义是 `.github/workflows/publish-core.yml`。本地复现命令：

```powershell
git clone https://github.com/one-click-run/portable-lean4.git
cd portable-lean4
.\scripts\test.ps1
.\scripts\build-core.ps1 -OutputDirectory .\dist
```

输出包括：

- `portable-lean4-core-4.35.0-windows-x86_64.zip`
- 对应 `.sha256`
- `source-manifest.json`
- SPDX 2.3 SBOM

不同机器的 ZIP 字节可能因为文件时间戳或压缩器版本而不同。包内组件由固定上游 SHA-256 验证，且构建后执行功能测试。

## Mathlib 完整版

完整版额外固定：

- Mathlib tag：`v4.35.0`
- Mathlib commit：`56a005855ea17e0b0958f73ec801ae140b0a1679`
- 依赖提交：由该版本 Mathlib 的 `lake-manifest.json` 和生成的根项目 manifest 双重锁定
- 预编译文件：由 Mathlib 自带 `cache` 工具按固定源码提交获取

权威构建定义是 `.github/workflows/publish-full.yml`：

```powershell
.\scripts\test.ps1
.\scripts\build-full.ps1 -OutputDirectory .\dist-full
```

输出为 `portable-lean4-mathlib-4.35.0-windows-x86_64.zip` 及 SHA-256、来源清单和 SPDX SBOM。安装时由 `init-full.ps1` 与经过独立校验的 Core ZIP 合并。

