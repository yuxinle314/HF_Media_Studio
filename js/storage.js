// 输出文件保存模块
// 优先使用 File System Access API: 用户一次性授权一个父文件夹后,
// 照片写入 <父>/pics/, 音频写入 <父>/voices/, 之后无需再次选择.
// 句柄持久化到 IndexedDB, 刷新后仍记得 (再次写入时请求一次权限).
// 不支持该 API 的浏览器 (如 Firefox) 自动回退为普通下载.

const DB_NAME = "media-studio";
const STORE = "handles";
const KEY = "baseDir";

let baseDirHandle = null;

export function supported() {
  return typeof window !== "undefined" && "showDirectoryPicker" in window;
}

/* ---------------- IndexedDB 简易读写 ---------------- */
function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}
async function idbGet(key) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const r = db.transaction(STORE, "readonly").objectStore(STORE).get(key);
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
async function idbSet(key, val) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const r = db.transaction(STORE, "readwrite").objectStore(STORE).put(val, key);
    r.onsuccess = () => resolve();
    r.onerror = () => reject(r.error);
  });
}

/* ---------------- 权限 ---------------- */
async function ensurePermission(handle) {
  const opts = { mode: "readwrite" };
  if ((await handle.queryPermission(opts)) === "granted") return true;
  if ((await handle.requestPermission(opts)) === "granted") return true;
  return false;
}

/* ---------------- 公开 API ---------------- */

/** 启动时尝试恢复上次选择的文件夹 (仅恢复句柄, 权限留待写入时再请求) */
export async function restoreBaseDir() {
  if (!supported()) return null;
  try {
    const h = await idbGet(KEY);
    if (h) {
      baseDirHandle = h;
      return h.name;
    }
  } catch {
    /* ignore */
  }
  return null;
}

/** 当前已选父文件夹名称 (未选则 null) */
export function currentBaseName() {
  return baseDirHandle ? baseDirHandle.name : null;
}

/** 弹出文件夹选择器 (必须在用户手势内调用) */
export async function chooseBaseDir() {
  const h = await window.showDirectoryPicker({ id: "media-studio", mode: "readwrite" });
  if (!(await ensurePermission(h))) throw new Error("未授予文件夹写入权限");
  baseDirHandle = h;
  try {
    await idbSet(KEY, h);
  } catch {
    /* 持久化失败不影响本次使用 */
  }
  return h.name;
}

/** 把 blob 写入 <父>/<subdir>/<filename>, 返回展示用路径 */
async function writeInto(subdir, filename, blob) {
  const dir = await baseDirHandle.getDirectoryHandle(subdir, { create: true });
  const fh = await dir.getFileHandle(filename, { create: true });
  const w = await fh.createWritable();
  await w.write(blob);
  await w.close();
  return `${baseDirHandle.name}/${subdir}/${filename}`;
}

/**
 * 保存输出文件.
 * @param {string} subdir 'pics' | 'voices'
 * @param {string} filename
 * @param {Blob} blob
 * @param {()=>void} fallbackDownload 不支持/失败/取消时的普通下载
 * @returns {Promise<{method:'fs'|'download'|'cancel', path?:string}>}
 */
export async function save(subdir, filename, blob, fallbackDownload) {
  if (!supported()) {
    fallbackDownload();
    return { method: "download" };
  }
  try {
    // 没有可用文件夹时, 当场弹出选择器 (依赖按钮点击的用户手势)
    if (!baseDirHandle) {
      await chooseBaseDir();
    } else if (!(await ensurePermission(baseDirHandle))) {
      // 句柄存在但权限被拒, 重新选择
      await chooseBaseDir();
    }
    const path = await writeInto(subdir, filename, blob);
    return { method: "fs", path };
  } catch (e) {
    if (e && e.name === "AbortError") return { method: "cancel" }; // 用户取消选择
    // 其他错误回退下载
    fallbackDownload();
    return { method: "download" };
  }
}
