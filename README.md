# 短波通信多媒体处理中心

**建设单位：** 中国传媒大学 广播电视智能化教育部工程研究中心
**当前版本：** v1.2.0（2026-06-30）

一个面向 **Windows 10/11**（以及任何现代浏览器）的纯前端 Web 应用 / PWA，采用 **Apple HIG 风格** 界面，提供四类功能：

1. **语音转文字** —— 调用浏览器语音识别能力进行实时中文听写，单次最长 60s，可复制或保存识别文本。
2. **摄像头拍照 + 压缩** —— 调用电脑摄像头拍照，自动压缩到 **50KB / 100KB / 200KB**（允许 ±20% 抖动），分辨率可在 `480×270 / 960×540 / 1024×768 / 1920×1080` 间选择或自动匹配。
3. **图片文件压缩** —— 选择 / 拖入任意图片，按相同的目标大小与分辨率压缩。
4. **语音录音 + 声码器压缩** —— **按住按钮录音、松开结束**（最长 60s，带充能进度条，60s = 100%），或选择音频文件，用 **Codec2 超低码率声码器** 编码 / 转码（700C ≈ 700 bps，60s 仅约 5KB），并可把已有 `.c2` 文件转成普通播放器可播放的 MP3。

> 照片、音频压缩与转码在浏览器本地处理；语音转文字由浏览器语音识别能力提供，可能依赖浏览器或系统服务。

### 输出文件夹（pics / voices）

借助 **File System Access API**（Edge / Chrome on Windows 支持），可一次性授权一个父文件夹，之后：

- 照片自动存入 `pics/`
- 音频自动存入 `voices/`

父文件夹句柄会记忆在 IndexedDB 中，刷新后仍然有效（再次写入时浏览器可能请求一次权限）。文件名带时间戳，避免同名覆盖。

不支持该 API 的浏览器（如 Firefox）会自动回退为普通下载到「下载」目录。页脚可随时查看 / 更换输出文件夹。

---

## 运行

摄像头 / 麦克风以及 ffmpeg.wasm 都要求 **安全上下文（HTTPS 或 `localhost`）**，因此不能直接用 `file://` 打开，需要一个静态服务器：

### 一键启动（Windows）

在项目目录双击 `start.bat` 即可启动本地服务，脚本会自动打开浏览器：

```text
http://127.0.0.1:8080/
```

如果 8080 已被占用，脚本会自动顺延使用 8081、8082 等空闲端口，并在窗口中显示实际地址。

部署到其它 Windows 电脑时，复制整个项目目录，或从 GitHub 下载 / 克隆仓库后，双击 `start.bat` 即可。该方式不依赖 Python 或 Node.js，只需要 Windows 自带的 PowerShell。

关闭服务时，回到启动脚本的命令行窗口按 `Ctrl+C`。

如 8080 端口被占用，可手动换端口：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\serve-local.ps1 -Port 8081
```

### 命令行启动

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
- 语音转文字：`SpeechRecognition` / `webkitSpeechRecognition`，实时麦克风识别，最长 60s，不支持直接识别已选音频文件。
- 编码：[`@ffmpeg/ffmpeg`](https://www.npmjs.com/package/@ffmpeg/ffmpeg) `0.11.6` + 带 libcodec2 的核心 [`@uimaxbai/ffmpeg-core-codec2`](https://www.npmjs.com/package/@uimaxbai/ffmpeg-core-codec2)，命令等价于：
  ```
  ffmpeg -i <输入> -ar 8000 -ac 1 -c:a libcodec2 -mode 700C out.c2
  ```
- 试听：再用 ffmpeg 把 `.c2` 解码回 WAV 播放。
- MP3 转码：选择 `.c2` 文件后，浏览器内用同一 ffmpeg 内核转成 16 kHz 单声道 MP3，便于用普通播放器播放或分享。
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
