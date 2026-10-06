"""Windows controls execute real rustup with official bytes and isolated fault injection."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import urllib.error
import urllib.request

from acquire_package_rust import acquire


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--receipt-dir', required=True)
    args = parser.parse_args()
    out = Path(args.receipt_dir)
    out.mkdir(parents=True, exist_ok=True)
    if os.name != 'nt':
        raise ValueError('Real native Windows rustup control required')
    work = Path(os.environ['RUNNER_TEMP'])/'rust-acquisition-control-work'
    work.mkdir(exist_ok=True)
    cache = work/'official-cache'
    cache.mkdir(exist_ok=True)
    state = {'mode': '', 'requests': [], 'manifestFailures': 0, 'receipt': None}
    request_lock = threading.Lock()
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            path = self.path
            status = 200
            body = b''
            is_manifest = path.endswith('channel-rust-nightly.toml')
            if state['mode'] == 'not-found':
                status = 404
            elif is_manifest and (state['mode'] in ('raw-persistent', 'persistent') or
                                 state['mode'] == 'recover' and state['manifestFailures'] == 0):
                status = 503
                state['manifestFailures'] += 1
            elif state['mode'] == 'component-persistent' and '/cargo-nightly-' in path:
                status = 503
            else:
                target = cache/hashlib.sha256(path.encode()).hexdigest()
                if not target.is_file():
                    try:
                        with urllib.request.urlopen('https://static.rust-lang.org'+path, timeout=180) as response:
                            body = response.read()
                        target.write_bytes(body)
                    except urllib.error.HTTPError as error:
                        status = error.code
                else:
                    body = target.read_bytes()
            with request_lock:
                state['requests'].append({'path': path, 'status': status,
                                          'userAgent': self.headers.get('User-Agent'),
                                          'servedBytesSha256': hashlib.sha256(body).hexdigest() if status == 200 else None})
                (state['receipt']/'http-requests.json').write_text(json.dumps(state['requests'], indent=2)+'\n')
            self.send_response(status)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    results = []
    try:
        for mode in ('raw-persistent', 'first-success', 'recover', 'persistent', 'not-found', 'component-persistent'):
            state.update(mode=mode, requests=[], manifestFailures=0)
            environment = dict(os.environ)
            environment.update(RUSTUP_HOME=str(work/('home-'+mode)), RUSTUP_MAX_RETRIES='10',
                               RUST_TOOLCHAIN='nightly-2026-07-14', RUSTUP_TOOLCHAIN='nightly-2026-07-14',
                               RUSTUP_DIST_SERVER=f'http://127.0.0.1:{server.server_port}',
                               RUSTUP_AUTO_INSTALL='0', NO_PROXY='127.0.0.1,localhost')
            receipt = out/mode
            receipt.mkdir(exist_ok=True)
            state['receipt'] = receipt
            if mode == 'raw-persistent':
                native = subprocess.run([shutil.which('rustup'), 'toolchain', 'install', 'nightly-2026-07-14',
                                         '--profile', 'minimal', '--no-self-update'], env=environment,
                                        capture_output=True, text=True, timeout=300)
                (receipt/'stdout.txt').write_text(native.stdout)
                (receipt/'stderr.txt').write_text(native.stderr)
                require(native.returncode != 0, 'Raw persistent HTTP503 must fail')
                require(state['manifestFailures'] == 1, 'Reassess observed native manifest retry behavior')
                result = {'status': 'EXPECTED_FAILURE', 'attempts': [{'exitCode': native.returncode}],
                          'meaning': 'RUSTUP_MAX_RETRIES does not retry this manifest HTTP503'}
            else:
                failed = None
                try:
                    result = acquire(receipt, environment)
                except ValueError as error:
                    failed = str(error)
                    result = json.loads((receipt/'rust-acquisition.json').read_text())
                expected_success = mode in ('first-success', 'recover')
                require((failed is None) == expected_success, str((mode, failed)))
                expected_attempts = 2 if mode == 'recover' else 11 if mode == 'persistent' else 1
                require(len(result['attempts']) == expected_attempts, str((mode, result['attempts'])))
                if expected_success:
                    require(result['status'] == 'PASS' and result['identity']['rustc'] and result['identity']['cargo'], 'Exact native Rust identity missing')
                else:
                    require(result['status'] == 'FAIL', 'Expected failure status lost')
                if mode == 'component-persistent':
                    cargo_calls = [r for r in state['requests'] if '/cargo-nightly-' in r['path']]
                    require(len(cargo_calls) == 11, 'Component retry count differs from10 additional attempts: '+str(len(cargo_calls)))
            # Every requested distribution path belongs to the same dated pin; no backtrack/mirror.
            require(all('/2026-07-14/' in r['path'] for r in state['requests']), 'Control attempted an alternative date')
            require(all('rustup/1.29.1' in (r['userAgent'] or '') for r in state['requests']), 'Requests did not originate from pinned rustup')
            (receipt/'http-requests.json').write_text(json.dumps(state['requests'], indent=2)+'\n')
            results.append({'mode': mode, 'status': 'PASS', 'attemptCount': len(result['attempts']),
                            'requestCount': len(state['requests']), 'scope': 'CONTROL_ONLY_LOOPBACK_FAULTS_OFFICIAL_BYTES'})
            (out/'rust-native-control.json').write_text(json.dumps({'status': 'IN_PROGRESS', 'cases': results}, indent=2)+'\n')
        (out/'rust-native-control.json').write_text(json.dumps({'status': 'PASS', 'cases': results}, indent=2)+'\n')
        print('RUSTUP_ACQUISITION_CONTROL=PASS; six real native executable cases')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
