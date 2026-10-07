import json
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]

class PinnedGitContractTests(unittest.TestCase):
    def test_release_authority_preserves_native_and_msys_pins(self):
        pins = json.loads((ROOT/'ci/windows/ci-toolchain-pins.json').read_text())
        self.assertEqual(pins['gitVersion'], '2.55.0.5')
        git = pins['gitUpstream']
        self.assertEqual(git['releaseTag'], 'v2.55.0.windows.5')
        self.assertEqual(git['assetName'], 'MinGit-2.55.0.5-64-bit.zip')
        self.assertEqual(git['archiveSha256'], '56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e')
        self.assertEqual(git['executableVersion'], 'git version 2.55.0.windows.5')
        self.assertEqual(git['executableRelativePath'], 'cmd/git.exe')

    def test_acquisition_admits_archive_before_extraction_and_selection(self):
        code = (ROOT/'ci/windows/Install-PinnedGit.ps1').read_text()
        self.assertLess(code.index('Get-FileHash -LiteralPath $archive'), code.index('Expand-Archive'))
        self.assertLess(code.index('observedVersion.Trim() -cne'), code.index('AppendAllText'))
        for name in ('RUNNER_TEMP','GITHUB_ENV','GITHUB_PATH','HELIOS_GIT','Move-Item','gitSha256','gitSize','observedArchiveSha256'):
            self.assertIn(name, code)

    def test_checker_requires_explicit_git_and_exact_version(self):
        code = (ROOT/'ci/windows/Assert-ComponentToolchain.ps1').read_text()
        self.assertIn('HELIOS_GIT_REQUIRED', code)
        self.assertIn('$options.ExecutablePath=[string]$env:HELIOS_GIT', code)
        self.assertIn('$options.ExpectedResolvedPath=[string]$env:HELIOS_GIT', code)
        self.assertIn('[regex]::Escape($pins.gitUpstream.executableVersion)', code)
        self.assertNotIn("$pins.gitVersion -replace", code)
        init = (ROOT/'ci/windows/Initialize-HeliosBuild.ps1').read_text()
        self.assertIn('Split-Path -Parent ([IO.Path]::GetFullPath($env:HELIOS_GIT))', init)

    def test_all_component_jobs_install_before_consumers(self):
        workflow = yaml.safe_load((ROOT/'.github/workflows/windows-stack.yml').read_text())
        jobs = workflow['jobs']
        for name, job in jobs.items():
            steps = job.get('steps', [])
            if not any('Assert-ComponentToolchain.ps1' in s.get('run', '') for s in steps):
                continue
            with self.subTest(job=name):
                install = next(i for i,s in enumerate(steps) if 'Install-PinnedGit.ps1' in s.get('run',''))
                consumers = [i for i,s in enumerate(steps) if 'git submodule update' in s.get('run','') or 'Assert-ComponentToolchain.ps1' in s.get('run','')]
                self.assertTrue(all(install < i for i in consumers))
        focal = jobs['package_production_integration_preflight']['steps']
        self.assertTrue(any('Test-PinnedGit.ps1' in s.get('run','') for s in focal))

if __name__ == '__main__':
    unittest.main()
