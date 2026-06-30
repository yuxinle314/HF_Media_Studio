// 通用工具函数

/** 人类可读的字节数 */
export function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb.toFixed(kb < 10 ? 1 : 0)} KB`;
  return `${(kb / 1024).toFixed(2)} MB`;
}

/** 触发浏览器下载一个 Blob */
export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  // 稍后释放, 避免下载尚未开始就被回收
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}

/** 简易顶层 toast 提示 */
let toastTimer = null;
export function toast(msg) {
  const el = document.getElementById("toast");
  if (!el) return;
  el.textContent = msg;
  el.hidden = false;
  // 强制 reflow 后再加 class, 保证过渡动画生效
  void el.offsetWidth;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    el.classList.remove("show");
    setTimeout(() => (el.hidden = true), 320);
  }, 2600);
}

/**
 * 把一组分段控件 (.segmented[data-group]) 变成单选, 返回一个读取当前值的函数.
 * @param {string} group data-group 名称
 * @param {(val:string)=>void} [onChange]
 */
export function bindSegmented(group, onChange) {
  const root = document.querySelector(`.segmented[data-group="${group}"]`);
  if (!root) return () => null;
  root.addEventListener("click", (e) => {
    const btn = e.target.closest(".seg-item");
    if (!btn || !root.contains(btn)) return;
    root.querySelectorAll(".seg-item").forEach((b) => b.classList.remove("is-active"));
    btn.classList.add("is-active");
    onChange && onChange(btn.dataset.val);
  });
  return () => root.querySelector(".seg-item.is-active")?.dataset.val ?? null;
}

/** 把 mm:ss.s 之类的秒数格式化为 1 位小数 */
export function fmtSeconds(s) {
  return s.toFixed(1);
}

/** 生成文件名用的时间戳 MMDD-HHMMSS, 避免同名覆盖 */
export function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}
