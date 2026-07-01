// 短波通信多媒体处理中心 · 主逻辑
import { formatBytes, downloadBlob, toast, bindSegmented, fmtSeconds, stamp } from "./util.js";
import { compressToTarget, loadBitmap } from "./image.js";
import { encodeToCodec2, decodeCodec2ToWav, decodeCodec2ToMp3 } from "./audio.js";
import { save, supported as fsSupported, restoreBaseDir, chooseBaseDir, currentBaseName } from "./storage.js";

const $ = (id) => document.getElementById(id);
const DECIMAL_KB = 1000;
const TRANSFER_LIMIT_BYTES = 256000;

/* ============================================================
   顶部数字时钟
   ============================================================ */
function initClock() {
  const el = $("live-clock");
  if (!el) return;
  const pad = (n) => String(n).padStart(2, "0");
  const render = () => {
    const d = new Date();
    el.textContent =
      `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  };
  render();
  setInterval(render, 1000);
}

/* ============================================================
   输出文件夹 (pics / voices)
   ============================================================ */
function updateSaveLocLabel() {
  const el = $("saveloc-name");
  if (!el) return;
  const n = currentBaseName();
  el.textContent = n ? `${n}/（pics, voices）` : "未设置（保存时将提示选择）";
}

/** 统一保存出口: 优先写入所选文件夹的子目录, 否则普通下载 */
async function saveOutput(subdir, filename, blob) {
  const res = await save(subdir, filename, blob, () => downloadBlob(blob, filename));
  if (res.method === "fs") {
    toast(`已保存到 ${res.path}`);
    updateSaveLocLabel();
  } else if (res.method === "download") {
    toast(`已下载 ${filename}`);
  }
  // cancel: 用户取消选择, 不提示
}

async function uploadOutput(subdir, filename, blob, btn) {
  if (!blob) return;
  if (blob.size > TRANSFER_LIMIT_BYTES) {
    toast(`上传失败: 文件超过 ${formatBytes(TRANSFER_LIMIT_BYTES)}`);
    return;
  }

  const originalText = btn ? btn.textContent : "";
  if (btn) {
    btn.disabled = true;
    btn.textContent = "上传中…";
  }

  try {
    const params = new URLSearchParams({ subdir, filename });
    const resp = await fetch(`/api/upload?${params.toString()}`, {
      method: "POST",
      headers: { "Content-Type": blob.type || "application/octet-stream" },
      body: blob,
      cache: "no-store",
    });
    const isJson = (resp.headers.get("content-type") || "").includes("application/json");
    const data = isJson ? await resp.json() : null;
    if (!resp.ok || !data || !data.ok) {
      throw new Error(data?.error || `HTTP ${resp.status}`);
    }
    toast(`已上传到服务电脑: ${data.path}`);
  } catch (e) {
    toast("上传失败: " + (e.message || e));
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.textContent = originalText;
    }
  }
}

async function initStorage() {
  const nameEl = $("saveloc-name");
  const btn = $("saveloc-btn");
  if (!fsSupported()) {
    nameEl.textContent = "浏览器下载（当前浏览器不支持按文件夹保存）";
    return;
  }
  btn.hidden = false;
  await restoreBaseDir();
  updateSaveLocLabel();
  btn.addEventListener("click", async () => {
    try {
      await chooseBaseDir();
      updateSaveLocLabel();
      toast("已设置输出文件夹");
    } catch (e) {
      if (e && e.name !== "AbortError") toast("选择失败: " + (e.message || e));
    }
  });
}

/* ============================================================
   标签切换
   ============================================================ */
function initTabs() {
  const tabs = document.querySelectorAll(".topbar .seg-item[data-tab]");
  const panels = {
    camera: $("panel-camera"),
    image: $("panel-image"),
    audio: $("panel-audio"),
  };
  tabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      tabs.forEach((t) => t.classList.remove("is-active"));
      tab.classList.add("is-active");
      Object.values(panels).forEach((p) => p.classList.remove("is-active"));
      panels[tab.dataset.tab].classList.add("is-active");
    });
  });
}

/* 把分辨率分段值解析成 {w,h} 或 null(自动) */
function parseRes(val) {
  if (!val || val === "auto") return null;
  const [w, h] = val.split("x").map(Number);
  return { w, h };
}

/* 渲染图像压缩结果到指定 DOM */
function renderImageResult({ imgEl, metaEl, cardEl, dlBtn, uploadBtn }, result, originalBytes, baseName) {
  const { blob, width, height, quality, status } = result;
  const url = URL.createObjectURL(blob);
  imgEl.src = url;

  const ext = blob.type === "image/webp" ? "webp" : "jpg";
  const kb = Math.round(blob.size / DECIMAL_KB);

  const ok = status === "ok";
  const badge = ok
    ? `<span class="badge ok">命中 ±20%</span>`
    : `<span class="badge warn">尽力 (${status === "tooBig" ? "偏大" : "偏小"})</span>`;

  const rows = [];
  if (originalBytes) {
    rows.push(["原始大小", formatBytes(originalBytes)]);
    rows.push(["压缩比", `${(originalBytes / blob.size).toFixed(1)}×`]);
  }
  rows.push(["输出大小", `<strong>${formatBytes(blob.size)}</strong>`]);
  rows.push(["分辨率", `${width}×${height}`]);
  rows.push(["质量", `${Math.round(quality * 100)}%`]);
  rows.push(["状态", badge]);

  metaEl.innerHTML = rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("");
  cardEl.hidden = false;
  // 照片统一保存到 pics/, 文件名带时间戳避免覆盖
  const filename = `${baseName}_${kb}kb_${width}x${height}_${stamp()}.${ext}`;
  dlBtn.onclick = () => saveOutput("pics", filename, blob);
  if (uploadBtn) {
    uploadBtn.disabled = false;
    uploadBtn.onclick = () => uploadOutput("pics", filename, blob, uploadBtn);
  }
}

/* ============================================================
   摄像头拍照
   ============================================================ */
function initCamera() {
  const video = $("cam-video");
  const empty = $("cam-empty");
  const deviceSel = $("cam-device");
  const toggleBtn = $("cam-toggle");
  const shotBtn = $("cam-shot");

  const getSize = bindSegmented("cam-size", recompress);
  const getRes = bindSegmented("cam-res", recompress);
  const getFmt = bindSegmented("cam-fmt", recompress);

  const els = {
    imgEl: $("cam-out-img"),
    metaEl: $("cam-out-meta"),
    cardEl: $("cam-result"),
    dlBtn: $("cam-download"),
    uploadBtn: $("cam-upload"),
  };

  let stream = null;
  let lastShot = null; // 最近一次拍摄的 canvas, 供改设置后重新压缩

  async function listDevices() {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const cams = devices.filter((d) => d.kind === "videoinput");
      deviceSel.innerHTML = cams
        .map((c, i) => `<option value="${c.deviceId}">${c.label || "摄像头 " + (i + 1)}</option>`)
        .join("");
    } catch {
      /* ignore */
    }
  }

  async function start() {
    try {
      const deviceId = deviceSel.value;
      const constraints = {
        audio: false,
        video: deviceId
          ? { deviceId: { exact: deviceId } }
          : { width: { ideal: 1920 }, height: { ideal: 1080 } },
      };
      stream = await navigator.mediaDevices.getUserMedia(constraints);
      video.srcObject = stream;
      empty.style.display = "none";
      shotBtn.disabled = false;
      toggleBtn.textContent = "关闭摄像头";
      await listDevices(); // 授权后才能拿到设备名
    } catch (e) {
      toast("无法访问摄像头: " + (e.message || e.name));
    }
  }

  function stop() {
    if (stream) stream.getTracks().forEach((t) => t.stop());
    stream = null;
    video.srcObject = null;
    empty.style.display = "";
    shotBtn.disabled = true;
    toggleBtn.textContent = "开启摄像头";
  }

  toggleBtn.addEventListener("click", () => (stream ? stop() : start()));
  deviceSel.addEventListener("change", () => {
    if (stream) {
      stop();
      start();
    }
  });

  async function recompress() {
    if (!lastShot) return;
    const targetBytes = Number(getSize()) * DECIMAL_KB;
    const result = await compressToTarget(lastShot, {
      targetBytes,
      tolerance: 0.2,
      maxBytes: TRANSFER_LIMIT_BYTES,
      type: getFmt(),
      resolution: parseRes(getRes()),
    });
    renderImageResult(els, result, null, "photo");
  }

  shotBtn.addEventListener("click", async () => {
    if (!stream) return;
    const w = video.videoWidth;
    const h = video.videoHeight;
    if (!w || !h) return toast("画面尚未就绪");
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    canvas.getContext("2d").drawImage(video, 0, 0, w, h);
    lastShot = canvas;
    toast("已拍摄, 正在压缩…");
    await recompress();
  });

  // 进入页面时尝试列设备名(可能为空, 需授权后才完整)
  listDevices();
}

/* ============================================================
   图片文件压缩
   ============================================================ */
function initImageFile() {
  const drop = $("img-drop");
  const fileInput = $("img-file");
  const cameraFileInput = $("img-camera-file");
  const cameraPickBtn = $("img-camera-pick");
  const runBtn = $("img-run");

  const getSize = bindSegmented("img-size", recompress);
  const getRes = bindSegmented("img-res", recompress);
  const getFmt = bindSegmented("img-fmt", recompress);

  const els = {
    imgEl: $("img-out-img"),
    metaEl: $("img-out-meta"),
    cardEl: $("img-result"),
    dlBtn: $("img-download"),
    uploadBtn: $("img-upload"),
  };

  let bitmap = null;
  let originalBytes = 0;

  async function setFile(file) {
    if (!file || !file.type.startsWith("image/")) return toast("请选择图片文件");
    try {
      bitmap = await loadBitmap(file);
      originalBytes = file.size;
      runBtn.disabled = false;
      drop.querySelector("p").innerHTML = `<strong>${file.name}</strong>`;
      drop.querySelector("small").textContent = `${formatBytes(file.size)} · ${bitmap.width}×${bitmap.height}`;
    } catch (e) {
      toast("无法读取图片: " + (e.message || e));
    }
  }

  fileInput.addEventListener("change", (e) => setFile(e.target.files[0]));
  cameraFileInput.addEventListener("change", (e) => setFile(e.target.files[0]));
  cameraPickBtn.addEventListener("click", () => cameraFileInput.click());

  // 拖放
  ["dragenter", "dragover"].forEach((ev) =>
    drop.addEventListener(ev, (e) => {
      e.preventDefault();
      drop.classList.add("dragover");
    })
  );
  ["dragleave", "drop"].forEach((ev) =>
    drop.addEventListener(ev, (e) => {
      e.preventDefault();
      drop.classList.remove("dragover");
    })
  );
  drop.addEventListener("drop", (e) => setFile(e.dataTransfer.files[0]));

  async function recompress() {
    if (!bitmap) return;
    const targetBytes = Number(getSize()) * DECIMAL_KB;
    const result = await compressToTarget(bitmap, {
      targetBytes,
      tolerance: 0.2,
      maxBytes: TRANSFER_LIMIT_BYTES,
      type: getFmt(),
      resolution: parseRes(getRes()),
    });
    renderImageResult(els, result, originalBytes, "image");
  }

  runBtn.addEventListener("click", async () => {
    if (!bitmap) return;
    runBtn.disabled = true;
    runBtn.textContent = "压缩中…";
    await recompress();
    runBtn.disabled = false;
    runBtn.textContent = "开始压缩";
  });
}

/* ============================================================
   音频: 录音 + Codec2 声码器
   ============================================================ */
function initAudio() {
  const recBtn = $("aud-rec");
  const playSrcBtn = $("aud-play-src");
  const runBtn = $("aud-run");
  const timeEl = $("aud-time");
  const levelEl = $("aud-level");
  const recProgressEl = $("aud-rec-progress");
  const drop = $("aud-drop");
  const fileInput = $("aud-file");
  const statusEl = $("aud-status");
  const progress = $("aud-progress");
  const progressBar = progress.querySelector("span");
  const resultCard = $("aud-result");
  const metaEl = $("aud-out-meta");
  const playOutBtn = $("aud-play-out");
  const dlBtn = $("aud-download");
  const c2Drop = $("c2-drop");
  const c2FileInput = $("c2-file");
  const c2RunBtn = $("c2-run");
  const c2StatusEl = $("c2-status");
  const c2Progress = $("c2-progress");
  const c2ProgressBar = c2Progress.querySelector("span");
  const c2ResultCard = $("c2-result");
  const c2MetaEl = $("c2-out-meta");
  const c2PlayBtn = $("c2-play-out");
  const c2DownloadBtn = $("c2-download");

  const getMode = bindSegmented("aud-mode");

  const MAX_MS = 60_000;
  const MIN_MS = 300; // 过短的按压视为误触
  let mediaRecorder = null;
  let recStream = null;
  let audioCtx = null;
  let rafId = null;
  let startTime = 0;
  let chunks = [];
  let holding = false; // 是否仍按住
  let starting = false; // getUserMedia 进行中

  let source = null; // {blob, name, bytes} 待压缩的音频来源
  let resultBlob = null; // 压缩后的 .c2
  let resultName = "voice.c2";
  let c2Source = null; // {blob, name, bytes} 待转 MP3 的 Codec2 文件
  let mp3Blob = null;
  let mp3Name = "voice.mp3";
  let outAudio = new Audio();
  let srcAudio = new Audio();
  let mp3Audio = new Audio();

  function setSource(blob, name) {
    source = { blob, name, bytes: blob.size };
    runBtn.disabled = false;
    playSrcBtn.disabled = false;
    srcAudio.src = URL.createObjectURL(blob);
  }

  function baseName(name, fallback) {
    const cleaned = (name || fallback).replace(/\.[^.]+$/, "");
    return cleaned || fallback;
  }

  function isC2File(file) {
    return file && (/\.c2$/i.test(file.name || "") || file.type === "audio/codec2");
  }

  function setC2Source(file) {
    if (!file) return;
    if (!isC2File(file)) return toast("请选择 .c2 文件");
    c2Source = { blob: file, name: baseName(file.name, "codec2"), bytes: file.size };
    mp3Blob = null;
    c2ResultCard.hidden = true;
    c2RunBtn.disabled = false;
    c2StatusEl.textContent = "";
    c2Drop.querySelector("p").innerHTML = `<strong>${file.name || "codec2.c2"}</strong>`;
    c2Drop.querySelector("small").textContent = `${formatBytes(file.size)} · Codec2`;
  }

  /* ---- 录音 ---- */
  function pickMime() {
    const cands = ["audio/webm;codecs=opus", "audio/webm", "audio/ogg;codecs=opus", "audio/mp4"];
    return cands.find((m) => window.MediaRecorder && MediaRecorder.isTypeSupported(m)) || "";
  }

  async function startRec() {
    if (starting || (mediaRecorder && mediaRecorder.state === "recording")) return;
    starting = true;
    try {
      recStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (e) {
      starting = false;
      return toast("无法访问麦克风: " + (e.message || e.name));
    }
    starting = false;
    // 若用户在授权过程中已松手, 则立即收尾, 不开始录音
    if (!holding) {
      recStream.getTracks().forEach((t) => t.stop());
      recStream = null;
      return;
    }
    chunks = [];
    const mime = pickMime();
    mediaRecorder = new MediaRecorder(recStream, mime ? { mimeType: mime } : undefined);
    mediaRecorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
    mediaRecorder.onstop = () => {
      const elapsed = performance.now() - startTime;
      const blob = new Blob(chunks, { type: mediaRecorder.mimeType || "audio/webm" });
      cleanupRec();
      if (elapsed < MIN_MS || blob.size === 0) {
        toast("录音太短, 请按住按钮再说话");
        return;
      }
      setSource(blob, "recording");
      toast(`录音完成 ${fmtSeconds(Math.min(elapsed, MAX_MS) / 1000)}s (${formatBytes(blob.size)})`);
    };
    mediaRecorder.start();
    startTime = performance.now();
    recBtn.classList.add("recording");
    recBtn.textContent = "● 录音中…松开结束";

    // 电平表
    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    const srcNode = audioCtx.createMediaStreamSource(recStream);
    const analyser = audioCtx.createAnalyser();
    analyser.fftSize = 512;
    srcNode.connect(analyser);
    const buf = new Uint8Array(analyser.fftSize);

    const tick = () => {
      const elapsed = performance.now() - startTime;
      const ratio = Math.min(elapsed, MAX_MS) / MAX_MS;
      timeEl.textContent = fmtSeconds(Math.min(elapsed, MAX_MS) / 1000);
      recProgressEl.style.width = ratio * 100 + "%";
      analyser.getByteTimeDomainData(buf);
      let sum = 0;
      for (let i = 0; i < buf.length; i++) {
        const v = (buf[i] - 128) / 128;
        sum += v * v;
      }
      const rms = Math.sqrt(sum / buf.length);
      levelEl.style.width = Math.min(100, rms * 280) + "%";
      if (elapsed >= MAX_MS) return stopRec(); // 到 60s 自动停止
      rafId = requestAnimationFrame(tick);
    };
    tick();
  }

  function stopRec() {
    if (mediaRecorder && mediaRecorder.state !== "inactive") mediaRecorder.stop();
  }

  function cleanupRec() {
    if (rafId) cancelAnimationFrame(rafId);
    rafId = null;
    if (recStream) recStream.getTracks().forEach((t) => t.stop());
    recStream = null;
    if (audioCtx) audioCtx.close().catch(() => {});
    audioCtx = null;
    recBtn.classList.remove("recording");
    recBtn.textContent = "按住录音";
    levelEl.style.width = "0%";
    recProgressEl.style.width = "0%";
  }

  // 按住录音, 松开结束 (Pointer 事件统一鼠标 + 触屏)
  function onPressStart(e) {
    e.preventDefault();
    holding = true;
    startRec();
  }
  function onPressEnd() {
    if (!holding) return;
    holding = false;
    stopRec();
  }
  recBtn.addEventListener("pointerdown", onPressStart);
  recBtn.addEventListener("pointerup", onPressEnd);
  recBtn.addEventListener("pointercancel", onPressEnd);
  recBtn.addEventListener("pointerleave", onPressEnd);
  recBtn.addEventListener("contextmenu", (e) => e.preventDefault());

  playSrcBtn.addEventListener("click", () => {
    srcAudio.currentTime = 0;
    srcAudio.play();
  });

  /* ---- 文件选择 ---- */
  fileInput.addEventListener("change", (e) => {
    const f = e.target.files[0];
    if (!f) return;
    setSource(f, f.name.replace(/\.[^.]+$/, ""));
    drop.querySelector("p").innerHTML = `<strong>${f.name}</strong>`;
    drop.querySelector("small").textContent = formatBytes(f.size);
  });
  ["dragenter", "dragover"].forEach((ev) =>
    drop.addEventListener(ev, (e) => {
      e.preventDefault();
      drop.classList.add("dragover");
    })
  );
  ["dragleave", "drop"].forEach((ev) =>
    drop.addEventListener(ev, (e) => {
      e.preventDefault();
      drop.classList.remove("dragover");
    })
  );
  drop.addEventListener("drop", (e) => {
    const f = e.dataTransfer.files[0];
    if (f) {
      setSource(f, f.name.replace(/\.[^.]+$/, ""));
      drop.querySelector("p").innerHTML = `<strong>${f.name}</strong>`;
      drop.querySelector("small").textContent = formatBytes(f.size);
    }
  });

  /* ---- .c2 转 MP3 文件选择 ---- */
  c2FileInput.addEventListener("change", (e) => setC2Source(e.target.files[0]));
  ["dragenter", "dragover"].forEach((ev) =>
    c2Drop.addEventListener(ev, (e) => {
      e.preventDefault();
      c2Drop.classList.add("dragover");
    })
  );
  ["dragleave", "drop"].forEach((ev) =>
    c2Drop.addEventListener(ev, (e) => {
      e.preventDefault();
      c2Drop.classList.remove("dragover");
    })
  );
  c2Drop.addEventListener("drop", (e) => setC2Source(e.dataTransfer.files[0]));

  /* ---- 压缩 ---- */
  runBtn.addEventListener("click", async () => {
    if (!source) return;
    runBtn.disabled = true;
    runBtn.textContent = "处理中…";
    progress.hidden = false;
    progressBar.style.width = "5%";
    statusEl.textContent = "首次使用会从 CDN 加载声码器内核 (约 10MB), 请稍候…";
    try {
      const mode = getMode();
      resultBlob = await encodeToCodec2(source.blob, mode, (r) => {
        progressBar.style.width = Math.max(5, Math.round(r * 100)) + "%";
      });
      progressBar.style.width = "100%";
      resultName = `${source.name || "voice"}_codec2_${mode}_${stamp()}.c2`;

      const ratio = source.bytes / resultBlob.size;
      metaEl.innerHTML = [
        ["原始大小", formatBytes(source.bytes)],
        ["输出大小", `<strong>${formatBytes(resultBlob.size)}</strong>`],
        ["压缩比", `${ratio.toFixed(1)}×`],
        ["声码器", `Codec2 ${mode}`],
      ]
        .map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`)
        .join("");
      resultCard.hidden = false;
      statusEl.textContent = "完成 ✓";
    } catch (e) {
      statusEl.textContent = "失败: " + (e.message || e);
      toast("压缩失败");
    } finally {
      progress.hidden = true;
      progressBar.style.width = "0%";
      runBtn.disabled = false;
      runBtn.textContent = "压缩 / 转码";
    }
  });

  playOutBtn.addEventListener("click", async () => {
    if (!resultBlob) return;
    playOutBtn.disabled = true;
    playOutBtn.textContent = "解码中…";
    try {
      const wav = await decodeCodec2ToWav(resultBlob);
      outAudio.src = URL.createObjectURL(wav);
      await outAudio.play();
    } catch (e) {
      toast("解码失败: " + (e.message || e));
    } finally {
      playOutBtn.disabled = false;
      playOutBtn.textContent = "▶ 试听结果";
    }
  });

  dlBtn.addEventListener("click", () => resultBlob && saveOutput("voices", resultName, resultBlob));

  /* ---- .c2 转 MP3 ---- */
  c2RunBtn.addEventListener("click", async () => {
    if (!c2Source) return;
    c2RunBtn.disabled = true;
    c2RunBtn.textContent = "转码中…";
    c2Progress.hidden = false;
    c2ProgressBar.style.width = "5%";
    c2StatusEl.textContent = "首次使用会从 CDN 加载声码器内核 (约 10MB), 请稍候…";
    try {
      mp3Blob = await decodeCodec2ToMp3(c2Source.blob, (r) => {
        c2ProgressBar.style.width = Math.max(5, Math.round(r * 100)) + "%";
      });
      c2ProgressBar.style.width = "100%";
      mp3Name = `${c2Source.name || "voice"}_mp3_${stamp()}.mp3`;

      c2MetaEl.innerHTML = [
        ["原始 .c2", formatBytes(c2Source.bytes)],
        ["输出 MP3", `<strong>${formatBytes(mp3Blob.size)}</strong>`],
        ["体积变化", `${(mp3Blob.size / c2Source.bytes).toFixed(1)}×`],
        ["格式", "MP3 · 16 kHz · 单声道"],
      ]
        .map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`)
        .join("");
      c2ResultCard.hidden = false;
      c2StatusEl.textContent = "完成 ✓";
      toast("MP3 转码完成");
    } catch (e) {
      c2StatusEl.textContent = "失败: " + (e.message || e);
      toast("MP3 转码失败");
    } finally {
      c2Progress.hidden = true;
      c2ProgressBar.style.width = "0%";
      c2RunBtn.disabled = false;
      c2RunBtn.textContent = "转码成 MP3";
    }
  });

  c2PlayBtn.addEventListener("click", async () => {
    if (!mp3Blob) return;
    c2PlayBtn.disabled = true;
    c2PlayBtn.textContent = "载入中…";
    try {
      mp3Audio.src = URL.createObjectURL(mp3Blob);
      await mp3Audio.play();
    } catch (e) {
      toast("试听失败: " + (e.message || e));
    } finally {
      c2PlayBtn.disabled = false;
      c2PlayBtn.textContent = "▶ 试听 MP3";
    }
  });

  c2DownloadBtn.addEventListener("click", () => mp3Blob && saveOutput("voices", mp3Name, mp3Blob));

}

/* ============================================================
   启动
   ============================================================ */
initClock();
initTabs();
initStorage();
initCamera();
initImageFile();
initAudio();
