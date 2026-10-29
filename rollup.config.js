import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { cwd } from 'node:process';
import typescript from '@rollup/plugin-typescript';

const pkg = JSON.parse(readFileSync(join(cwd(), 'package.json'), 'utf8'));

export default [
  // ESM + CJS builds
  {
    input: 'guest-js/index.ts',
    output: [
      {
        file: pkg.exports.import,
        format: 'esm'
      },
      {
        file: pkg.exports.require,
        format: 'cjs'
      }
    ],
    plugins: [
      typescript({
        declaration: true,
        declarationDir: dirname(pkg.exports.import),
        rootDir: 'guest-js'
      })
    ],
    external: [
      /^@tauri-apps\/api/,
      ...Object.keys(pkg.dependencies || {}),
      ...Object.keys(pkg.peerDependencies || {})
    ]
  },
  // IIFE build embedded by Tauri
  {
    input: 'guest-js/index.ts',
    output: {
      file: 'api-iife.js',
      format: 'iife',
      name: '__TAURI_PLUGIN_PENCILKIT__',
      globals: {
        '@tauri-apps/api/core': 'window.__TAURI__.core'
      },
      banner: 'if ("__TAURI__" in window) {',
      footer: 'Object.defineProperty(window.__TAURI__, "pencilkit", { value: __TAURI_PLUGIN_PENCILKIT__ });\n}'
    },
    plugins: [
      typescript({
        declaration: false,
        declarationDir: undefined,
        rootDir: 'guest-js'
      })
    ],
    external: [
      '@tauri-apps/api/core'
    ]
  }
];
