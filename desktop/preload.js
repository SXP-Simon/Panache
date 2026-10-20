// 渲染进程与主进程之间唯一的桥。contextIsolation 开着，站点页面拿不到任何 Node/Electron
// API，只能调这里明确暴露的下载方法和固定键/资源 ID 存储方法：
//   onDownloadFinished(cb) —— 主进程把「下载完成，文件在这个绝对路径」推给页面
//   revealLastDownload()   —— 让系统文件管理器打开最后那次下载（路径由主进程记着，
//                             不从页面传路径过来，免得给 shell 开了个任意路径的入口）
const { contextBridge, ipcRenderer } = require("electron");
const closeHandlers = new Set();
let closeUiState = null;

ipcRenderer.on("storage:flush-request", async (event, id, reason) => {
  if (typeof id !== "string" || !/^[a-f0-9-]{36}$/.test(id)) return;
  if (!closeUiState && document.documentElement) {
    closeUiState = {
      element: document.documentElement,
      inert: document.documentElement.inert,
      focus: document.activeElement,
    };
    document.documentElement.inert = true;
  }
  try {
    await Promise.all([...closeHandlers].map((callback) => callback(reason === "update" ? "update" : "close")));
    ipcRenderer.send("storage:flush-complete", id, true);
  } catch (error) {
    ipcRenderer.send("storage:flush-complete", id, false, error?.message === "generationBusy" ? "generationBusy" : "saveFailed");
  }
});
ipcRenderer.on("storage:close-cancelled", () => {
  if (!closeUiState) return;
  closeUiState.element.inert = closeUiState.inert;
  if (closeUiState.focus instanceof HTMLElement && closeUiState.focus.isConnected) {
    closeUiState.focus.focus();
  }
  closeUiState = null;
});

contextBridge.exposeInMainWorld("handwritingDesktop", {
  onDownloadFinished: (callback) => {
    if (typeof callback !== "function") throw new TypeError("Invalid download listener");
    const listener = (event, payload) => {
      if (payload && typeof payload.file === "string" && typeof payload.state === "string") {
        callback({ file: payload.file, state: payload.state });
      }
    };
    ipcRenderer.on("download:finished", listener);
    return () => {
      ipcRenderer.removeListener("download:finished", listener);
    };
  },
  revealLastDownload: () => ipcRenderer.send("download:reveal"),
  onBeforeClose: (callback) => {
    if (typeof callback !== "function") throw new TypeError("Invalid close listener");
    closeHandlers.add(callback);
    return () => { closeHandlers.delete(callback); };
  },
  updates: {
    state: () => ipcRenderer.invoke("updates:state"),
    check: () => ipcRenderer.invoke("updates:check"),
    download: () => ipcRenderer.invoke("updates:download"),
    cancel: () => ipcRenderer.invoke("updates:cancel"),
    open: () => ipcRenderer.invoke("updates:open"),
    manual: () => ipcRenderer.invoke("updates:manual"),
    healthy: () => ipcRenderer.invoke("updates:healthy"),
    subscribe: (callback) => {
      if (typeof callback !== "function") throw new TypeError("Invalid update listener");
      const listener = (_event, state) => callback(state);
      ipcRenderer.on("updates:state", listener);
      return () => ipcRenderer.removeListener("updates:state", listener);
    },
  },
  storage: {
    readRecord: (key) => ipcRenderer.invoke("storage:read-record", key),
    writeRecord: (key, value) => ipcRenderer.invoke("storage:write-record", key, value),
    removeRecord: (key) => ipcRenderer.invoke("storage:remove-record", key),
    readAsset: (id) => ipcRenderer.invoke("storage:read-asset", id),
    writeAsset: (id, bytes, mimeType) =>
      ipcRenderer.invoke("storage:write-asset", id, bytes, mimeType),
    removeAsset: (id) => ipcRenderer.invoke("storage:remove-asset", id),
  },
});
