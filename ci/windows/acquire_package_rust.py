"""Finite, exact-pin Package acquisition; never retry a job or select another toolchain."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

PINS = Path(__file__).with_name('ci-toolchain-pins.json')


def retry_manifest_failure(stderr):
    # Rustup 1.29.1's component retry does not cover manifest acquisition.
    return any(re.search(r'channel-rust-nightly\.toml(?:\.sha256)?', line)
               and re.search(r'(?:HTTP status code|http request returned an unsuccessful status code): (502|503|504)\b', line, re.IGNORECASE)
               for line in stderr.splitlines())


def acquire(receipt_dir, environment=None):
    environment = dict(os.environ if environment is None else environment)
    pins = json.loads(PINS.read_text(encoding='utf-8'))
    toolchain = pins['rust']['toolchain']
    if environment.get('RUST_TOOLCHAIN') != toolchain or environment.get('RUSTUP_TOOLCHAIN') != toolchain:
        raise ValueError('Package toolchain environment differs from qualified pin')
    if environment.get('RUSTUP_MAX_RETRIES') != '10':
        raise ValueError('Package requires finite RUSTUP_MAX_RETRIES=10')
    rustup = shutil.which('rustup', path=environment.get('PATH'))
    if not rustup:
        raise ValueError('rustup executable unavailable')
    receipt_dir = Path(receipt_dir)
    receipt_dir.mkdir(parents=True, exist_ok=True)
    record = {'status': 'FAIL', 'toolchain': toolchain, 'rustupExecutable': rustup,
              'componentDownloadMaxRetries': 10, 'manifestMaxRetries': 10,
              'distributionServer': environment.get('RUSTUP_DIST_SERVER', 'https://static.rust-lang.org'),
              'workflowRetry': False, 'versionFallback': False, 'attempts': [], 'identity': {}}
    def save():
        target = receipt_dir/'rust-acquisition.json'
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps(record, indent=2)+'\n', encoding='utf-8')
        temporary.replace(target)
    def run(args, label):
        result = subprocess.run([rustup, *args], env=environment, capture_output=True, text=True,
                                encoding='utf-8', errors='replace', timeout=900)
        (receipt_dir/(label+'.stdout.txt')).write_text(result.stdout, encoding='utf-8')
        (receipt_dir/(label+'.stderr.txt')).write_text(result.stderr, encoding='utf-8')
        return result
    save()
    try:
        version = run(['--version'], 'rustup-version')
        if version.returncode or not re.match(r'^rustup '+re.escape(pins['rust']['rustupVersion'])+r'(?:\s|$)', version.stdout):
            raise ValueError('rustup version differs from qualified pin')
        arguments = ['toolchain', 'install', toolchain, '--profile', 'minimal', '--no-self-update']
        for attempt in range(1, 12):
            result = run(arguments, f'install-{attempt:02d}')
            retryable = result.returncode != 0 and retry_manifest_failure(result.stderr)
            record['attempts'].append({'attempt': attempt, 'arguments': arguments,
                                      'exitCode': result.returncode, 'manifestTransient': retryable})
            save()
            if result.returncode == 0:
                break
            if not retryable or attempt == 11:
                raise ValueError('Pinned Rust acquisition failed; no fallback permitted')
            time.sleep(min(attempt * 2, 10))
        else:
            raise ValueError('Pinned Rust acquisition exhausted')
        toolchains = run(['toolchain', 'list'], 'toolchain-list')
        expected = toolchain+'-x86_64-pc-windows-msvc'
        if toolchains.returncode or not any(line.split()[0] == expected for line in toolchains.stdout.splitlines() if line.split()):
            raise ValueError('Installed Windows toolchain identity mismatch')
        record['identity']['toolchainList'] = toolchains.stdout.strip()
        for name in ('rustc', 'cargo'):
            result = run(['run', toolchain, name, '--version'], name+'-version')
            record['identity'][name] = result.stdout.strip()
            if result.returncode or result.stdout.strip() != pins['qualifiedObservedTools'][name]:
                raise ValueError(name+' differs from qualified exact version')
        record['status'] = 'PASS'
        save()
        return record
    except Exception as error:
        record['errorType'] = type(error).__name__
        record['error'] = str(error)
        save()
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--receipt-dir', required=True)
    args = parser.parse_args()
    # Production never changes mirrors. Loopback HTTP fault injection is control-only.
    if os.environ.get('RUSTUP_DIST_SERVER', 'https://static.rust-lang.org') != 'https://static.rust-lang.org':
        raise ValueError('Package acquisition requires the official distribution server')
    result = acquire(args.receipt_dir)
    print('PACKAGE_RUST_ACQUISITION=PASS; toolchain='+result['toolchain']+'; RUSTUP_MAX_RETRIES=10')


if __name__ == '__main__':
    main()
