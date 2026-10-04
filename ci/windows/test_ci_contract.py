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
