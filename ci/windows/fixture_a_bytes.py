"""Raw current-HEAD identity and separate semantics of the frozen .317 fixture."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

EXPECTED_SHA256='6f529cdd45961ff29420e0bc35dc7de0190c5fce9b28518aaf6f6370cc64a033'
RELATIVE_FIXTURE='ci/windows/fixtures/msys2-archives-317.json'
AUTHORITY='6437badff87d903a4bab4d4f1cc7f9e682e50bea'

def default_receipt():
    return Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'python-test-dependencies'/'fixture-a-byte-identity.json'

def inspect_fixture_a(root,source,receipt,manifest,expected=EXPECTED_SHA256):
    root=Path(root).resolve();source=Path(source);receipt=Path(receipt)
    record=dict(status='FAIL',fixturePath=str(source),relativePath=RELATIVE_FIXTURE,expectedSha256=expected,worktreeSha256=None,gitBlobSha256=None,gitBlobObjectId=None,worktreeSize=None,gitBlobSize=None,byteCause='NOT_OBSERVED',firstDivergentOffsets=[],gitCommands=[],gitBlobIdentity='NOT_OBSERVED',checkoutByteIdentity='NOT_OBSERVED',historicalArchiveSemantics='NOT_RUN')
    def git(*args):
        result=subprocess.run(['git','-C',str(root),*args],capture_output=True)
        record['gitCommands'].append(dict(command=['git',*args],exitCode=result.returncode,stderr=result.stderr.decode('utf-8',errors='replace')))
        return result
    try:
        if source.resolve()!=(root/RELATIVE_FIXTURE).resolve() or source.is_symlink():raise ValueError('HISTORIC_FIXTURE_PATH_IDENTITY_MISMATCH')
        oid=git('rev-parse','HEAD:'+RELATIVE_FIXTURE)
        if oid.returncode:raise ValueError('HISTORIC_FIXTURE_CURRENT_HEAD_BLOB_UNAVAILABLE')
        record['gitBlobObjectId']=oid.stdout.decode('ascii').strip()
        result=git('cat-file','blob',record['gitBlobObjectId'])
        if result.returncode:raise ValueError('HISTORIC_FIXTURE_BLOB_READ_FAILED')
        blob=result.stdout
        record.update(gitBlobSha256=hashlib.sha256(blob).hexdigest(),gitBlobSize=len(blob),blobCrlf=blob.count(b'\r\n'),blobIsolatedLf=blob.count(b'\n')-blob.count(b'\r\n'))
        record['gitBlobIdentity']='PASS' if record['gitBlobSha256']==EXPECTED_SHA256 else 'FAIL'
        attrs=git('check-attr','-z','text','eol','--',RELATIVE_FIXTURE)
        if attrs.returncode:raise ValueError('HISTORIC_FIXTURE_ATTRIBUTES_READ_FAILED')
        parts=attrs.stdout.decode('utf-8').split('\0');record['attributes']={parts[i+1]:parts[i+2] for i in range(0,len(parts)-1,3)}
        record['gitConfig']={}
        for option in ('core.autocrlf','core.eol'):
            value=git('config','--get',option)
            record['gitConfig'][option]=dict(value=value.stdout.decode('utf-8').strip() if value.returncode==0 else None,exitCode=value.returncode)
            if value.returncode not in (0,1):raise ValueError('HISTORIC_FIXTURE_GIT_CONFIG_READ_FAILED')
        data=source.read_bytes()
        record.update(worktreeSha256=hashlib.sha256(data).hexdigest(),worktreeSize=len(data),worktreeCrlf=data.count(b'\r\n'),worktreeIsolatedLf=data.count(b'\n')-data.count(b'\r\n'))
        record['firstDivergentOffsets']=[i for i in range(max(len(data),len(blob))) if i>=len(data) or i>=len(blob) or data[i]!=blob[i]][:16]
        if data==blob:record['byteCause']='NO_CHECKOUT_CONVERSION_BYTES_IDENTICAL'
        elif b'\r\n' not in blob and data==blob.replace(b'\n',b'\r\n'):record['byteCause']='LF_BLOB_TO_CRLF_WORKTREE_CONFIRMED'
        else:record['byteCause']='OTHER_BYTE_DIVERGENCE'
        record['checkoutByteIdentity']='PASS' if data==blob and record['worktreeSha256']==EXPECTED_SHA256 else 'FAIL'
        if expected!=EXPECTED_SHA256:raise ValueError('HISTORIC_FIXTURE_EXPECTED_HASH_UNAPPROVED')
        if record['gitBlobIdentity']!='PASS':raise ValueError('HISTORIC_FIXTURE_GIT_BLOB_IDENTITY_MISMATCH')
        if record['checkoutByteIdentity']!='PASS':raise ValueError('HISTORIC_FIXTURE_IDENTITY_MISMATCH')
        if record['attributes'].get('text')!='unset':raise ValueError('HISTORIC_FIXTURE_SPECIFIC_BINARY_ATTRIBUTE_REQUIRED')
        record['historicalArchiveSemantics']='FAIL'
        baseline=json.loads(data)
        if baseline['authority']['commit']!=AUTHORITY or len(baseline['packages'])!=7:raise ValueError('HISTORIC_FIXTURE_INVALID')
        if manifest['msys2ArchivedPackages']['baseUrl']!=baseline['baseUrl']:raise ValueError('HISTORIC_ARCHIVE_ORIGIN_CHANGED')
        rows=manifest['msys2ArchivedPackages']['packages'];names=[row['name'] for row in rows]
        if len(names)!=len(set(names)):raise ValueError('ARCHIVE_NAME_DUPLICATE')
        for old in baseline['packages']:
            if old not in rows:raise ValueError('HISTORIC_ARCHIVE_CHANGED_OR_MISSING: '+old['name'])
        record.update(status='PASS',historicalArchiveSemantics='PASS',historicalArchiveCount=7,gitCheckoutByteContract='PASS')
    except (OSError,ValueError,KeyError,TypeError) as error:
        record['firstFailure']=str(error)
        raise
    finally:
        receipt.parent.mkdir(parents=True,exist_ok=True)
        receipt.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    return record
