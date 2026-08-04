# Web 媒体播放器接管方案设计文档

> 状态：**已确认，代码实施完成（Phase 1/2/3 全部落地，macOS 构建通过；GUI 手动验证待反馈）**
> 版本：v1.2
> 日期：2026-08-03
>
> 实施结果记录见 [media_player_implementation.md](./media_player_implementation.md)

## 修订记录

| 版本 | 日期 | 说明 |
|------|------|------|
| v1.0 | 2026-08-03 | 初稿：17 条核心决策 |
| v1.1 | 2026-08-03 | 补充决策 18–22（iframe 支持、SPA 导航、手势窗口、元素移除、Phase 1 错误处理）；明确原生侧改动方案（renderer 侧 OnContextCreated 注入、按 frame 回写）；macos/common 由"零改动"调整为"小改动" |
| v1.2 | 2026-08-03 | 对照审查报告逐条复核后的决策调整：**决策 18** 删除 postMessage 降级链路（`$cef` 为 V8 extension，跨源 iframe 内直接可用，Phase 1 实测兜底）；**决策 19 撤销**（SPA 路由不主动关闭播放器，由元素移除监控决定）；**决策 20** 手势判定改 `navigator.userActivation.hasBeenActive`（降级 500ms 窗口）；**决策 13** 精确为跨文档导航；**决策 14** 语义微调（页面从未激活才静默）；**决策 7** 接受免费格式自动播放回归（补已知限制）；补充 `play()` Promise 三种终态、`mediaPlayResult` 失败联动、`mediaSeekRequest` 归入 Phase 3、iframe 相对 URL resolve、frameId 失效静默处理 |

## 1. 背景与问题

- 应用采用 Flutter 技术栈，支持 PC（macOS/Windows）与移动端跨端。
- PC 端通过 Flutter 中间层封装 CEF 浏览器内核（本仓库 `webview_cef` 插件），供业务 App 展示 Web 页面。
- **问题**：从 https://cef-builds.spotifycdn.com 下载的 CEF 内核（Spotify 构建版）因版权问题**不支持 MP3、MP4（H.264/AAC）等专利编码格式**的播放。
- **目标**：在不更换 CEF 内核版本的前提下，让 Web 页面中的 MP3 等媒体资源可以被播放。

## 2. 解决方案概述

通过 **JS 注入层劫持页面媒体元素**（`<video>` / `<audio>`），在用户触发播放时**接管播放行为**，改用 **Flutter 原生播放器（fvp，基于 libmdk）** 在 Web 容器之上渲染播放 UI，并通过 JS Bridge 与页面保持状态同步。

```
┌─────────────────────────────────────────────────────────┐
│  Flutter 层 (webview_cef 插件)                           │
│  ┌─────────────┐  ┌──────────────────────────────────┐  │
│  │  WebView    │  │  Media Player Overlay (Stack)    │  │
│  │  (Texture)  │  │  ├─ 全屏播放器                    │  │
│  │  CEF 渲染   │  │  ├─ 浮窗播放器（可拖拽/缩放）       │  │
│  └──────┬──────┘  │  └─ 音频 mini bar（可拖拽）        │  │
│         │         └──────────────┬───────────────────┘  │
│         │  JS Bridge ($cef 通道)  │ fvp (libmdk)         │
└─────────┼─────────────────────────┼─────────────────────┘
          │                         │
  ┌───────┴────────────┐   ┌────────┴────────┐
  │  JS 拦截脚本（注入  │   │  裸 URL 直连     │
  │  Web 页面，劫持     │   │  (公开/URL签名)   │
  │  HTMLMediaElement) │   └─────────────────┘
  └────────────────────┘
```

## 3. 已确认的核心决策（22 条）

| # | 决策点 | 结论 |
|---|--------|------|
| 1 | 拦截层级 | **JS 注入层**：劫持 `HTMLMediaElement`，经 JS Bridge 通知 Flutter 弹出原生播放器 |
| 2 | 原生播放器 | **fvp**（基于 libmdk，支持 macOS Metal 渲染、纯音频播放、FFmpeg 全格式解码） |
| 3 | 视频 UI | **全屏模式** + **浮窗模式**（浮窗默认右下角，可拖拽、多档尺寸可切换），两模式间可切换 |
| 4 | 音频 UI | **浮动 mini bar**（可拖拽），播控 UI 包含播放/暂停、进度、音量、倍速、关闭 |
| 5 | 架构位置 | **内置到 webview_cef 插件**（方案 A），目录划分清晰，对现有文件改动最小化 |
| 6 | 生效方式 | **默认开启**，零配置，所有 WebView 自动具备媒体接管能力 |
| 7 | 拦截策略 | **全部媒体元素拦截**（不区分格式，统一走 fvp） |
| 8 | 状态同步 | **B→C 分期**：先实现核心属性和事件（paused/currentTime/duration/ended/timeupdate/play/pause），最终目标为完整 `HTMLMediaElement` shim（readyState/networkState/volume/muted/buffered/seekable/playbackRate 等全属性全事件） |
| 9 | 播放器实例 | **每个 webview 一个播放器实例**；音频与视频**互斥共用**（听音频时点视频 → 音频停、切视频） |
| 10 | 媒体 URL 鉴权 | **裸 URL 直传 fvp**（业务媒体均为公开 URL 或 URL 拼接 authkey 形式） |
| 11 | blob/MSE | v1 **不支持**；遇到 blob URL 等无法直接播放的源，提示「该视频格式不支持」 |
| 12 | 平台范围 | **v1 仅 macOS**；架构（JS 注入 + Dart overlay）天然跨平台，Windows/Linux 后续补齐原生集成 |
| 13 | 页面导航 | **跨文档导航（页面加载/刷新/跳转）立即关闭播放器**（全屏/浮窗/mini bar 全部关闭）；SPA 路由变化**不主动关闭**（见决策 19 撤销说明，由决策 21 元素移除监控决定） |
| 14 | 自动播放 | **有手势才弹出播放器**；无手势的脚本自动播放（autoplay）：页面**从未被用户激活过** → 静默忽略，不打扰用户；页面**被激活过之后** → 跟随浏览器默认行为允许播放（与 Chrome autoplay policy 一致） |
| 15 | 播放结束 | 视频（全屏/浮窗）：**停在结束帧 + 重播按钮 + 用户主动关闭**；音频 mini bar：**播完自动收起** |
| 16 | 多 webview 并存 | **各自独立播放**，不做全局协调（业务几乎不会出现多 webview 同时播放，未来可按需追加） |
| 17 | 播放失败 | **统一错误提示**（「无法播放该视频」）+ 重试按钮 |
| 18 | iframe 支持 | **v1 支持 iframe 内媒体**。拦截脚本经 renderer 侧 `OnContextCreated` 注入到**每个 frame**（含跨源 iframe）；`$cef` 为 V8 extension，注入每个 frame 的 V8 context（含跨源 iframe / OOPIF 独立进程），iframe 内媒体与主 frame 同样直接 `$cef.MediaPlayer.postMessage(...)`，frameId 由通道从当前 context 的 frame 天然获取，**无需 postMessage 降级转发**（依赖 CEF 契约保证，Phase 1 以跨源 iframe 实测用例兜底）；Dart→JS 回写按 `frameId` 定位到具体 frame（原生新增 `executeJavaScriptInFrame`）。**代价：macos/common 由"零改动"调整为小改动**（详见 §5.2） |
| 19 | SPA 导航 | **已撤销**：SPA 路由变化**不主动关闭播放器**，由决策 21 的元素移除 / `display:none` 监控决定（浮窗/mini bar 的设计价值即"播放中可操作网页"，路由切换是最常见的网页操作；跨文档导航仍由决策 13 关闭） |
| 20 | 手势判定 | **`navigator.userActivation.hasBeenActive` 为主判据**（CEF 为 Chromium 内核，原生支持）：页面曾被用户激活 → 视为有手势，点击后异步延迟（>500ms）再 `play()` 同样命中；页面从未激活 → 无手势，静默忽略；极老内核无此 API 时**降级 500ms 窗口** |
| 21 | 元素移除 | 被接管元素被 JS 从 DOM 移除或 `display:none` 隐藏 → **通知 Dart 关闭播放器**（MutationObserver 监控） |
| 22 | Phase 1 错误处理 | **基础错误态一次到位**：`Loading → Error`（「无法播放该视频」）+ 重试按钮（重新加载同一 URL）；blob/MSE 特殊提示等其他错误 UI 仍留 Phase 2 |

## 4. 技术方案详述

### 4.1 JS 拦截层（注入脚本）

**注入机制（v1.2 复核确认）**：拦截脚本作为 Dart 字符串常量（`media_player_js_injection.dart`），`WebviewManager.initialize()` 时经 method channel 传入原生侧缓存；创建 webview 时随 `extra_info` 传给 renderer 进程，`WebviewApp::OnContextCreated`（renderer 侧，`common/webview_app.cc`）在**每个 frame 的 V8 上下文创建时**执行 `context->Eval(script)` 注入。此机制保证：

- **全 frame 覆盖**：主 frame 与 iframe（含跨源 iframe）均注入；
- **时机最早**：先于页面任何脚本运行，劫持必然生效；
- 插件内部完成，业务方无感知（默认开启、零配置）。

> 备选方案（不采用）：浏览器进程侧 `OnLoadStart` 时 `frame->ExecuteJavaScript()` 对每个 frame 注入——存在 V8 上下文尚未创建的竞态，页面早期脚本可能绕过劫持。

拦截策略：

1. **劫持 `HTMLMediaElement.prototype.play` / `.pause`**：
   - `play()` 被调用时，根据**用户手势判定**决定行为：
     - 有手势（判定方式见下）→ 通过 JS Bridge 向 Flutter 发送 `mediaPlayRequest`（携带 mediaId、URL、type、标题、frameId；**URL 为相对路径时先 `new URL(v.src, location.href)` resolve 为绝对 URL**），Flutter 弹出播放器；`play()` 返回一个保持 pending 的 Promise（模拟"播放中"）。
     - 无手势（脚本自动播放）→ 静默记录"已接管"，不弹播放器，元素保持静默。
   - `pause()` 被调用 → 通过 JS Bridge 发送 `mediaPauseRequest`，Flutter 侧暂停。
   - **`play()` 返回 Promise 的三种终态（v1.2 明确）**：
     - 有手势且 fvp 播放启动成功 → Promise 保持 pending；播放器被关闭（用户关闭/跨文档导航/元素移除）时 **reject（AbortError）** 并派发 `abort` 事件，页面 `await play()` 不再永久挂起；
     - fvp 播放失败 → **reject**（同步收到 `mediaPlayResult {success:false}` 后执行），元素保持 paused；
     - 无手势（自动播放被忽略）→ **reject（NotAllowedError）**，与浏览器自动播放被阻止时的行为一致，页面有机会显示"点击播放"。
2. **`MutationObserver` 监控新元素**：动态创建的 `<video>` / `<audio>` 同样被接管。
3. **手势判定（v1.2 重写，决策 20）**：使用 `navigator.userActivation.hasBeenActive`——`true`（该 frame 的 window 曾被用户激活过）→ 视为有手势，点击后异步延迟（>500ms）再 `play()` 同样命中；`false`（页面从未被激活）→ 无手势，静默忽略。该 API 为 **per-window（per-frame）独立**，恰好覆盖"iframe 内事件不冒泡、需各自判定"的诉求，且零事件监听。极老内核无此 API 时降级为 500ms 窗口（监听 mousedown/keydown/触摸事件）。
4. **iframe 通道（v1.2 简化，决策 18）**：`$cef` 为 V8 extension，注入**每个** frame 的 V8 context（含跨源 iframe，OOPIF 独立 renderer 进程同样在 `OnWebKitInitialized` 注册），iframe 内媒体与主 frame 同样直接 `$cef.MediaPlayer.postMessage(...)`——无需探测、无需 postMessage 降级转发；JS→Dart 消息的 frameId 由 `CefJSBridge` 从当前 context 的 frame 天然获取，定位 iframe 无需转发保 frameId。此链路依赖 CEF 契约保证，Phase 1 以跨源 iframe 实测用例验证（§8 清单第 6 条），若实测异常再补降级。
5. **状态回写接收**：接收 Flutter 侧的状态更新（currentTime / paused / duration / ended 等），按 `frameId` 认领归属本 frame 的回写，模拟到被劫持的元素属性上，并派发 `timeupdate`、`play`、`pause`、`ended` 事件（timeupdate 节流 ≥250ms）。
6. **元素移除监控（决策 21）**：MutationObserver（`childList` + `attributes`）对被接管元素持续观察，元素从 DOM 移除或内联样式 `display:none` → 发送 `mediaElementRemoved` 消息 → Dart 关闭播放器；级联样式（class/媒体查询）引起的 `display` 变化以 `getComputedStyle` 复查（或 ResizeObserver 辅助）兜底。SPA 路由切换导致框架卸载/隐藏组件时由此监控触发关闭（决策 19 已撤销，不设路由钩子）。
7. **C 阶段扩展点**：属性 getter/setter 全面代理（volume/muted/playbackRate/readyState/networkState/buffered/seekable 等），事件完整派发。

### 4.2 JS Bridge 协议

复用插件现有 `$cef` Proxy 通道（`javascriptChannelMessage`），插件内部注册一个名为 `MediaPlayer` 的 channel，业务方无感知。`$cef` 消息链路天然携带 `frameId`（`WebviewHandler::OnProcessMessageReceived` 已透传，`common/webview_handler.cc`），媒体消息据此定位来源 frame。

**JS → Dart（页面 → Flutter）**：

| 消息 | 载荷 | 说明 |
|------|------|------|
| `mediaPlayRequest` | `{mediaId, url, type, title, gesture, frameId}` | 用户触发播放，请求弹播放器 |
| `mediaPauseRequest` | `{mediaId}` | 页面脚本请求暂停 |
| `mediaSeekRequest` | `{mediaId, position}` | 页面脚本请求跳转（页面自定义控件拖拽时）。**Phase 3 引入**（v1.2 标注）：Phase 1/2 无发送方（`currentTime` setter 代理在 Phase 3，fvp UI 拖进度条由 Dart 侧直接 seek） |
| `mediaElementRemoved` | `{mediaId}` | 被接管元素从 DOM 移除或 display:none，请求关闭播放器 |

**Dart → JS（Flutter → 页面）**：

| 消息 | 载荷 | 说明 |
|------|------|------|
| `mediaStateUpdate` | `{mediaId, paused, currentTime, duration, ended}` | 播放状态回写（节流）；**经原生 `executeJavaScriptInFrame(browserId, frameId, code)` 定位到元素所在 frame 执行**（现有 `executeJavaScript` 仅作用于主 frame，无法回写 iframe 内元素）。**frameId 失效处理（v1.2 明确）**：导航后 `frame->GetIdentifier()` 可能失效，`executeJavaScriptInFrame` 对 frame 不存在时静默失败 |
| `mediaPlayResult` | `{mediaId, success, error}` | 播放启动结果。**失败时页面侧联动（v1.2 明确）**：`play()` reject + 元素保持 paused（状态回写驱动页面控件复位），派发 `error` 事件 |
| `mediaClosed` | `{mediaId}` | 播放器关闭通知（元素回到初始态） |

### 4.3 Flutter 播放器层

**播放器实例模型**：每个 `WebViewController` 持有且仅持有一个 `MediaPlayerController`（音频/视频共用，互斥）。

**UI 三形态**（叠加在 `WebView` widget 的 `Stack` 上）：

| 形态 | 触发 | 行为 |
|------|------|------|
| 全屏播放器 | 视频 + 用户手势 | 覆盖整个 webview 区域，完整播控（播放/暂停、进度条可拖、音量、倍速、全屏⇄浮窗切换、关闭） |
| 浮窗播放器 | 用户在全屏内切换 | 缩小到可拖拽浮窗（默认右下角，多档尺寸），视频继续播放，用户可操作网页 |
| 音频 mini bar | 音频 + 用户手势 | 浮动 mini bar（可拖拽），播放/暂停、进度、音量、倍速、关闭 |

**状态机**：`Idle → Loading → Playing → Paused → Ended / Error`。

**错误处理**：fvp 播放失败（加载错误/网络错误等）→ UI 显示统一错误提示 + 重试按钮，重试重新加载同一 URL。

**播放结束**：视频 → 停在结束帧显示重播按钮，用户主动关闭；音频 → 自动收起 mini bar。

**生命周期**：
- 跨文档导航（页面加载/刷新/跳转）→ 立即关闭播放器，向页面回写 `mediaClosed`；SPA 路由变化不关闭（决策 19 撤销，由元素移除监控决定）。
- webview 销毁（`controller.dispose()`）→ 释放 fvp 播放器实例。

### 4.4 fvp 集成

- `pubspec.yaml` 添加 `fvp` 依赖（唯一新增第三方依赖，macOS 端经 CocoaPods 引入 mdk）。
- 示例工程 `example/macos/Podfile` 已启用 `use_frameworks!`，构建链兼容。
- fvp 提供 backend API 可直接创建播放器实例（不依赖官方 `video_player` 接口），适合插件内部封装。

## 5. 目录结构规划（改动最小化）

**新增文件**（集中于新目录 `lib/src/media/`）：

```
lib/src/media/
├── media_player_controller.dart   # 每 webview 一个；状态机、fvp 封装、与 JS/UI 交互
├── media_player_overlay.dart      # Stack 上的 UI 三形态（全屏/浮窗/mini bar）
├── media_player_js_bridge.dart    # JS Bridge 消息编解码、channel 注册、回写
├── media_player_js_injection.dart # 内置 JS 拦截脚本（字符串常量，经原生 OnContextCreated 注入）
└── media_player_types.dart        # 消息类型、状态枚举等公共类型
```

**现有文件的改动**（v1.1：macos/common 由"零改动"调整为小改动，支撑决策 18 iframe 支持）：

| 文件 | 改动 |
|------|------|
| `pubspec.yaml` | 添加 `fvp` 依赖 |
| `lib/src/webview.dart` | `WebView` widget 的 Stack 中叠加 `MediaPlayerOverlay`；`WebViewController` 持有 `MediaPlayerController`（懒创建） |
| `lib/src/webview_manager.dart` | `initialize()` 时将拦截脚本传入原生；methodCallHandler 增加媒体消息分发（约 10 行）；新增 `executeJavaScriptInFrame` 调用入口 |
| `lib/webview_cef.dart` | 如需暴露媒体相关 API 则补充 export（v1 可能不需要） |

**原生侧改动（§5.2 详述）**：

| 文件 | 改动 |
|------|------|
| `common/webview_app.cc` | renderer 侧 `OnContextCreated` 执行拦截脚本（每 frame 注入）；`OnBrowserCreated` 接收 `extra_info` 中的脚本字符串并缓存 |
| `common/webview_handler.h/.cc` | 新增 `executeJavaScriptInFrame(browserId, frameId, code)`（`browser->GetFrame(frameId)` 定位，替代现有仅主 frame 的 `executeJavaScript`） |
| `common/webview_plugin.cc` | 新增 method `executeJavaScriptInFrame` 分发；`init` 接收并缓存注入脚本；`create` 时将脚本写入 `extra_info` |
| `macos/Classes/CefWrapper.mm` | 适配新 method 参数透传（若有） |

### 5.2 原生侧注入与回写链路（v1.1 新增）

```
Dart (media_player_js_injection.dart 字符串常量)
  │  method channel: init(mediaPlayerInjectScript)
  ▼
browser 进程 WebviewPlugin 缓存脚本
  │  create(url, extra_info = {mediaPlayerInjectScript})
  ▼
renderer 进程 WebviewApp::OnBrowserCreated(extra_info) → 缓存脚本
  │  每个 frame 的 V8 上下文创建时
  ▼
WebviewApp::OnContextCreated(browser, frame, context)
  │  context->Enter(); context->Eval(mediaScript); context->Exit();
  ▼
每个 frame（含跨源 iframe）页面脚本运行前完成 HTMLMediaElement 劫持

Dart → 指定 frame 回写：
  executeJavaScriptInFrame(browserId, frameId, code)
  → WebviewHandler::executeJavaScriptInFrame
  → browser->GetFrame((int64)frameId)->ExecuteJavaScript(code)
```

## 6. 实施分期

### Phase 1：核心链路（v1）— ✅ 已完成

1. ✅ `pubspec.yaml` 接入 fvp，macOS 构建验证。
2. ✅ 原生侧：`OnContextCreated` 每 frame 注入 + `executeJavaScriptInFrame` + `init`/`create` 传脚本（决策 18 基础）。
3. ✅ JS 拦截脚本 v1：劫持 `play()`/`pause()`（含 Promise 三种终态）+ `userActivation` 手势判定 + MutationObserver（动态元素/移除监控）+ iframe 通道（直接 `$cef`，无降级）。
4. ✅ JS Bridge 通道建立（mediaPlayRequest / mediaStateUpdate / mediaClosed / mediaElementRemoved）。
5. ✅ 全屏播放器 UI + fvp 播放 + 状态回写（B 程度最小集：paused / currentTime / duration / ended / timeupdate / play / pause）。
6. ✅ 错误态（决策 22）：`Loading → Error`（「无法播放该视频」）+ 重试按钮。
7. ✅ 生命周期：跨文档导航 / 元素移除 → 关闭播放器；webview 销毁释放。

**验收**：
- 业务页面点击 MP3/MP4 链接 → 全屏播放器弹出并正常播放、进度可拖、暂停恢复正常、页面元素状态（如播放按钮图标）随播放状态变化；
- 自动播放不弹播放器（页面从未被点击时）；
- 跨文档导航 / 元素移除 / display:none 后播放器关闭；SPA pushState 切换时播放器不关闭；
- iframe 内媒体（含跨源）可正常弹出播放、状态回写正确；
- 无效 URL → 错误提示 + 重试。

### Phase 2：UI 完善 — ✅ 已完成

1. ✅ 浮窗模式：拖拽、多档尺寸、全屏⇄浮窗切换。
2. ✅ 音频 mini bar：可拖拽、播控 UI、播完自动收起。
3. ✅ 错误提示 + 重试。
4. ✅ blob/MSE 场景的「该视频格式不支持」提示。

### Phase 3：完整 shim（目标 C）— ✅ 已完成

1. ✅ `HTMLMediaElement` 全属性代理（volume / muted / playbackRate / readyState / networkState / buffered / seekable / played 等）。
2. ✅ 全事件派发（seeking / seeked / waiting / canplay / loadedmetadata / error 等）。
3. ✅ 页面自定义控件的完整兼容（拖进度条、音量条直接操作页面元素）。

## 7. 已知限制（v1 接受）

1. **裸 URL 直传**：需要 Cookie / Referer / 动态签名的媒体无法播放（业务侧约定媒体为公开 URL 或 URL 携带 authkey）。
2. **blob/MSE**：不拦截接管，遇到即提示「该视频格式不支持」。
3. **浮窗播放期间页面原始元素显示黑屏**：CEF 本身无法解码该格式，页面元素在播放期间无画面（已知限制，不额外处理）。
4. **volume/muted 不同步**：列入 Phase 3。
5. **多 webview 可同时播放**：允许双音叠加，由业务使用方式规避。
6. **v1 仅 macOS**：Windows/Linux 待后续版本。
7. **免费格式（VP8/VP9/Opus/WebM）自动播放行为回归**：Spotify CEF 构建保留免费编解码器，原生可播；决策 7 全部拦截后，页面**从未被激活时**的免费格式自动播放被静默忽略（原本能播）。业务规避：免费格式素材页面引导用户点击播放（有手势时 fvp 同样可播，体验一致）；若业务大量依赖免费格式自动播放，后续可补 `canPlayType()` 分流（Phase 3 候选）。
8. **iframe 内元素移除/`display:none` 监控**：内联样式变化由 MutationObserver（`attributes`）感知，级联样式（class/媒体查询）引起的 `display` 变化经 `getComputedStyle` 复查，存在毫秒级判定延迟。

## 8. 测试验证方案

**测试页面**：在现有 `web-playground/media-test.html`（MP3/MP4/HLS/RTMP/RTSP 用例已具备）基础上补充：

- iframe 内嵌媒体（同源 + 跨源各一，验证注入与回写链路；跨源用例验证 iframe 内 `$cef` 直接可用——决策 18 的契约兜底实测）
- SPA 路由用例（`history.pushState` / `location.hash` 切换，验证播放器**不**关闭、继续播放，组件卸载后由元素移除监控关闭）
- 播放中移除媒体元素 / `display:none`（验证播放器关闭）
- 用户点击页面后异步延迟 `play()`（>500ms，验证 `hasBeenActive` 命中 → 弹出播放器）
- 页面从未被点击时带 `autoplay` 属性的元素（验证静默忽略）
- 带自定义播放控件、依赖 `timeupdate` / `ended` 事件的页面（验证状态回写）

**验证清单**（macOS）：

1. 点击播放 → 全屏播放器弹出 → 正常播放/暂停/拖进度/音量/倍速。
2. 全屏 ⇄ 浮窗切换、浮窗拖拽、尺寸切换。
3. 页面 JS 读 `paused` / `currentTime` 与播放器一致；`timeupdate` / `ended` 事件驱动页面 UI 正常。
4. 页面从未被点击时 autoplay 元素不弹播放器；页面被点击过之后 autoplay 跟随浏览器行为。
5. 跨文档导航 / 元素移除 / display:none 后播放器关闭；SPA pushState 切换时播放器**不**关闭（组件卸载则由元素移除监控关闭）。
6. iframe 内媒体（同源/跨源）点击播放 → 播放器弹出、状态回写正确；跨源 iframe 内 `typeof $cef` 确认可用（决策 18 契约实测）。
7. 音频点击 → mini bar 出现 → 播完自动收起。
8. 无效 URL → 错误提示 + 重试。
9. webview 销毁无泄漏（fvp 实例释放）。
