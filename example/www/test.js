async function run() {
  const result = document.querySelector('#result');
  const native = async (method, data) => (await window.Capacitor.nativePromise('ThermalPrinter', method, data)).value;
  const params = new URLSearchParams(location.search);
  const address = params.get('host') || '100.84.156.107';
  const port = Number(params.get('port') || 19100);
  const reports = [];
  for (const receipt of await (await fetch('receipts.json')).json()) {
    const printer = { ...receipt.data, type: 'tcp', id: `receipt-${receipt.data.printerWidthMM}`, address, port };
    const lines = [];
    for (const image of receipt.images) {
      const blob = await (await fetch(`images/${image}`)).blob();
      const base64 = await new Promise(resolve => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.readAsDataURL(blob);
      });
      lines.push(`[C]<img>${await native('bitmapToHexadecimalString', { ...printer, base64 })}</img>`);
    }
    await native('printFormattedText', { ...printer, text: lines.join('\n') + '\n\n\n\n', dotsFeedPaper: 1 });
    await native('disconnectPrinter', printer);
    reports.push({ width: printer.printerWidthMM, strips: lines.length, printed: true });
  }
  const permissions = await native('requestBTPermissions', { type: 'bluetooth' });
  const paired = await native('listPrinters', { type: 'bluetooth' });
  reports.push({ bluetoothPermission: permissions.granted, pairedDevices: paired.length });
  result.textContent = JSON.stringify(reports, null, 2);
  console.log('THERMAL_CHECK ' + JSON.stringify(reports));
}
run().catch(error => {
  document.querySelector('#result').textContent = String(error);
  console.error('THERMAL_CHECK_FAILED ' + String(error));
});
