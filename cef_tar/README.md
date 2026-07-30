# CEF Tarball 离线缓存

将 CEF 预编译包提前下载到用户级缓存目录，构建脚本会自动识别并跳过 CDN 下载，大幅加速首次构建。

## 缓存路径

所有平台使用统一的用户级缓存目录，概念一致，仅路径写法不同：

| 平台 | 默认路径 |
|------|---------|
| macOS | `~/.cef/tar/`（即 `/Users/<name>/.cef/tar/`） |
| Linux | `~/.cef/tar/`（即 `/home/<name>/.cef/tar/`） |
| Windows | `%USERPROFILE%\.cef\tar\`（即 `C:\Users\<name>\.cef\tar\`） |

可通过环境变量 `CEF_TAR_CACHE_DIR` 覆盖默认路径（可选，详见[自定义缓存路径](#自定义缓存路径)）。

## 为什么需要

Spotify CDN 在国内下载速度可能非常慢（几十分钟），而使用本地 tarball 仅需数秒即可完成。缓存目录是用户级的，**与项目位置无关**——无论 `webview_cef` 是以本地路径、Git 依赖还是 pub 依赖的方式集成，构建脚本都会在统一位置查找 tarball。

## 快速开始

### 方式一：脚本自动下载（推荐，全平台通用）

```bash
bash cef_tar/download_cef_tars.sh                        # macOS（arm64 + x86_64）
bash cef_tar/download_cef_tars.sh --platform windows      # Windows x64
bash cef_tar/download_cef_tars.sh --platform linux         # Linux x64
bash cef_tar/download_cef_tars.sh --platform linux-arm64   # Linux arm64 (eLinux)
```

脚本会自动解析 CEF 版本号，将 tarball 下载到对应平台的默认缓存目录。

### 方式二：手动下载放置（macOS / Linux）

```bash
mkdir -p ~/.cef/tar

# macOS arm64
curl -L -o ~/.cef/tar/cef_binary_149.0.4+g2f1bfd8+chromium-149.0.7827.156_macosarm64.tar.bz2 \
  "https://cef-builds.spotifycdn.com/cef_binary_149.0.4%2Bg2f1bfd8%2Bchromium-149.0.7827.156_macosarm64.tar.bz2"

# macOS x86_64
curl -L -o ~/.cef/tar/cef_binary_149.0.4+g2f1bfd8+chromium-149.0.7827.156_macosx64.tar.bz2 \
  "https://cef-builds.spotifycdn.com/cef_binary_149.0.4%2Bg2f1bfd8%2Bchromium-149.0.7827.156_macosx64.tar.bz2"

# Windows x64
curl -L -o ~/.cef/tar/cef_binary_149.0.4+g2f1bfd8+chromium-149.0.7827.156_windows64.tar.bz2 \
  "https://cef-builds.spotifycdn.com/cef_binary_149.0.4%2Bg2f1bfd8%2Bchromium-149.0.7827.156_windows64.tar.bz2"

# Linux x64
curl -L -o ~/.cef/tar/cef_binary_149.0.4+g2f1bfd8+chromium-149.0.7827.156_linux64.tar.bz2 \
  "https://cef-builds.spotifycdn.com/cef_binary_149.0.4%2Bg2f1bfd8%2Bchromium-149.0.7827.156_linux64.tar.bz2"

# Linux arm64
curl -L -o ~/.cef/tar/cef_binary_149.0.4+g2f1bfd8+chromium-149.0.7827.156_linuxarm64.tar.bz2 \
  "https://cef-builds.spotifycdn.com/cef_binary_149.0.4%2Bg2f1bfd8%2Bchromium-149.0.7827.156_linuxarm64.tar.bz2"
```

> **注意**：URL 中的 `+` 必须编码为 `%2B`。CEF 版本号以 `third/download.cmake` 中的 `CEF_VERSION` 为准，上述命令中的版本号仅作示例。

## 效果

放置 tarball 后，构建日志中会显示：

```
==> Using local cef_binary_..._macosarm64.tar.bz2 (arm64) from /Users/<you>/.cef/tar/
```

而非：

```
==> Downloading cef_binary_..._macosarm64.tar.bz2 (arm64)
```

## 自定义缓存路径

默认缓存目录如上表所示。如需自定义（如 CI 环境），可设置环境变量 `CEF_TAR_CACHE_DIR`：

```bash
# macOS / Linux
export CEF_TAR_CACHE_DIR=/path/to/custom/cache
bash cef_tar/download_cef_tars.sh --platform linux

# Windows (PowerShell)
$env:CEF_TAR_CACHE_DIR = "D:\cef-cache"
```

此环境变量为可选参数，不设置时自动使用各平台默认路径。该变量对 `pod install`（macOS）和 CMake 构建（Windows / Linux / eLinux）均生效。

## 各平台 tarball 文件名

| 平台 | tarball 文件名 |
|------|---------------|
| macOS arm64 | `cef_binary_<version>_macosarm64.tar.bz2` |
| macOS x86_64 | `cef_binary_<version>_macosx64.tar.bz2` |
| Windows x64 | `cef_binary_<version>_windows64.tar.bz2` |
| Linux x64 | `cef_binary_<version>_linux64.tar.bz2` |
| Linux arm64 | `cef_binary_<version>_linuxarm64.tar.bz2` |

## 版本升级

CEF 版本升级后（`third/download.cmake` 中的 `CEF_VERSION` 变更），只需重新运行 `download_cef_tars.sh` 下载新版本 tarball。旧版本 tarball 可手动删除以释放磁盘空间（每个约 300 MB）。
