import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]

class PackageContracts(unittest.TestCase):
    def test_package_only_finite_retry_and_exact_toolchain(self):
        workflow = yaml.safe_load((ROOT/'.github/workflows/windows-stack.yml').read_text())
        package = workflow['jobs']['package']
        self.assertEqual(package['env']['RUSTUP_MAX_RETRIES'], '10')
        step = next(s for s in package['steps'] if s.get('id') == 's14')
        self.assertIn('acquire_package_rust.py', step['run'])
        self.assertEqual(workflow['env']['RUST_TOOLCHAIN'], 'nightly-2026-07-14')
        self.assertNotIn('RUSTUP_MAX_RETRIES',workflow['env'])

    def test_acquisition_retry_policy(self):
        from acquire_package_rust import retry_manifest_failure
        self.assertTrue(retry_manifest_failure('could not download file channel-rust-nightly.toml HTTP status code: 503'))
        self.assertTrue(retry_manifest_failure('channel-rust-nightly.toml.sha256 HTTP status code: 502'))
        self.assertFalse(retry_manifest_failure('channel-rust-nightly.toml HTTP status code: 404'))
        self.assertFalse(retry_manifest_failure('rustc-nightly.tar.xz HTTP status code: 503'))
        self.assertFalse(retry_manifest_failure('toolchain identity mismatch'))
        for code in (502, 503, 504):
            self.assertTrue(retry_manifest_failure(f'channel-rust-nightly.toml http request returned an unsuccessful status code: {code}'))
        self.assertTrue(retry_manifest_failure('channel-rust-nightly.toml HTTP status code: 504'))
        self.assertTrue(retry_manifest_failure("could not download file from 'http://127.0.0.1/dist/2026-07-14/channel-rust-nightly.toml': http request returned an unsuccessful status code: 503"))
        self.assertFalse(retry_manifest_failure('channel-rust-nightly.toml\ncomponent HTTP status code: 503'))

    def test_date_gate_native_control_is_required(self):
        script = (ROOT/'ci/windows/Assemble-Package.ps1').read_text()
        self.assertIn('[string[]]$driverDateFormats',script)
        self.assertIn('driver-date-diagnostic.json',script)
        self.assertIn('InvariantCulture',script)
        self.assertNotIn('[DateTime]::Parse(',script)
