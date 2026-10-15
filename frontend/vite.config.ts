import { fileURLToPath, URL } from 'node:url';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    {
      name: 'retire-legacy-service-workers',
      generateBundle(_options, bundle) {
        const publicPaths = [
          'manifest.json',
          'site.webmanifest',
          'icon.svg',
          'favicon.svg',
          'favicon.ico',
          'favicon-96x96.png',
          'apple-touch-icon.png',
          'web-app-manifest-192x192.png',
          'web-app-manifest-512x512.png',
          ...readdirSync(fileURLToPath(new URL('./public/fonts/lxgw-wenkai', import.meta.url)))
            .filter((name) => /\.(?:woff2|css|txt|md)$/.test(name))
            .map((name) => `fonts/lxgw-wenkai/${name}`),
        ];
        const brandVersion = createHash('sha256')
          .update(readFileSync(new URL('./src/assets/brand.svg', import.meta.url)))
          .digest('hex')
          .slice(0, 12);
        const versionUrls = publicPaths
          .filter((name) => /\.(?:png|svg|ico)$/.test(name))
          .map((name) => `${name}?v=${brandVersion}`);
        const shellPaths = [
          'index.html',
          ...publicPaths,
          ...versionUrls,
          ...Object.keys(bundle).filter((name) => name.startsWith('assets/')),
        ];
        const contentHash = createHash('sha256').update(JSON.stringify(shellPaths));
        for (const name of publicPaths)
          contentHash.update(readFileSync(new URL(`./public/${name}`, import.meta.url)));
        const version = contentHash.digest('hex').slice(0, 20);
        for (const output of Object.values(bundle)) {
          if (output.type === 'chunk' && output.name === 'service-worker')
            this.emitFile({ type: 'asset', fileName: 'sw.js', source: output.code });
          if (output.type === 'chunk' && output.name === 'studio-worker')
            output.code = output.code
              .replaceAll('__STUDIO_PRECACHE_PATHS__', JSON.stringify(shellPaths))
              .replaceAll('__STUDIO_CACHE_VERSION__', JSON.stringify(version));
        }
      },
    },
  ],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  server: {
    port: 8080,
    strictPort: true,
    proxy: { '/api': { target: 'http://127.0.0.1:5005', changeOrigin: true, ws: true } },
  },
  build: {
    target: 'es2022',
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      input: {
        index: fileURLToPath(new URL('./index.html', import.meta.url)),
        'service-worker': fileURLToPath(new URL('./worker/service-worker.ts', import.meta.url)),
        'studio-worker': fileURLToPath(new URL('./worker/studio-worker.ts', import.meta.url)),
      },
      output: {
        entryFileNames: (chunk) =>
          ['service-worker', 'studio-worker'].includes(chunk.name)
            ? `${chunk.name}.js`
            : 'assets/[name]-[hash].js',
      },
    },
  },
});
