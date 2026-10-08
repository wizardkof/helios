"""No-follow entry guards and handle-bound reads for CI evidence.

Directory ancestor replacement remains a race: components are checked again at
operation boundaries, but are not all pinned by relative directory handles.
"""
import ctypes
import fnmatch
import glob
import os
from pathlib import Path
import stat

REPARSE= getattr(stat,'FILE_ATTRIBUTE_REPARSE_POINT',0x400)

class EntryRefusal(ValueError):
    def __init__(self,path,component,stage,info=None,code='REPARSE_POINT_REFUSED'):
        self.details=dict(code=code,requestedPath=str(path),rejectedComponent=str(component),detectionStage=stage,fileAttributes=getattr(info,'st_file_attributes',None),reparseTag=getattr(info,'st_reparse_tag',None))
        super().__init__('reparse/symlink refused: '+str(component) if code=='REPARSE_POINT_REFUSED' else code+': '+str(component))

def absolute(path):
    path=Path(path)
    if '..' in path.parts:raise EntryRefusal(path,path,'path-syntax',code='AMBIGUOUS_PARENT_COMPONENT_REFUSED')
    return Path(os.path.abspath(path))

def guard(path,stage='entry'):
    """lstat each lexical component from root before inspecting its child."""
    requested=Path(path);path=absolute(path);current=Path(path.anchor);info=None
    for component in (None,*path.parts[1:]):
        if component is not None:current=current/component
        info=current.lstat()
        if stat.S_ISLNK(info.st_mode) or getattr(info,'st_file_attributes',0)&REPARSE:
            raise EntryRefusal(requested,current,stage,info)
        # CPython 3.12 exposes junction identity separately. This never resolves.
        if os.name=='nt' and hasattr(current,'is_junction') and current.is_junction():
            raise EntryRefusal(requested,current,stage,info)
    return info

def matches(pattern):
    """Expand one component at a time, checking directories before scandir."""
    requested=Path(pattern);pattern=absolute(pattern)
    def expand(parent,parts):
        if not parts:
            try:guard(parent,'glob-result')
            except FileNotFoundError:return
            yield parent;return
        part,*tail=parts
        if glob.has_magic(part):
            if part=='**':raise EntryRefusal(requested,parent,'glob',code='RECURSIVE_GLOB_UNSUPPORTED')
            try:info=guard(parent,'glob-directory')
            except FileNotFoundError:return
            if not stat.S_ISDIR(info.st_mode):return
            with os.scandir(parent) as iterator:
                names=sorted(entry.name for entry in iterator)
            guard(parent,'glob-after-enumeration')
            for name in names:
                if name.startswith('.') and not part.startswith('.'):continue
                if fnmatch.fnmatch(name,part):
                    child=parent/name;guard(child,'glob-selected-entry')
                    yield from expand(child,tail)
        else:
            child=parent/part
            try:info=guard(child,'glob-literal-component')
            except FileNotFoundError:return
            if tail and not stat.S_ISDIR(info.st_mode):return
            yield from expand(child,tail)
    return sorted(expand(Path(pattern.anchor),list(pattern.parts[1:])))

def files(path):
    """Inspect every directory entry before classifying or descending into it."""
    path=Path(path);info=guard(path,'walk-root')
    if stat.S_ISREG(info.st_mode):return [path]
    if not stat.S_ISDIR(info.st_mode):raise EntryRefusal(path,path,'walk',info,code='NON_REGULAR_SOURCE_REFUSED')
    output=[]
    def walk(directory):
        guard(directory,'walk-before-enumeration')
        with os.scandir(directory) as iterator:
            children=sorted((Path(entry.path) for entry in iterator),key=str)
        guard(directory,'walk-after-enumeration')
        for child in children:
            info=guard(child,'walk-entry')
            if stat.S_ISDIR(info.st_mode):walk(child)
            elif stat.S_ISREG(info.st_mode):output.append(child)
            else:raise EntryRefusal(path,child,'walk-entry',info,code='NON_REGULAR_SOURCE_REFUSED')
    walk(path)
    return sorted(output)

def _windows_fd(path):
    """Deny write/delete sharing and inspect the actual OPEN_REPARSE_POINT handle."""
    import msvcrt
    from ctypes import wintypes
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    class FileInfo(ctypes.Structure):
        _fields_=[('attributes',wintypes.DWORD),('creation',wintypes.FILETIME),('access',wintypes.FILETIME),('write',wintypes.FILETIME),('volume',wintypes.DWORD),('sizeHigh',wintypes.DWORD),('sizeLow',wintypes.DWORD),('links',wintypes.DWORD),('indexHigh',wintypes.DWORD),('indexLow',wintypes.DWORD)]
    create=kernel.CreateFileW;create.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,wintypes.LPVOID,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE];create.restype=wintypes.HANDLE
    close=kernel.CloseHandle;close.argtypes=[wintypes.HANDLE];close.restype=wintypes.BOOL
    query=kernel.GetFileInformationByHandle;query.argtypes=[wintypes.HANDLE,ctypes.POINTER(FileInfo)];query.restype=wintypes.BOOL
    handle=create(str(absolute(path)),0x80000000,0x1,None,3,0x00200000|0x02000000,None)
    if handle==ctypes.c_void_p(-1).value:raise ctypes.WinError(ctypes.get_last_error())
    try:
        info=FileInfo()
        if not query(handle,ctypes.byref(info)):raise ctypes.WinError(ctypes.get_last_error())
        if info.attributes&REPARSE:
            raise EntryRefusal(path,path,'opened-handle',type('Attrs',(),{'st_file_attributes':info.attributes})())
        if info.attributes&0x10:raise EntryRefusal(path,path,'opened-handle',code='NON_REGULAR_FILE_REFUSED')
        fd=msvcrt.open_osfhandle(handle,os.O_RDONLY|os.O_BINARY);handle=None
        return fd
    finally:
        if handle is not None:close(handle)

def read(path):
    path=Path(path);before=guard(path,'before-open')
    if not stat.S_ISREG(before.st_mode):raise EntryRefusal(path,path,'before-open',before,code='NON_REGULAR_FILE_REFUSED')
    fd=_windows_fd(path) if os.name=='nt' else os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as stream:
        opened=os.fstat(stream.fileno())
        if not stat.S_ISREG(opened.st_mode):raise EntryRefusal(path,path,'opened-object',code='NON_REGULAR_FILE_REFUSED')
        # Some Windows CRT stat fields may be unavailable; compare supported identity fields.
        if before.st_ino and opened.st_ino and (before.st_dev,before.st_ino)!=(opened.st_dev,opened.st_ino):raise ValueError('source identity changed before open')
        if before.st_size!=opened.st_size:raise ValueError('source size changed before open')
        guard(path,'after-open')
        data=stream.read()
        after=os.fstat(stream.fileno())
        if (opened.st_size,opened.st_mtime_ns)!=(after.st_size,after.st_mtime_ns):raise ValueError('source changed during read')
        current=guard(path,'after-read')
        if before.st_ino and current.st_ino and (before.st_dev,before.st_ino)!=(current.st_dev,current.st_ino):raise ValueError('source path identity changed during read')
        if current.st_size!=len(data):raise ValueError('source size changed during read')
        return data

def ensure_directory(path):
    """Create missing directories one lexical component at a time."""
    path=absolute(path);current=Path(path.anchor);guard(current,'mkdir-root')
    for part in path.parts[1:]:
        current=current/part
        try:info=guard(current,'mkdir-existing')
        except FileNotFoundError:
            guard(current.parent,'mkdir-parent')
            try:current.mkdir()
            except FileExistsError:pass # A competing creation must still satisfy the guard.
            info=guard(current,'mkdir-created')
        if not stat.S_ISDIR(info.st_mode):raise ValueError('directory parent is not a directory: '+str(current))

def create_file(path,data):
    """Exclusive destination creation; no replacement or final-component traversal."""
    path=Path(path);guard(path.parent,'destination-parent')
    flags=os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0)
    fd=os.open(path,flags,0o600)
    with os.fdopen(fd,'wb') as stream:
        guard(path,'destination-opened');stream.write(data)
    guard(path,'destination-after-write')
