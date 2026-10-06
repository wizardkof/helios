"""Check historical inputs without rewriting their original producer identity."""
import argparse
import json
from pathlib import Path
from ci_artifact import verify

parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True)
parser.add_argument('--configuration', required=True, choices=['Release', 'Debug'])
parser.add_argument('--receipt', required=True)
args = parser.parse_args()
provenance = json.loads((Path(__file__).parent/'fixtures/package-313/provenance.json').read_text())
expected = dict(provenance['historicalIdentity'])
expected['configuration'] = args.configuration
record = verify(args.directory, expected)
if args.configuration == 'Debug':
    inf = next(row for row in record['files'] if row['path'] == 'helios_kmd_render.inf')
    if inf != provenance['inf']:
        raise ValueError('Original Debug INF differs from preserved historical exact bytes')
Path(args.receipt).write_text(json.dumps({'status': 'PASS', 'scope': 'IMMUTABLE_313_INPUT_NOT_CURRENT_PRODUCT',
                                       'originalIdentity': expected, 'files': record['files']}, indent=2)+'\n')
print('HISTORICAL_313_DRIVER_INPUT=PASS; original identity unchanged')
