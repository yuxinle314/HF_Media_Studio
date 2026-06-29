// 图像压缩引擎
// 思路: 在 Canvas 上把图像缩放到目标分辨率, 再对 JPEG/WebP 质量做二分搜索,
// 使输出字节数落在 [target*(1-tol), target*(1+tol)] 区间内.
// 若某分辨率即便最低质量仍超标 -> 自动降到更小的预设分辨率重试.

/** 预设分辨率, 从大到小排列 (自动模式按此顺序尝试) */
export const RES_PRESETS = [
  { w: 1920, h: 1080 },
  { w: 1024, h: 768 },
  { w: 960, h: 540 },
  { w: 480, h: 270 },
];

const QUALITY_MIN = 0.1; // 二分下界
const QUALITY_MAX = 0.95; // 二分上界
const SEARCH_ITERS = 8; // 二分迭代次数 (2^8 ≈ 0.4% 质量精度)

/** 从 File / Blob 读出 ImageBitmap (尊重 EXIF 方向) */
export async function loadBitmap(fileOrBlob) {
  try {
    return await createImageBitmap(fileOrBlob, { imageOrientation: "from-image" });
  } catch {
    // 个别浏览器不支持 imageOrientation 选项
    return await createImageBitmap(fileOrBlob);
  }
}

/** 在不放大的前提下, 计算 src 适配到 box 内的目标尺寸 (contain) */
function fitDims(srcW, srcH, boxW, boxH) {
  const scale = Math.min(boxW / srcW, boxH / srcH, 1); // <=1, 不放大
  return {
    w: Math.max(1, Math.round(srcW * scale)),
    h: Math.max(1, Math.round(srcH * scale)),
  };
}

/** 把 src 绘制到给定尺寸的 canvas */
function draw(src, w, h) {
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(src, 0, 0, w, h);
  return canvas;
}

/** canvas -> Blob (Promise 化) */
function encode(canvas, type, quality) {
  return new Promise((resolve) => canvas.toBlob(resolve, type, quality));
}

/**
 * 对单个 canvas 做质量二分, 返回最接近目标的结果.
 * @returns {{blob:Blob, quality:number, status:'ok'|'tooBig'|'tooSmall'}}
 */
async function searchQuality(canvas, type, target, tol) {
  const upper = target * (1 + tol);
  const lower = target * (1 - tol);

  // 边界探测: 最低质量仍超上限 -> 该分辨率太大
  const minBlob = await encode(canvas, type, QUALITY_MIN);
  if (minBlob.size > upper) {
    return { blob: minBlob, quality: QUALITY_MIN, status: "tooBig" };
  }
  // 最高质量仍低于下限 -> 该分辨率太小, 无法填满目标体积
  const maxBlob = await encode(canvas, type, QUALITY_MAX);
  if (maxBlob.size < lower) {
    return { blob: maxBlob, quality: QUALITY_MAX, status: "tooSmall" };
  }

  // 二分搜索, 追踪最接近 target 的结果
  let lo = QUALITY_MIN;
  let hi = QUALITY_MAX;
  let best = { blob: maxBlob, quality: QUALITY_MAX };
  let bestDist = Math.abs(maxBlob.size - target);

  for (let i = 0; i < SEARCH_ITERS; i++) {
    const mid = (lo + hi) / 2;
    const blob = await encode(canvas, type, mid);
    const dist = Math.abs(blob.size - target);
    if (dist < bestDist) {
      bestDist = dist;
      best = { blob, quality: mid };
    }
    if (blob.size > target) hi = mid;
    else lo = mid;
  }

  const ok = best.blob.size <= upper && best.blob.size >= lower;
  return { ...best, status: ok ? "ok" : best.blob.size > upper ? "tooBig" : "tooSmall" };
}

/**
 * 压缩到目标体积.
 * @param {ImageBitmap|HTMLCanvasElement|HTMLImageElement} src
 * @param {object} opts
 * @param {number} opts.targetBytes   目标字节
 * @param {number} [opts.tolerance]   抖动比例 (默认 0.2)
 * @param {string} [opts.type]        'image/jpeg' | 'image/webp'
 * @param {{w:number,h:number}|null} [opts.resolution]  指定分辨率盒; null=自动
 * @returns {Promise<{blob:Blob,width:number,height:number,quality:number,status:string}>}
 */
export async function compressToTarget(src, opts) {
  const { targetBytes, tolerance = 0.2, type = "image/jpeg", resolution = null } = opts;
  const srcW = src.width;
  const srcH = src.height;

  // 指定分辨率: 单次尽力压缩
  if (resolution) {
    const { w, h } = fitDims(srcW, srcH, resolution.w, resolution.h);
    const canvas = draw(src, w, h);
    const r = await searchQuality(canvas, type, targetBytes, tolerance);
    return { blob: r.blob, width: w, height: h, quality: r.quality, status: r.status };
  }

  // 自动: 从大到小尝试预设分辨率, 只在"超标"时降级
  let best = null; // 全局最接近 target 的结果
  let bestDist = Infinity;
  const seen = new Set();

  for (const preset of RES_PRESETS) {
    const { w, h } = fitDims(srcW, srcH, preset.w, preset.h);
    const key = `${w}x${h}`;
    if (seen.has(key)) continue; // 原图较小时多个预设会落到同一尺寸
    seen.add(key);

    const canvas = draw(src, w, h);
    const r = await searchQuality(canvas, type, targetBytes, tolerance);
    const dist = Math.abs(r.blob.size - targetBytes);
    if (dist < bestDist) {
      bestDist = dist;
      best = { blob: r.blob, width: w, height: h, quality: r.quality, status: r.status };
    }
    if (r.status === "ok") return best;
    // 太小: 再降分辨率只会更小, 停止
    if (r.status === "tooSmall") break;
    // 太大: 继续尝试更小分辨率
  }

  return best;
}
