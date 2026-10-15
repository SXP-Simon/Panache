const fs = require("fs");
const path = require("path");
const { randomUUID } = require("crypto");

function setupPersistence({ ipcMain, getWindow, getAllowedOrigin, dataDir }) {
  const STORAGE_RECORDS = new Set([
    "studio.workspace",
    "studio.draft", "studio.settings", "studio.preset", "studio.assets",
    "studio.generation", "studio.locale", "studio.theme", "markdownTableMode", "studio.legacy",
  ]);
  const MAX_RECORD_BYTES = 8 * 1024 * 1024;
  const MAX_ASSET_BYTES = 32 * 1024 * 1024;
  const MAX_STORAGE_CALLS = 8;
  const MAX_STORAGE_BYTES = 65 * 1024 * 1024;
  let storageCalls = 0;
  let storageBytes = 0;
  const storageWrites = new Map();
  const accepted = new Set();
  let drainPending = null;

  // 2026-10-15：桥只接受当前主窗口的主 frame 与本次握手确定的精确同源地址。
  function trustedRenderer(event) {
    const mainWindow = getWindow();
    const allowedStorageOrigin = getAllowedOrigin();
    if (!mainWindow || mainWindow.isDestroyed() || !allowedStorageOrigin) return false;
    const contents = mainWindow.webContents;
    if (event.sender !== contents || event.senderFrame !== contents.mainFrame) return false;
    try {
      return new URL(event.senderFrame.url).origin === allowedStorageOrigin &&
        new URL(contents.getURL()).origin === allowedStorageOrigin;
    } catch {
      return false;
    }
  }

  function recordPath(key) {
    if (typeof key !== "string" || !STORAGE_RECORDS.has(key)) {
      throw new Error("Invalid storage record");
    }
    return path.join(dataDir(), "studio", "records", `${key}.json`);
  }

  function assetPath(id) {
    if (typeof id !== "string" || !/^[a-z0-9][a-z0-9_-]{0,95}$/.test(id) ||
        /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/.test(id)) {
      throw new Error("Invalid storage asset ID");
    }
    return path.join(dataDir(), "studio", "assets", `${id}.bin`);
  }

  function validateMimeType(type) {
    if (typeof type !== "string" || type.length > 128 ||
        (type && !/^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*$/i.test(type))) {
      throw new Error("Invalid asset MIME type");
    }
  }

  async function readStorageFile(file, limit) {
    // 2026-10-15：使用同一文件句柄先测长再读取，避免超大文件进入 IPC。
    let handle;
    try {
      handle = await fs.promises.open(file, "r");
      const stat = await handle.stat();
      if (!stat.isFile() || stat.size > limit) throw new Error("Stored data exceeds size limit");
      const buffer = await handle.readFile();
      if (buffer.length > limit) throw new Error("Stored data exceeds size limit");
      return buffer;
    } catch (error) {
      if (error.code === "ENOENT") return null;
      throw error;
    } finally {
      await handle?.close();
    }
  }

  async function atomicWrite(file, buffer) {
    await fs.promises.mkdir(path.dirname(file), { recursive: true });
    const temporary = `${file}.${randomUUID()}.tmp`;
    let handle;
    try {
      handle = await fs.promises.open(temporary, "wx", 0o600);
      await handle.writeFile(buffer);
      await handle.sync();
      await handle.close();
      handle = undefined;
      await fs.promises.rename(temporary, file);
    } finally {
      await handle?.close();
      await fs.promises.rm(temporary, { force: true });
    }
  }

  // 2026-10-15：同一键的写/删串行，原子替换不会留下半个 JSON 或错配资源头。
  function mutateStorageFile(file, operation) {
    const previous = storageWrites.get(file) || Promise.resolve();
    const current = previous.catch(() => {}).then(operation);
    storageWrites.set(file, current);
    return current.finally(() => {
      if (storageWrites.get(file) === current) storageWrites.delete(file);
    });
  }

  function registerHandlers() {
    const operations = {
      "storage:read-record": async (key) => {
        const file = recordPath(key);
        await storageWrites.get(file);
        const data = await readStorageFile(file, MAX_RECORD_BYTES);
        return data === null ? null : data.toString("utf8");
      },
      "storage:write-record": async (key, value) => {
        const file = recordPath(key);
        if (typeof value !== "string" || Buffer.byteLength(value, "utf8") > MAX_RECORD_BYTES) {
          throw new Error("Storage record exceeds 8 MiB or has an invalid type");
        }
        await mutateStorageFile(file, () => atomicWrite(file, Buffer.from(value, "utf8")));
      },
      "storage:remove-record": async (key) => {
        const file = recordPath(key);
        await mutateStorageFile(file, () => fs.promises.rm(file, { force: true }));
      },
      "storage:read-asset": async (id) => {
        const file = assetPath(id);
        await storageWrites.get(file);
        const data = await readStorageFile(file, MAX_ASSET_BYTES + 129);
        if (data === null) return null;
        const separator = data.indexOf(10);
        if (separator < 0 || separator > 128) throw new Error("Invalid stored asset header");
        const mimeType = data.subarray(0, separator).toString("ascii");
        validateMimeType(mimeType);
        const bytes = data.subarray(separator + 1);
        if (bytes.length > MAX_ASSET_BYTES) throw new Error("Stored asset exceeds 32 MiB");
        return { mimeType, bytes: new Uint8Array(bytes) };
      },
      "storage:write-asset": async (id, bytes, mimeType) => {
        const file = assetPath(id);
        validateMimeType(mimeType);
        if (!(bytes instanceof ArrayBuffer) || bytes.byteLength > MAX_ASSET_BYTES) {
          throw new Error("Storage asset exceeds 32 MiB or has an invalid type");
        }
        const header = Buffer.from(`${mimeType}\n`, "ascii");
        const data = Buffer.concat([header, Buffer.from(bytes)]);
        await mutateStorageFile(file, () => atomicWrite(file, data));
      },
      "storage:remove-asset": async (id) => {
        const file = assetPath(id);
        await mutateStorageFile(file, () => fs.promises.rm(file, { force: true }));
      },
    };
    for (const [channel, operation] of Object.entries(operations)) {
      ipcMain.handle(channel, async (event, ...args) => {
        if (!trustedRenderer(event)) throw new Error("Storage access denied");
        const expectedArguments = channel === "storage:write-asset" ? 3 :
          channel === "storage:write-record" ? 2 : 1;
        if (args.length !== expectedArguments) throw new Error("Invalid storage arguments");
        const reservedBytes = channel === "storage:read-asset" ? MAX_ASSET_BYTES + 129 :
          channel === "storage:read-record" ? MAX_RECORD_BYTES :
            args.reduce((total, value) => total + (typeof value === "string" ?
              Buffer.byteLength(value, "utf8") : value instanceof ArrayBuffer ? value.byteLength : 0), 0);
        if (storageCalls >= MAX_STORAGE_CALLS) throw new Error("Too many storage operations");
        if (reservedBytes + storageBytes > MAX_STORAGE_BYTES) {
          throw new Error("Storage operations exceed the memory limit");
        }
        storageCalls += 1;
        storageBytes += reservedBytes;
        const pending = Promise.resolve().then(() => operation(...args));
        accepted.add(pending);
        try {
          return await pending;
        } finally {
          accepted.delete(pending);
          storageCalls -= 1;
          storageBytes -= reservedBytes;
        }
      });
    }
  }

  // 2026-10-15：等待已接收 IPC 与同键排队写；失败也须结清，不阻断其后的有效写。
  function drain() {
    if (drainPending) return drainPending;
    drainPending = (async () => {
      while (accepted.size || storageWrites.size) {
        await Promise.allSettled([...accepted, ...storageWrites.values()]);
      }
    })().finally(() => { drainPending = null; });
    return drainPending;
  }

  registerHandlers();
  return { drain, trustedRenderer };
}

module.exports = { setupPersistence };
