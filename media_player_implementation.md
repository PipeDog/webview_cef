# Web 媒体播放器接管方案 — 实施结果记录

> 对应设计文档：[media_player_design.md](./media_player_design.md)（v1.2）
> 实施日期：2026-08-03
> 状态：**代码实施完成（Phase 1/2/3 全部落地），macOS 构建通过、逻辑测试通过；GUI 手动验证待反馈**

## 1. 实施概述

按照设计文档 v1.2 的全部 22 条决策，在 `webview_cef` 仓库完成了三阶段（Phase 1 核心链路 / Phase 2 UI 完善 / Phase 3 完整 shim）的代码实施：

- **JS 注入层**：renderer 侧 `OnContextCreated` 在**每个 frame**（含跨源 iframe / OOPIF）的 V8 上下文创建时注入拦截脚本（决策 1、18），先于页面脚本运行，劫持必然生效。
- **JS Bridge**：复用 `$cef` V8 extension Proxy 通道，新增 `MediaPlayer` channel；frameId 由原生从当前 context 的 frame 天然获取，无需 postMessage 降级转发。
- **Flutter 播放器层**：每个 `WebViewController` 一个 `MediaPlayerController`（音频/视频互斥共用，决策 9），fvp（libmdk）后端，Stack 上叠加三形态 UI（全屏 / 浮窗 / 音频 mini bar）。
- **回写链路**：新增原生 `executeJavaScriptInFrame(browserId, frameId, code)`，Dart → JS 状态回写按 frameId 精确定位到元素所在 frame（决策 18 基础）。

## 2. 文件改动清单

### 新增文件

| 文件 | 说明 |
|------|------|
| `lib/src/media/media_player_types.dart` | 消息类型、播放阶段/显示模式等公共枚举（`MediaPlaybackPhase`、`MediaPlayerDisplayMode`、`MediaPlayRequest`、`MediaStateUpdate`、`MediaPlayResult` 等） |
| `lib/src/media/media_player_js_injection.dart` | 内置 JS 拦截脚本字符串常量（经原生 `OnContextCreated` 注入每个 frame） |
| `lib/src/media/media_player_js_bridge.dart` | JS Bridge 消息编解码、Dart→JS 回写代码生成（JSON object literal 嵌入，无需转义） |
| `lib/src/media/media_player_controller.dart` | 每 webview 一个；状态机、fvp 封装、250ms 状态轮询、与 JS/UI 交互 |
| `lib/src/media/media_player_overlay.dart` | Stack 上的 UI 三形态：全屏播放器、浮窗播放器（3 档尺寸/拖拽）、音频 mini bar |
| `web-playground/media-takeover-test.html` | 6 节媒体接管测试套件（basic/iframe/SPA/手势/移除/自定义控件） |
| `web-playground/media-iframe-content.html` | iframe 内容页（含 `$cef` 可用性检查） |

### 修改文件

| 文件 | 改动 |
|------|------|
| `pubspec.yaml` | 添加 `fvp: ^0.37.3` 依赖（决策 2） |
| `common/webview_app.h/.cc` | renderer 侧 `OnBrowserCreated` 接收 `extra_info` 中的脚本字符串；`OnContextCreated` 执行 `context->Eval(script)` 每 frame 注入 |
| `common/webview_handler.h/.cc` | 新增 `executeJavaScriptInFrame(browserId, frameId, code)`（`GetFrameByIdentifier` 定位，frame 失效静默失败）；`setMediaPlayerInjectScript`；`createBrowser` 传 `extra_info`；load 回调增加 `isMainFrame` |
| `common/webview_plugin.cc` | `init` 接收 `mediaPlayerInjectScript` 并缓存；新增 `executeJavaScriptInFrame` method 分发；媒体消息分发与 `isMain` 标记透传 |
| `lib/src/webview.dart` | Stack 叠加 `MediaPlayerOverlay`；`WebViewController` 持有懒创建 `MediaPlayerController`；`onJavascriptChannelMessage` 处理 `MediaPlayer` channel；新增 `executeJavaScriptInFrame` |
| `lib/src/webview_manager.dart` | `initialize()` 传入注入脚本；`onLoadStart` 按 `isMain` 触发 `onPageNavigation()`（决策 13） |
| `example/lib/main.dart` | 新增媒体测试页入口（`Icons.movie_filter` 按钮 + `_loadMediaTest()`） |

### CEF 149 与设计文档的 API 差异处理

| 差异 | 处理 |
|------|------|
| `CreateBrowserSync` 参数顺序为 `(window_info, client, url, settings, extra_info, request_context)` | 传 `(..., extra_info, nullptr)` |
| CEF 122+ 弃用 `GetFrame(int64)`，改为 string frame identifiers + `GetFrameByIdentifier` | `executeJavaScriptInFrame` 直接传递 string frameId |
| CEF 149 `Eval` 需 5 参数 `(code, script_url, start_line, retval, exception)` | 补全签名 |

## 3. 分阶段实施明细

### Phase 1：核心链路（完成）

1. ✅ `pubspec.yaml` 接入 fvp，macOS 构建验证通过。
2. ✅ 原生侧：`OnContextCreated` 每 frame 注入 + `executeJavaScriptInFrame` + `init`/`create` 传脚本。
3. ✅ JS 拦截脚本 v1：劫持 `play()`/`pause()` + `play()` Promise 三种终态（成功 pending / 关闭 AbortError / 失败 reject + 元素保持 paused + error 事件 / 无手势 NotAllowedError）+ `navigator.userActivation.hasBeenActive` 手势判定（降级 500ms 窗口）+ MutationObserver（动态元素/移除/display:none 监控）+ iframe 直接 `$cef` 通道。
4. ✅ JS Bridge 通道（mediaPlayRequest / mediaPauseRequest / mediaStateUpdate / mediaPlayResult / mediaClosed / mediaElementRemoved）。
5. ✅ 全屏播放器 UI + fvp 播放 + 状态回写（paused/currentTime/duration/ended + timeupdate/play/pause 事件，timeupdate 节流 ≥250ms）。
6. ✅ 错误态（决策 22）：`Loading → Error`（「无法播放该视频」）+ 重试按钮（重新加载同一 URL）。
7. ✅ 生命周期：跨文档导航（onLoadStart isMain）立即关闭；元素移除/display:none 关闭；webview 销毁释放 fvp 实例。

### Phase 2：UI 完善（完成）

1. ✅ 浮窗模式：默认右下角、拖拽（onPanUpdate + LayoutBuilder clamp）、3 档尺寸（240×135 / 320×180 / 480×270）、全屏⇄浮窗切换。
2. ✅ 音频 mini bar：380×56 可拖拽胶囊条，播放/暂停、进度（mini progress）、音量、倍速、关闭；播完自动收起。
3. ✅ 错误提示 + 重试（全屏与浮窗均有错误面板）。
4. ✅ blob/MSE 场景「该视频格式不支持」提示（决策 11）。

### Phase 3：完整 shim（完成）

1. ✅ `HTMLMediaElement` 全属性代理：`volume`/`muted`/`playbackRate` setter → `mediaPropertyChange` 转发原生播放器（volume clamp [0,1]）；`currentTime` setter → `mediaSeekRequest`；`readyState`/`networkState`/`seeking`/`buffered`/`seekable`/`played` 从回写镜像（TimeRanges 代理兼容扁平与嵌套数组两种输入）。
2. ✅ 全事件派发：`seeking`/`seeked`、`waiting`（networkState 2）/`playing`（缓冲结束）、`canplay`/`loadedmetadata`（readyState 迁移）、`error`/`abort`/`ended`/`pause`/`play`/`timeupdate`。
3. ✅ 页面自定义控件兼容：拖进度条（currentTime setter）、音量/静音/倍速操作直接生效；readyState/networkState 由播放状态机推导（`_deriveReadyState`/`_deriveNetworkState`）。

## 4. 验证情况

### 4.1 构建验证

- `flutter pub get` 成功，fvp 0.37.3（libmdk）经 CocoaPods 集成。
- macOS debug 构建成功：`✓ Built build/macos/Build/Products/Debug/webview_cef_example.app`。

### 4.2 JS 注入脚本逻辑测试（Node mock 环境）

从 Dart 字符串常量提取真实注入脚本，在 Node 的 DOM mock 环境下执行，48 项断言全部通过，覆盖：

- 手势判定与 `play()` 三种 Promise 终态（决策 14/20/22 联动）；
- `mediaPlayRequest` URL 相对路径 resolve、type/title/gesture 载荷正确；
- 状态回写属性镜像 + timeupdate 节流 + play/pause/ended 事件；
- 元素移除 / display:none → `mediaElementRemoved`（决策 21）+ 幂等性（重复注入 no-op）；
- Phase 3：volume/muted/playbackRate/currentTime 代理、seeking/seeked、readyState 迁移事件、buffered/seekable/played 代理、等待缓冲 cycle。

### 4.3 运行时验证（macOS app 实测）

- 应用正常启动，无崩溃；加载 `media-takeover-test.html`、`media-iframe-content.html`、`about:srcdoc`（跨源 iframe 内容）均成功；
- 页面生命周期日志正常（onPageStarted/onPageFinished/onProgressUpdated）；
- 外部媒体源出现一次 SSL handshake 网络错误（`net_error -100`）——来自测试页外部素材，属环境网络问题，非插件缺陷；
- 跨源 iframe 内容页加载成功，注入脚本未导致任何 frame 崩溃（决策 18 契约初步成立）。

## 5. 待办

- **GUI 手动验证（等待用户反馈）**：全屏播放器弹出/播控、浮窗切换/拖拽/尺寸、iframe（同源/跨源）播放、SPA 路由不关闭、元素移除/display:none 关闭、音频 mini bar、无效 URL 错误+重试、autoplay 静默忽略等（对应设计文档 §8 验证清单 1–9 条）。
- 根据验证反馈修复问题后，按需提交代码（提交前按仓库规范同步 `docs/` 目录）。

## 6. 已知限制（与设计文档 §7 一致，实施未改变）

1. 裸 URL 直传，需要 Cookie/Referer/动态签名的媒体无法播放；
2. blob/MSE 不接管，提示「该视频格式不支持」；
3. 浮窗播放期间页面原始元素黑屏（CEF 无法解码该格式）；
4. v1 仅 macOS（Windows/Linux 原生集成后续版本补齐）；
5. 免费格式（VP8/VP9/Opus/WebM）在页面从未被激活时的自动播放被静默忽略（原本可播），业务需引导用户点击播放。
