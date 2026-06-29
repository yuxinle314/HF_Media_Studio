// 音频声码器模块
// 使用 ffmpeg.wasm + libcodec2 实现超低码率语音编码 / 任意音频转码.
// ffmpeg 多线程核心需要 SharedArrayBuffer, 即 crossOriginIsolated 环境
// (由 coi-serviceworker 提供).
//
// 运行时从 CDN 加载 ffmpeg, 仓库本身不内置 ~10MB 的 wasm 体积.

const FFMPEG_UMD =
  "https://unpkg.com/@ffmpeg/ffmpeg@0.11.6/dist/ffmpeg.min.js";
const CORE_PATH =
  "https://unpkg.com/@uimaxbai/ffmpeg-core-codec2@0.11.3/dist/ffmpeg-core.js";

let ffmpeg = null;
let loadingPromise = null;
let progressCb = null;

/** 动态注入一个 <script> */
function injectScript(src) {
  return new Promise((resolve, reject) => {
    if (document.querySelector(`script[src="${src}"]`)) return resolve();
    const s = document.createElement("script");
    s.src = src;
    s.onload = () => resolve();
    s.onerror = () => reject(new Error(`脚本加载失败: ${src}`));
    document.head.appendChild(s);
  });
}

/** 惰性加载并初始化 ffmpeg (含 codec2) */
async function getFFmpeg(onProgress) {
  progressCb = onProgress || null;
  if (ffmpeg) return ffmpeg;
  if (loadingPromise) return loadingPromise;

  loadingPromise = (async () => {
    if (!self.crossOriginIsolated) {
      throw new Error(
        "当前页面未进入跨源隔离 (crossOriginIsolated) 状态, 无法运行 ffmpeg.wasm。\n" +
          "请通过本地服务器 (如 npx serve) 或 HTTPS 访问, 并确保 coi-serviceworker 已注册后刷新页面。"
      );
    }
    await injectScript(FFMPEG_UMD);
    const { createFFmpeg, fetchFile } = self.FFmpeg;
    const ff = createFFmpeg({ log: false, corePath: CORE_PATH });
    ff.setProgress(({ ratio }) => {
      if (progressCb && ratio >= 0 && ratio <= 1) progressCb(ratio);
    });
    await ff.load();
    ff._fetchFile = fetchFile;
    ffmpeg = ff;
    return ff;
  })();

  try {
    return await loadingPromise;
  } catch (e) {
    loadingPromise = null; // 允许重试
    throw e;
  }
}

/** 从 emscripten FS 读出的视图拷贝为独立 ArrayBuffer 的 Blob */
function toBlob(data, mime) {
  return new Blob([new Uint8Array(data)], { type: mime });
}

/**
 * 编码 / 转码到 Codec2 (.c2).
 * @param {Blob|File} input 任意可被 ffmpeg 解析的音频
 * @param {string} mode Codec2 档位: '3200'|'2400'|'1600'|'1400'|'1300'|'1200'|'700C'
 * @param {(ratio:number)=>void} [onProgress]
 * @returns {Promise<Blob>} audio/codec2
 */
export async function encodeToCodec2(input, mode, onProgress) {
  const ff = await getFFmpeg(onProgress);
  const inName = "in_" + Date.now();
  const outName = "out.c2";
  ff.FS("writeFile", inName, await ff._fetchFile(input));
  try {
    await ff.run(
      "-i", inName,
      "-ar", "8000",   // codec2 固定 8kHz
      "-ac", "1",      // 单声道
      "-c:a", "libcodec2",
      "-mode", mode,
      outName
    );
    const data = ff.FS("readFile", outName);
    return toBlob(data, "audio/codec2");
  } finally {
    try { ff.FS("unlink", inName); } catch {}
    try { ff.FS("unlink", outName); } catch {}
  }
}

/**
 * 把 .c2 解码回可播放的 WAV (用于试听).
 * .c2 文件头自带 mode 信息, 无需再指定.
 * @param {Blob} c2 audio/codec2
 * @returns {Promise<Blob>} audio/wav
 */
export async function decodeCodec2ToWav(c2, onProgress) {
  const ff = await getFFmpeg(onProgress);
  const inName = "dec_" + Date.now() + ".c2";
  const outName = "dec.wav";
  ff.FS("writeFile", inName, await ff._fetchFile(c2));
  try {
    await ff.run("-i", inName, outName);
    const data = ff.FS("readFile", outName);
    return toBlob(data, "audio/wav");
  } finally {
    try { ff.FS("unlink", inName); } catch {}
    try { ff.FS("unlink", outName); } catch {}
  }
}

/** 预热 (可选): 提前加载 ffmpeg 以减少首次压缩等待 */
export function warmup(onProgress) {
  return getFFmpeg(onProgress).catch(() => {});
}
