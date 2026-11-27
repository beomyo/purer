import { defineConfig } from 'vite'
import monkey from 'vite-plugin-monkey'

export default defineConfig({
  define: {
    // @cbingbing/demuxer 的部分依赖会引用 global
    global: 'globalThis',
  },
  build: {
    minify: true,
  },
  plugins: [
    monkey({
      entry: 'src/main.ts',
      userscript: {
        name: '115 缩略图/雪碧图生成器',
        namespace: '115-thumbnail-scraper',
        version: '1.6.0',
        description: '在 115 网页里用 WebCodecs 批量生成 Purer 兼容的缩略图和雪碧图，直接写入 WebDAV 缓存',
        author: '115-thumbnail-scraper',
        match: ['https://115.com/*'],
        grant: [
          'GM_xmlhttpRequest',
          'GM_getValue',
          'GM_setValue',
          'GM_registerMenuCommand',
          'GM_addStyle',
        ],
        connect: ['*'],
        'run-at': 'document-idle',
      },
      build: {
        fileName: '115-thumbnail-scraper.user.js',
      },
    }),
  ],
})
