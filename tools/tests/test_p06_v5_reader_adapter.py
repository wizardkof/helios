from pathlib import Path
import re


source = Path(__file__).parents[1] / "escape_owner_probe.c"
text = source.read_text()

helper = re.search(
    r"static\s+NTSTATUS\s+escape_on_adapter\s*\([^)]*\)\s*\{(.*?)\n\}",
    text,
    re.S,
)
assert helper, "candidate query must use an explicit adapter/device escape helper"
assert re.search(r"esc\.hAdapter\s*=\s*adapter\s*;", helper.group(1))
assert re.search(r"esc\.hDevice\s*=\s*device\s*;", helper.group(1))

query = re.search(
    r"static\s+int\s+v5_query_supported\s*\([^)]*\)\s*\{(.*?)\n\}",
    text,
    re.S,
)
assert query, "V5 candidate query helper is missing"
assert re.search(r"escape_on_adapter\s*\(\s*adapter\s*,\s*device\s*,\s*&v5", query.group(1))
assert re.search(
    r"v5_query_supported\s*\(\s*items\[i\]\.hAdapter\s*,\s*create\.hDevice\s*\)",
    text,
), "candidate enumeration must pass its matching hAdapter and hDevice"

reader_open = re.search(
    r"static\s+int\s+v5_reader_open\s*\([^)]*\)\s*\{(.*?)\n\}",
    text,
    re.S,
)
assert reader_open, "V5 reader open function is missing"
assert "(void)D3DKMTCloseAdapter" not in reader_open.group(1), (
    "candidate adapter close status must not be discarded"
)
assert re.search(r"close_status\s*=\s*D3DKMTCloseAdapter\(&close\)", reader_open.group(1)), (
    "candidate adapter close status must be captured"
)

print("P06_V5_CANDIDATE_ADAPTER_ROUTE=PASS")
