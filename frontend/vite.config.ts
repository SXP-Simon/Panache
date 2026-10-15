import { fileURLToPath, URL } from 'node:url';
import { createHash } from 'node:crypto';
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
        const shellPaths = [
          'index.html',
          'manifest.json',
          'icon.svg',
          'web-app-manifest-192x192.png',
          'web-app-manifest-512x512.png',
          ...Object.keys(bundle).filter((name) => name.startsWith('assets/')),
        ];
        const version = createHash('sha256')
          .update(JSON.stringify(shellPaths))
          .digest('hex')
          .slice(0, 20);
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
