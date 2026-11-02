import { registerPlugin } from '@capacitor/core';
import type { ThermalPrinterNativePlugin, ThermalPrinterPlugin } from './definitions';

const native = registerPlugin<ThermalPrinterNativePlugin>('ThermalPrinter', {
  web: () => import('./web').then(m => new m.ThermalPrinterWeb()),
});

const unwrap = <T>(request: Promise<{ value: T }>): Promise<T> =>
  request.then(result => result.value).catch(error => {
    if (error && typeof error === 'object' && error.data && typeof error.data === 'object') {
      Object.assign(error, error.data);
    }
    throw error;
  });

export const ThermalPrinter: ThermalPrinterPlugin = {
  listPrinters: data => unwrap(native.listPrinters(data)),
  printFormattedText: data => unwrap(native.printFormattedText(data)),
  printFormattedTextAndCut: data => unwrap(native.printFormattedTextAndCut(data)),
  getEncoding: data => unwrap(native.getEncoding(data)),
  disconnectPrinter: data => unwrap(native.disconnectPrinter(data)),
  requestPermissions: data => unwrap(native.requestPermissions(data)),
  requestBTPermissions: data => unwrap(native.requestBTPermissions(data)),
  requestUSBPermissions: data => unwrap(native.requestUSBPermissions(data)),
  bitmapToHexadecimalString: data => unwrap(native.bitmapToHexadecimalString(data)),
  bytesToHexadecimalString: data => unwrap(native.bytesToHexadecimalString(data)),
};

export * from './definitions';
