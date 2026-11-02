import json
import os
import pathlib
import subprocess
import sys

version = sys.argv[1] if len(sys.argv) > 1 else ''
temp = pathlib.Path(os.environ['RUNNER_TEMP'])


def simctl(*args, timeout=600):
    return subprocess.run(['xcrun', 'simctl', *args], check=True, capture_output=True, text=True, timeout=timeout).stdout


def runtimes():
    found = [r for r in json.loads(simctl('list', 'runtimes', '-j'))['runtimes'] if r.get('isAvailable') and r.get('platform', 'iOS') == 'iOS' and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS')]
    if version:
        found = [r for r in found if r['version'] == version or r['version'].startswith(version + '.')]
    return sorted(found, key=lambda r: [int(p) for p in r['version'].split('.')])


subprocess.run(['xcodebuild', '-version'], check=True)
if not runtimes() and version:
    target = temp / ('runtime-' + version)
    target.mkdir(exist_ok=True)
    subprocess.run(['xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', version, '-exportPath', str(target)], check=True, timeout=2400)
    for image in target.rglob('*.dmg'):
        subprocess.run(['xcodebuild', '-importPlatform', str(image)], check=True, timeout=1200)
available = runtimes()
if not available:
    raise SystemExit('No iOS ' + (version or '') + ' simulator runtime is available')
runtime = available[-1]
print('Runtime', runtime['version'], runtime['identifier'], flush=True)
subprocess.run(['xcrun', 'simctl', 'runtime', 'dyld_shared_cache', 'update', runtime['identifier']], timeout=1800)
types = [t['identifier'] for t in runtime.get('supportedDeviceTypes', []) if t.get('productFamily') == 'iPhone']
if not types:
    raise SystemExit('Runtime ' + runtime['version'] + ' lists no iPhone device types')
udid = simctl('create', 'TP CI ' + runtime['version'], types[-1], runtime['identifier']).strip()
simctl('boot', udid)
simctl('bootstatus', udid, '-b', timeout=900)
print('Booted', udid, types[-1], flush=True)
with open(os.environ['GITHUB_ENV'], 'a') as env:
    env.write('IOS_SIMULATOR=' + udid + '\nIOS_RUNTIME=' + runtime['version'] + '\n')
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
    summary.write('Simulator: iOS ' + runtime['version'] + ', ' + types[-1].rsplit('.', 1)[-1] + '\n')
