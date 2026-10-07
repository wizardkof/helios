import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]

class PinnedGitContractTests(unittest.TestCase):
    def test_installer_normalizes_multiple_application_candidates_before_source(self):
        code = (ROOT/'ci/windows/Install-PinnedGit.ps1').read_text()
        self.assertRegex(code, r'(?s)\$runnerGitCandidates\s*=\s*@\(\s*Get-Command git[^)]*-All[^)]*\)')
        selection = '$runnerGit = $runnerGitCandidates | Select-Object -First 1'
        self.assertIn(selection, code)
        self.assertLess(code.index(selection), code.index('& $runnerGit.Source --version'))
        self.assertIn('$receipt.runnerGitPath = [string]$runnerGit.Source', code)
        self.assertIn('runnerGitCandidates=@()', code)
        self.assertIn('$runnerGitCandidates | ForEach-Object { [string]$_.Source }', code)
        self.assertNotIn('& $runnerGitCandidates.Source', code)

    def test_resolution_requires_first_application_not_any_matching_candidate(self):
        code = (ROOT/'ci/windows/Test-PinnedGit.ps1').read_text()
        self.assertRegex(code, r'(?s)\$candidates\s*=\s*@\(\s*Get-Command git[^)]*-All[^)]*\)')
        selection = '$command = $candidates | Select-Object -First 1'
        self.assertIn(selection, code)
        self.assertLess(code.index(selection), code.index('[string]$command.Source'))
        self.assertIn('if ($candidates.Count -lt 1)', code)
        self.assertIn('resolutionCandidates=', code)
        self.assertIn('[StringComparison]::OrdinalIgnoreCase', code)
        self.assertNotIn('(Get-Command git -CommandType Application -ErrorAction Stop).Source', code)
        self.assertNotIn('$candidates.Count -ne 1', code)

    @unittest.skipUnless(os.name == 'nt' and shutil.which('pwsh'), 'PowerShell native multi-candidate regression requires Windows')
    def test_native_three_candidates_select_first_and_reject_later_authority(self):
        install = (ROOT/'ci/windows/Install-PinnedGit.ps1').read_text()
        # Execute the real observation block; only command discovery is substituted.
        observation = install[install.index('    $runnerGitCandidates ='):install.index('    $pins =')]
        test = (ROOT/'ci/windows/Test-PinnedGit.ps1').read_text()
        resolution = test[test.index('function Assert-GitResolution'):test.index('\ntry {')]
        with tempfile.TemporaryDirectory() as temporary:
            paths = [str(Path(temporary)/f'git-{i}.cmd') for i in range(3)]
            for path in paths:
                Path(path).write_text('@echo off\necho git version 2.55.0.windows.5\nexit /b 0\n')
            fixture = json.dumps(paths)
            script = """$ErrorActionPreference='Stop'
$paths = ConvertFrom-Json -InputObject '%s'
function Get-Command { param($Name,$CommandType,[switch]$All,$ErrorAction) $paths | ForEach-Object { [pscustomobject]@{Source=$_;CommandType='Application'} } }
$receipt = [ordered]@{runnerGitCandidates=@();runnerGitPath=$null;runnerGitVersion=$null;resolution=@()}
%s
if($receipt.runnerGitCandidates.Count -ne 3 -or $receipt.runnerGitPath -cne $paths[0]){throw 'Observation did not select first of three candidates'}
$selected=$paths[0]
$pins=[pscustomobject]@{gitUpstream=[pscustomobject]@{executableVersion='git version 2.55.0.windows.5'}}
%s
Assert-GitResolution 'three-candidates-first-authority'
if($receipt.resolution[0].resolutionCandidates.Count -ne 3){throw 'Resolution candidates lost'}
$selected=$paths[1]
$refused=$false
try{Assert-GitResolution 'authority-present-but-not-first'}catch{$refused=$true}
if(-not $refused){throw 'A later matching authority was incorrectly accepted'}
""" % (fixture.replace("'", "''"), observation, resolution)
            result = subprocess.run(['pwsh','-NoProfile','-Command',script], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

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
