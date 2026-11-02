import { createRequire } from 'node:module';
import test from 'node:test';
import assert from 'node:assert/strict';
const methods = ['listPrinters', 'printFormattedText', 'printFormattedTextAndCut', 'getEncoding', 'disconnectPrinter', 'requestPermissions', 'requestBTPermissions', 'requestUSBPermissions', 'bitmapToHexadecimalString', 'bytesToHexadecimalString'];
let response;
let failure;
let invocation;
globalThis.Capacitor = {
  getPlatform: () => 'android',
  PluginHeaders: [{ name: 'ThermalPrinter', methods: methods.map(name => ({ name, rtype: 'promise' })) }],
  nativePromise: async (plugin, method, data) => {
    invocation = { plugin, method, data };
    if (failure) throw failure;
    return { value: response };
  },
};
const { ThermalPrinter } = createRequire(import.meta.url)('../dist/plugin.cjs.js');
for (const method of methods) {
  test(`${method} preserves native payload and errors`, async () => {
    const data = { type: 'bluetooth', id: 'saved-name' };
    response = method === 'listPrinters' ? [{ address: 'AA', name: 'saved-name' }] : method.includes('Hexadecimal') ? '1D7630' : method.includes('Permissions') ? { granted: true } : undefined;
    assert.deepEqual(await ThermalPrinter[method](data), response);
    assert.deepEqual(invocation, { plugin: 'ThermalPrinter', method, data });
    failure = new Error('Disconnected');
    await assert.rejects(ThermalPrinter[method](data), /Disconnected/);
    failure = undefined;
  });
}

for (const payload of [
  { error: 'Device not enabled Bluetooth!' },
  { error: 'Device not found or not connected!', type: 'bluetooth', id: 'missing' },
  { granted: false },
]) {
  test(`preserves rejection fields ${JSON.stringify(payload)}`, async () => {
    failure = Object.assign(new Error(payload.error || 'USB permission denied'), { data: payload });
    await assert.rejects(ThermalPrinter.listPrinters({ type: 'bluetooth' }), error => {
      for (const [key, value] of Object.entries(payload)) assert.deepEqual(error[key], value);
      assert.ok(error.message);
      return true;
    });
    failure = undefined;
  });
}
