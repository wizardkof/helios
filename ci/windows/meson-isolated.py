"""Local Meson entrypoint: retain wrap locking outside candidate source roots."""
import hashlib
import os
from pathlib import Path
import sys
import mesonbuild.wrap.wrap as wrap
from mesonbuild import mesonmain

OriginalDirectoryLock = wrap.DirectoryLock

class BuildDirectoryLock(OriginalDirectoryLock):
    def __init__(self, dirname, *args, **kwargs):
        # One stable lock directory per canonical source subprojects directory.
        # Preserve Meson's filename, WAIT policy and OS lock implementation.
        key = hashlib.sha256(os.path.normcase(os.path.realpath(dirname)).encode()).hexdigest()
        lock_root = Path(os.environ['HELIOS_MESON_LOCK_ROOT']) / key
        lock_root.mkdir(parents=True, exist_ok=True)
        print('MESON_WRAP_LOCK_REDIRECT=' + str(dirname) + ' -> ' + str(lock_root), flush=True)
        super().__init__(str(lock_root), *args, **kwargs)

wrap.DirectoryLock = BuildDirectoryLock
if __name__ == '__main__':
    sys.exit(mesonmain.main())
