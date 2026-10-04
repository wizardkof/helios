"""Adapt only qualified WDK plugin dispatch; ordinary @rust remains host-owned."""
import argparse
from pathlib import Path

def adapt(text, helper, private_root):
    for value in (helper, private_root):
        if not value or any(ch.isspace() or ch in '\"\\$;`' for ch in value):
            raise ValueError('Isolation controls require safe absolute short Windows paths')
        if len(value)<3 or value[1:3]!=':/':
            raise ValueError('Isolation controls require absolute local Windows paths')
    install='out = exec --fail-on-error cargo install ${taskjson.install_crate.crate_name} --version ${taskjson.install_crate.min_version}'
    run='out = exec --fail-on-error rust-script --base-path '
    script=' ${CARGO_MAKE_CRATE_CUSTOM_TRIPLE_TARGET_DIRECTORY}/cargo-make-script/${task.name}/rust-env-update.rs %{combined_args}'
    for site in (install, run, script):
        if text.count(site)!=1:raise ValueError('Qualified WDK recipe shape changed: '+site)
    text=text.replace(install,'out = exec --fail-on-error pwsh.exe -NoProfile -File '+helper+' -Mode Install -PrivateRoot '+private_root+' -TaskName ${task.name}')
    text=text.replace(run,'out = exec --fail-on-error pwsh.exe -NoProfile -File '+helper+' -Mode Run -PrivateRoot '+private_root+' -TaskName ${task.name} -BasePath ')
    return text.replace(script,' -ScriptPath'+script)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--output',required=True);p.add_argument('--helper',required=True);p.add_argument('--private-root',required=True);a=p.parse_args()
    Path(a.output).write_text(adapt(Path(a.input).read_text(encoding='utf-8-sig'),a.helper,a.private_root),encoding='utf-8')
