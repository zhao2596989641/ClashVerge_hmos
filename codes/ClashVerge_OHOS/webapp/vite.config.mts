import path from 'node:path'

import legacy from '@vitejs/plugin-legacy'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import svgr from 'vite-plugin-svgr'

export default defineConfig({
  root: 'src',
  // 鸿蒙侧以 http://127.0.0.1:PORT/ 提供产物，使用相对路径避免绝对根路径
  base: './',
  server: { port: 3000 },
  plugins: [
    svgr(),
    react(),
    legacy({
      modernTargets: ['edge>=109', 'safari>=14'],
      renderLegacyChunks: false,
      // Auto-detected from the emitted bundle, dependencies included,
      // so post-Safari-14 APIs never depend on extending a manual list.
      modernPolyfills: true,
      additionalModernPolyfills: [
        path.resolve('./src/polyfills/matchMedia.js'),
        path.resolve('./src/polyfills/WeakRef.js'),
        path.resolve('./src/polyfills/RegExp.js'),
      ],
    }),
  ],
  // lightningcss 没有 openharmony-arm64 原生绑定，鸿蒙侧统一走 postcss + 不压缩 CSS
  css: { transformer: 'postcss' },
  build: {
    outDir: '../dist',
    emptyOutDir: true,
    chunkSizeWarningLimit: 4000,
    cssMinify: false,
  },
  resolve: {
    alias: {
      '@': path.resolve('./src'),
      '@root': path.resolve('.'),
      // 上游用 github: 依赖，鸿蒙侧改为本地 vendor 的 TS 源码（免 git 拉取，逻辑不变）
      'tauri-plugin-mihomo-api': path.resolve('./vendor/tauri-plugin-mihomo-api/index.ts'),
      'monaco-editor/esm/vs/editor/editor.worker.js':
        'monaco-editor/editor/editor.worker',
    },
  },
  define: {
    // 鸿蒙内核为 Linux，前端平台分支按 linux 走最贴近（Windows/macOS 专有分支本来就要隐藏）
    OS_PLATFORM: `"linux"`,
    IS_OHOS: `"true"`,
  },
})
