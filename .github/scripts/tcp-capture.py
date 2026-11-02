import hashlib
import json
import pathlib
import socket
import sys

fixtures, out, timeout = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), float(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
expected = [c for c in json.loads(fixtures.read_text()) if c['action'] == 'receipt']
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', 19100))
server.listen(2)
server.settimeout(timeout)
(out / 'listening').write_text('')
failed = False
for case in expected:
    client, _ = server.accept()
    client.settimeout(60)
    data = b''
    while True:
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
    client.close()
    width = case['data']['printerWidthMM']
    (out / f'ios-{width}mm.bin').write_bytes(data)
    match = data.hex() == case['expected']['bytes'].lower()
    failed = failed or not match
    print(json.dumps({'width': width, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'goldenMatch': match}), flush=True)
server.close()
if failed:
    raise SystemExit('Captured bytes differ from the Android golden receipts')
