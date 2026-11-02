export interface Printer {
  address?: string;
  bondState?: number;
  name?: string;
  type?: number;
  features?: string[];
  deviceClass?: number;
  majorDeviceClass?: number;
  productName?: string;
  manufacturerName?: string;
  deviceId?: number;
  serialNumber?: string;
  vendorId?: number;
}

export interface PrinterToUse {
  type: 'bluetooth' | 'tcp' | 'usb';
  id: string | number;
  address?: string;
  port?: number;
  mmFeedPaper?: number;
  dotsFeedPaper?: number;
  printerDpi?: number;
  printerWidthMM?: number;
  printerNbrCharactersPerLine?: number;
  charsetEncoding?: { charsetName: string; charsetId: number };
}

export interface PrintFormattedText extends PrinterToUse { text: string }
export interface BitmapToHexadecimalString extends PrinterToUse { base64: string }
export interface BytesToHexadecimalString extends PrinterToUse { bytes: number[] }
export interface RequestPermissionsResult {
  granted: boolean;
  BLUETOOTH?: boolean;
  BLUETOOTH_ADMIN?: boolean;
  BLUETOOTH_CONNECT?: boolean;
  BLUETOOTH_SCAN?: boolean;
}
export interface GetEncodingResult { name: string; command: number[] }
export interface ErrorResult { error?: string }

export interface ThermalPrinterPlugin {
  listPrinters(data: { type: 'bluetooth' | 'usb' }): Promise<Printer[]>;
  printFormattedText(data: PrintFormattedText): Promise<void>;
  printFormattedTextAndCut(data: PrintFormattedText): Promise<void>;
  getEncoding(data: PrinterToUse): Promise<GetEncodingResult | 'null'>;
  disconnectPrinter(data: PrinterToUse): Promise<void>;
  requestPermissions(data: PrinterToUse): Promise<RequestPermissionsResult>;
  requestBTPermissions(data: { type: 'bluetooth' }): Promise<RequestPermissionsResult>;
  requestUSBPermissions(data: PrinterToUse): Promise<RequestPermissionsResult>;
  bitmapToHexadecimalString(data: BitmapToHexadecimalString): Promise<string>;
  bytesToHexadecimalString(data: BytesToHexadecimalString): Promise<string>;
}

export type ThermalPrinterNativePlugin = {
  [K in keyof ThermalPrinterPlugin]: (
    data: Parameters<ThermalPrinterPlugin[K]>[0]
  ) => Promise<{ value: Awaited<ReturnType<ThermalPrinterPlugin[K]>> }>;
};
