import { WebPlugin } from '@capacitor/core';

export class ThermalPrinterWeb extends WebPlugin {
  async listPrinters(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
  async printFormattedText(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
  async printFormattedTextAndCut(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
  async getEncoding(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
  async disconnectPrinter(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
  async requestPermissions(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
  async requestBTPermissions(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
  async requestUSBPermissions(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
  async bitmapToHexadecimalString(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
  async bytesToHexadecimalString(): Promise<never> {
    throw this.unavailable('Thermal printing is unavailable on the web.');
  }
}
