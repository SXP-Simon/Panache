"use strict";

// 2026-10-16：从矢量源生成站点图标，可选同步独立 Flutter 工作树。
const fs = require("node:fs/promises");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { crc32, deflateSync } = require("node:zlib");
const { createRequire } = require("node:module");
const root = path.resolve(__dirname, "..");
const { chromium } = createRequire(path.join(root, "e2e/package.json"))("@playwright/test");

async function main() {
  const svg = await fs.readFile(path.join(root, "frontend/src/assets/brand.svg"), "utf8");
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    async function png(size, square = false) {
      const source = square ? svg.replace('rx="60"', 'rx="0"') : svg;
      const result = await page.evaluate(async ({ source, size, square }) => {
        const img = new Image();
        img.src = `data:image/svg+xml;base64,${btoa(source)}`;
        await img.decode();
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = size;
        const context = canvas.getContext("2d", { alpha: !square });
        context.drawImage(img, 0, 0, size, size);
        // Apple 的商店图标要求文件无 alpha 通道，而不只是每个像素恰好不透明。
        if (!square) return canvas.toDataURL("image/png").split(",")[1];
        const pixels = context.getImageData(0, 0, size, size).data;
        const reader = new FileReader();
        const encoded = await new Promise((resolve, reject) => {
          reader.onload = () => resolve(reader.result.split(",")[1]);
          reader.onerror = () => reject(reader.error);
          reader.readAsDataURL(new Blob([pixels]));
        });
        return { pixels: encoded };
      }, { source, size, square });
      if (typeof result === "string") return Buffer.from(result, "base64");
      const pixels = Buffer.from(result.pixels, "base64");
      const chunk = (type, data) => {
        const name = Buffer.from(type);
        const output = Buffer.alloc(data.length + 12);
        output.writeUInt32BE(data.length);
        name.copy(output, 4);
        data.copy(output, 8);
        output.writeUInt32BE(crc32(Buffer.concat([name, data])), data.length + 8);
        return output;
      };
      const header = Buffer.alloc(13);
      header.writeUInt32BE(size);
      header.writeUInt32BE(size, 4);
      header[8] = 8;
      header[9] = 2;
      const rows = Buffer.alloc(size * (size * 3 + 1));
      for (let y = 0; y < size; y++) for (let x = 0; x < size; x++)
        for (let channel = 0; channel < 3; channel++)
          rows[y * (size * 3 + 1) + 1 + x * 3 + channel] = pixels[(y * size + x) * 4 + channel];
      return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]);
    }
    async function write(relative, bytes, targetRoot = root) {
      const target = path.join(targetRoot, relative);
      await fs.mkdir(path.dirname(target), { recursive: true });
      await fs.writeFile(target, bytes);
    }
    async function ico() {
      const sizes = [16, 24, 32, 48, 64, 128, 256];
      const images = await Promise.all(sizes.map((size) => png(size)));
      const header = Buffer.alloc(6 + 16 * images.length);
      header.writeUInt16LE(1, 2);
      header.writeUInt16LE(images.length, 4);
      let offset = header.length;
      images.forEach((image, index) => {
        const entry = 6 + index * 16;
        header[entry] = header[entry + 1] = sizes[index] % 256;
        header.writeUInt16LE(1, entry + 4);
        header.writeUInt16LE(32, entry + 6);
        header.writeUInt32LE(image.length, entry + 8);
        header.writeUInt32LE(offset, entry + 12);
        offset += image.length;
      });
      return Buffer.concat([header, ...images]);
    }
    for (const name of ["icon.svg", "favicon.svg"]) await write(`frontend/public/${name}`, svg);
    await write("docs/assets/images/icon.svg", svg);
    for (const [name, size] of [["favicon-96x96.png", 96], ["apple-touch-icon.png", 180], ["web-app-manifest-192x192.png", 192], ["web-app-manifest-512x512.png", 512]])
      await write(`frontend/public/${name}`, await png(size));
    await write("frontend/public/favicon.ico", await ico());
    const version = createHash("sha256").update(svg).digest("hex").slice(0, 12);
    for (const name of ["frontend/index.html", "frontend/public/manifest.json", "frontend/public/site.webmanifest"]) {
      const file = path.join(root, name);
      await fs.writeFile(file, (await fs.readFile(file, "utf8")).replace(/\?v=[0-9a-f]{12}/g, `?v=${version}`));
    }
    const flutterRoot = process.argv[2] && path.resolve(process.argv[2]);
    if (flutterRoot) {
      const save = (name, bytes) => write(name, bytes, flutterRoot);
      await save("app/assets/branding/panache.svg", svg);
      await save("app/assets/branding/panache.png", await png(512));
      await save("app/windows/runner/resources/app_icon.ico", await ico());
      await save("app/web/favicon.png", await png(48));
      for (const size of [192, 512]) {
        await save(`app/web/icons/Icon-${size}.png`, await png(size));
        await save(`app/web/icons/Icon-maskable-${size}.png`, await png(size, true));
      }
      for (const platform of ["ios", "macos"]) {
        const dir = `app/${platform}/Runner/Assets.xcassets/AppIcon.appiconset`;
        const contents = JSON.parse(await fs.readFile(path.join(flutterRoot, dir, "Contents.json"), "utf8"));
        for (const image of contents.images) {
          if (!image.filename) continue;
          const size = Math.round(Number.parseFloat(image.size) * Number.parseFloat(image.scale));
          await save(`${dir}/${image.filename}`, await png(size, platform === "ios"));
        }
      }
      for (const [density, size] of [["mdpi", 48], ["hdpi", 72], ["xhdpi", 96], ["xxhdpi", 144], ["xxxhdpi", 192]])
        await save(`app/android/app/src/main/res/mipmap-${density}/ic_launcher.png`, await png(size));
      const paths = [...svg.matchAll(/<path d="([^"]+)"/g)].map((match) => match[1]);
      const vector = (color) => `<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="256" android:viewportHeight="256"><group android:scaleX="0.72" android:scaleY="0.72" android:translateX="35.84" android:translateY="35.84"><path android:fillColor="${color}" android:fillType="evenOdd" android:pathData="${paths[0]} ${paths[2]}"/><path android:fillColor="${color}" android:pathData="${paths[1]}"/></group></vector>\n`;
      await save("app/android/app/src/main/res/drawable/ic_panache_foreground.xml", vector("#205C36"));
      await save("app/android/app/src/main/res/drawable/ic_panache_monochrome.xml", vector("#FFFFFFFF"));
      await save("app/android/app/src/main/res/values/panache_colors.xml", '<resources><color name="panache_icon_background">#C5F879</color></resources>\n');
      const adaptive = (monochrome) => `<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@color/panache_icon_background"/><foreground android:drawable="@drawable/ic_panache_foreground"/>${monochrome ? '<monochrome android:drawable="@drawable/ic_panache_monochrome"/>' : ""}</adaptive-icon>\n`;
      await save("app/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml", adaptive(false));
      await save("app/android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml", adaptive(true));
    }
    process.stdout.write(`Panache icons generated (${version})\n`);
  } finally {
    await browser.close();
  }
}
main().catch((error) => { process.stderr.write(`${error.stack}\n`); process.exitCode = 1; });
