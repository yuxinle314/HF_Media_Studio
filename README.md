# 影音工坊 · Media Studio

一个面向 **Windows 10/11**（以及任何现代浏览器）的纯前端 Web 应用 / PWA，采用 **Apple HIG 风格** 界面，提供三类功能：

1. **摄像头拍照 + 压缩** —— 调用电脑摄像头拍照，自动压缩到 **50KB / 100KB / 200KB**（允许 ±20% 抖动），分辨率可在 `480×270 / 960×540 / 1024×768 / 1920×1080` 间选择或自动匹配。
2. **图片文件压缩** —— 选择 / 拖入任意图片，按相同的目标大小与分辨率压缩。
3. **语音录音 + 声码器压缩** —— **按住按钮录音、松开结束**（最长 60s，带充能进度条，60s = 100%），或选择音频文件，用 **Codec2 超低码率声码器** 编码 / 转码（700C ≈ 700 bps，60s 仅约 5KB）。

> 纯本地处理，音视频数据不上传、不保存。

### 输出文件夹（pics / voices）

借助 **File System Access API**（Edge / Chrome on Windows 支持），可一次性授权一个父文件夹，之后：

- 照片自动存入 `pics/`
- 音频自动存入 `voices/`

父文件夹句柄会记忆在 IndexedDB 中，刷新后仍然有效（再次写入时浏览器可能请求一次权限）。文件名带时间戳，避免同名覆盖。

不支持该 API 的浏览器（如 Firefox）会自动回退为普通下载到「下载」目录。页脚可随时查看 / 更换输出文件夹。

---

## 运行

摄像头 / 麦克风以及 ffmpeg.wasm 都要求 **安全上下文（HTTPS 或 `localhost`）**，因此不能直接用 `file://` 打开，需要一个静态服务器：

```bash
# 任选其一，在 media-studio/ 目录下执行
npx serve .
# 或
python3 -m http.server 8080
```

然后浏览器访问 `http://localhost:8080`（推荐 Edge / Chrome）。

首次打开时 `coi-serviceworker` 会注册并 **自动刷新一次页面**，使其进入跨源隔离（`crossOriginIsolated`）状态——这是 ffmpeg.wasm 多线程核心使用 `SharedArrayBuffer` 的前提。

### 部署到 GitHub Pages

整个目录是静态资源，直接作为站点根（或子路径）发布即可。`coi-serviceworker` 会在 Pages 这类无法自定义响应头的托管上补齐 COOP/COEP 头。

---

## 技术说明

### 图像压缩（`js/image.js`）
- 用 Canvas 将图像缩放到目标分辨率（**不放大**，保持宽高比 contain）。
- 对 JPEG / WebP 的质量做 **二分搜索**，使输出字节落入 `目标 ±20%`。
- 自动模式：从大到小尝试预设分辨率，仅在"即便最低质量仍超标"时降级，取最接近目标的结果。

### 语音声码器（`js/audio.js`）
- 录音：`getUserMedia` + `MediaRecorder`（Opus/WebM），**按住录音、松开结束**（Pointer 事件，兼容鼠标与触屏），最长 60s 自动停止，带实时电平表、计时与充能进度条。
- 编码：[`@ffmpeg/ffmpeg`](https://www.npmjs.com/package/@ffmpeg/ffmpeg) `0.11.6` + 带 libcodec2 的核心 [`@uimaxbai/ffmpeg-core-codec2`](https://www.npmjs.com/package/@uimaxbai/ffmpeg-core-codec2)，命令等价于：
  ```
  ffmpeg -i <输入> -ar 8000 -ac 1 -c:a libcodec2 -mode 700C out.c2
  ```
- 试听：再用 ffmpeg 把 `.c2` 解码回 WAV 播放。
- **ffmpeg 内核在运行时从 CDN（unpkg）加载**，仓库本身不内置约 10MB 的 wasm。首次压缩需联网下载内核。

Codec2 档位：`700C`（极致）/ `1300`（标准）/ `2400`（清晰）/ `3200`（高质）。档位越低体积越小、越偏"对讲机"音质。

---

## 浏览器要求

- Chromium 内核（Edge / Chrome）体验最佳。
- 需支持：`getUserMedia`、`MediaRecorder`、`canvas.toBlob`、`SharedArrayBuffer`、Service Worker。
- WebP 输出依赖浏览器对 `canvas.toBlob('image/webp')` 的支持（Chromium 均支持）。

## 第三方与许可

- `coi-serviceworker`（MIT，Guido Zuidhof）—— 已内置于本目录。
- ffmpeg.wasm 内核运行时从 CDN 加载（未随仓库分发）。
