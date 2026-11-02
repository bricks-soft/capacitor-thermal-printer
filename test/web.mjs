import { createRequire } from 'node:module';
import test from 'node:test';
import assert from 'node:assert/strict';
const { ThermalPrinter } = createRequire(import.meta.url)('../dist/plugin.cjs.js');
for (const method of Object.keys(ThermalPrinter)) {
  test(`web ${method} rejects as unavailable`, async () => {
    await assert.rejects(ThermalPrinter[method]({ type: 'bluetooth' }), error => error.code === 'UNAVAILABLE');
  });
}
