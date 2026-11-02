export default {
  input: 'dist/esm/index.js',
  output: [
    { file: 'dist/plugin.js', format: 'iife', inlineDynamicImports: true, name: 'capacitorThermalPrinter', globals: { '@capacitor/core': 'capacitorExports' } },
    { file: 'dist/plugin.cjs.js', format: 'cjs', inlineDynamicImports: true },
  ],
  external: ['@capacitor/core'],
};
