import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = process.cwd();
const manager = process.argv[2];
if (!['SPM', 'CocoaPods'].includes(manager)) throw new Error(`Unknown package manager ${manager}`);
const consumer = join(process.env.RUNNER_TEMP, 'ios-consumer');
const run = (command, args, cwd = consumer) => execFileSync(command, args, { cwd, stdio: 'inherit' });
const read = file => readFileSync(join(consumer, file), 'utf8');
const packed = JSON.parse(execFileSync('npm', ['pack', '--json', '--pack-destination', process.env.RUNNER_TEMP], { cwd: root, encoding: 'utf8' }));
const capacitor = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).devDependencies['@capacitor/ios'];
rmSync(consumer, { recursive: true, force: true });
mkdirSync(consumer, { recursive: true });
writeFileSync(join(consumer, 'package.json'), JSON.stringify({
  name: 'ios-tarball-consumer',
  version: '1.0.0',
  private: true,
  dependencies: {
    '@bricks-soft/capacitor-thermal-printer': `file:${resolve(process.env.RUNNER_TEMP, packed[0].filename)}`,
    '@capacitor/core': capacitor,
    '@capacitor/ios': capacitor,
    '@capacitor/cli': capacitor,
  },
}));
cpSync(join(root, 'example/www'), join(consumer, 'www'), { recursive: true });
writeFileSync(join(consumer, 'www/test.js'), read('www/test.js').replace("'100.84.156.107'", "'127.0.0.1'"));
cpSync(join(root, 'example/capacitor.config.json'), join(consumer, 'capacitor.config.json'));
run('npm', ['install', '--no-audit', '--no-fund']);
run('npx', ['cap', 'add', 'ios', ...(manager === 'CocoaPods' ? ['--packagemanager', 'CocoaPods'] : [])]);
run('npx', ['cap', 'sync', 'ios']);
run('plutil', ['-replace', 'NSBluetoothAlwaysUsageDescription', '-string', 'Connect to receipt printers', 'ios/App/App/Info.plist']);
const classes = JSON.parse(read('ios/App/App/capacitor.config.json')).packageClassList ?? [];
if (!classes.includes('ThermalPrinterPlugin')) throw new Error(`ThermalPrinterPlugin is not registered: ${classes}`);
if (manager === 'SPM' && !read('ios/App/CapApp-SPM/Package.swift').includes('BricksSoftCapacitorThermalPrinter')) throw new Error('CapApp-SPM does not depend on the plugin');
if (manager === 'CocoaPods' && !read('ios/App/Podfile.lock').includes('BricksSoftCapacitorThermalPrinter')) throw new Error('Podfile.lock does not contain the plugin');
console.log(`${manager} consumer ready with ${classes.join(', ')}`);
