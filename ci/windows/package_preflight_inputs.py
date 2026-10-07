"""Pre-reservation intake: exact frozen .314 API identity, archive digest and CRC."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import zipfile


def validate_archive(path, digest):
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest:
        raise ValueError('Frozen artifact API digest mismatch')
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('Frozen artifact CRC failure')
        names=set()
        for entry in archive.infolist():
            name=entry.filename.replace('\\','/')
            if name.startswith('/') or ':' in name or '..' in PurePosixPath(name).parts or name.casefold() in names or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('Unsafe or duplicate artifact archive path')
            names.add(name.casefold())
        return len(archive.infolist())


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--provenance',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--configuration',choices=['Release','Debug'],required=True)
    a=p.parse_args();record=json.loads(a.provenance.read_text(encoding='utf-8-sig'))
    repo=os.environ['GITHUB_REPOSITORY']
    a.output.mkdir(parents=True,exist_ok=True)
    rows=[]
    for item in record['artifacts']:
        if item['name'].startswith('helios-driver-') and item['name']!='helios-driver-'+a.configuration:
            continue
        folder='driver' if item['name'].startswith('helios-driver-') else item['name'].removeprefix('helios-')
        dest=a.output/folder
        if dest.exists():raise ValueError('Frozen artifact intake destination already exists')
        archive=a.output/(item['artifactId']+'.zip')
        with archive.open('wb') as stream:
            subprocess.run(['gh','api',f'repos/{repo}/actions/artifacts/{item["artifactId"]}/zip'],stdout=stream,check=True)
        count=validate_archive(archive,item['sha256'])
        with zipfile.ZipFile(archive) as source:source.extractall(dest)
        rows.append(dict(item,crc='PASS',archiveSha256=item['sha256'],archiveFileCount=count))
    if len(rows)!=6:raise ValueError('Frozen input artifact coverage mismatch')
    (a.output/'verified-intake.json').write_text(json.dumps({'status':'PASS_API_DIGEST_CRC','artifacts':rows},indent=2)+'\n')
    print('FROZEN_INPUT_ARCHIVE_DIGEST_CRC=PASS_6_OF_6')

if __name__=='__main__':main()
