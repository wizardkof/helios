import unittest
from adapt_wdk_recipe import adapt

INSTALL = 'out = exec --fail-on-error cargo install ${taskjson.install_crate.crate_name} --version ${taskjson.install_crate.min_version}'
RUN = 'out = exec --fail-on-error rust-script --base-path /source ${CARGO_MAKE_CRATE_CUSTOM_TRIPLE_TARGET_DIRECTORY}/cargo-make-script/${task.name}/rust-env-update.rs %{combined_args}'
FIXTURE = '[tasks.keep]\nscript_runner = "@rust"\n' + INSTALL + '\n' + RUN + '\n'
class WdkIsolationTests(unittest.TestCase):
    def test_private_install_and_run_preserve_host_tasks(self):
        result=adapt(FIXTURE, 'C:/hb/Invoke-WdkRustScript.ps1','C:/hb/private')
        self.assertNotIn('exec --fail-on-error cargo install',result)
        self.assertNotIn('exec --fail-on-error rust-script --base-path',result)
        self.assertIn('-Mode Install -PrivateRoot C:/hb/private',result)
        self.assertIn('-Mode Run -PrivateRoot C:/hb/private',result)
        self.assertIn('-ScriptPath ${CARGO_MAKE_CRATE_CUSTOM_TRIPLE_TARGET_DIRECTORY}',result)
        self.assertTrue(result.startswith('[tasks.keep]\nscript_runner = "@rust"\n'))
    def test_duplicate_install_fails_closed(self):
        with self.assertRaises(ValueError):adapt(FIXTURE+INSTALL,'C:/hb/helper.ps1','C:/hb/private')
    def test_missing_run_fails_closed(self):
        with self.assertRaises(ValueError):adapt(INSTALL,'C:/hb/helper.ps1','C:/hb/private')
    def test_unexpected_script_argument_fails_closed(self):
        with self.assertRaises(ValueError):adapt(FIXTURE.replace('rust-env-update.rs','unexpected.rs'),'C:/hb/helper.ps1','C:/hb/private')
    def test_unsafe_paths_rejected(self):
        with self.assertRaises(ValueError):adapt(FIXTURE,'C:/path with spaces/helper.ps1','C:/hb/private')
if __name__=='__main__':unittest.main()

class WorkflowInfrastructureOnlyTests(unittest.TestCase):
    def test_infrastructure_only_never_schedules_product_jobs_or_bundle(self):
        import yaml
        from pathlib import Path
        workflow = yaml.safe_load(Path(__file__).parents[2].joinpath('.github/workflows/windows-stack.yml').read_text())
        for name in ('mesa', 'mesa_x86', 'opencl', 'loaders', 'compatibility', 'package'):
            self.assertIn('!inputs.infrastructure_only', workflow['jobs'][name]['if'], name)
        steps = workflow['jobs']['driver']['steps']
        ids = [step['id'] for step in steps if 'id' in step]
        self.assertEqual(len(ids), len(set(ids)))
        for name in ('Install Rust nightly', 'Install Rust build helpers', 'Initialize isolated host and private WDK producers', 'Install Meson', 'Install and validate Vulkan SDK'):
            step = next(step for step in steps if step.get('name') == name)
            self.assertIn('always()', step.get('if', 'always()'), name)
        for name in ('Build pinned Wine 11.12 WIDL from official source', 'Capture Mesa MSYS2 package and Ninja consumer preflight'):
            step = next(step for step in steps if step.get('name') == name)
            self.assertIn('always()', step.get('if', 'always()'))

    def test_widl_build_uses_msys_make_and_disables_unneeded_freetype(self):
        from pathlib import Path
        script = Path(__file__).with_name('build-pinned-widl.sh').read_text()
        self.assertIn('./configure --enable-win64 --without-x --without-freetype --disable-tests', script)
        self.assertIn('make -C tools/widl -j2', script)

    def test_cargo_make_is_invoked_as_pinned_cargo_subcommand(self):
        from pathlib import Path
        root = Path(__file__).parents[2]
        for rel in ('ci/windows/Assert-CIToolchain.ps1', 'ci/windows/Assert-ComponentToolchain.ps1'):
            text = root.joinpath(rel).read_text()
            self.assertIn("name='cargo.exe'", text)
            self.assertIn("args=@('make','--version')", text)
            self.assertNotIn("name='cargo-make.exe'", text)
        init = root.joinpath('ci/windows/Initialize-CIIsolation.ps1').read_text()
        runner = root.joinpath('ci/windows/Invoke-IsolatedCargoMake.ps1').read_text()
        self.assertIn("(Get-Command cargo.exe).Source", init)
        self.assertIn("host-dispatch\\cargo.exe", runner)
        self.assertIn('$env:HELIOS_ORIGINAL_CARGO).Hash', runner)

    def test_global_vulkan_path_uses_normalized_expected_identity(self):
        from pathlib import Path
        checker = Path(__file__).with_name('Assert-CIToolchain.ps1').read_text()
        self.assertIn("$env:VULKAN_SDK = (Join-Path 'C:/VulkanSDK' $pins.vulkanSdkVersion).Replace('\\','/')", checker)
        self.assertIn("$expectedVulkanRoot = (Join-Path 'C:/VulkanSDK' $pins.vulkanSdkVersion).Replace('\\','/')", checker)
        self.assertIn("$Expected = ([string]$Expected).Replace('\\\\','/').TrimEnd('/')", checker)
        component = Path(__file__).with_name('Assert-ComponentToolchain.ps1').read_text()
        self.assertIn("$vulkanRoot.TrimEnd('\\\\','/')", component)
