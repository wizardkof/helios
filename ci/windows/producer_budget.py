"""Windows producer supervisor: a gated child and descendants owned by one Job Object.

No build options, tool selection, cache policy or retries live here. Closing the
job is fail-closed even if this supervisor is interrupted by the runner.
"""
import argparse
import ctypes
from ctypes import wintypes as w
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def utc():
    return datetime.now(timezone.utc).isoformat()


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


class WindowsJob:
    def __init__(self):
        self.api = ctypes.WinDLL('kernel32', use_last_error=True)
        api = self.api
        signatures = {
            'CreateJobObjectW': ([ctypes.c_void_p, w.LPCWSTR], w.HANDLE),
            'SetInformationJobObject': ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD], w.BOOL),
            'AssignProcessToJobObject': ([w.HANDLE, w.HANDLE], w.BOOL),
            'TerminateJobObject': ([w.HANDLE, w.UINT], w.BOOL),
            'QueryInformationJobObject': ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.c_void_p], w.BOOL),
            'CloseHandle': ([w.HANDLE], w.BOOL),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(api, name)
            function.argtypes, function.restype = arguments, result
        self.handle = api.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        class Limits(ctypes.Structure):
            _fields_ = [('perProcess', ctypes.c_int64), ('perJob', ctypes.c_int64),
                        ('flags', w.DWORD), ('minimum', ctypes.c_size_t), ('maximum', ctypes.c_size_t),
                        ('activeLimit', w.DWORD), ('affinity', ctypes.c_size_t),
                        ('priority', w.DWORD), ('scheduling', w.DWORD)]
        class Counters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in ('readOperations', 'writeOperations', 'otherOperations', 'readBytes', 'writeBytes', 'otherBytes')]
        class Extended(ctypes.Structure):
            _fields_ = [('basic', Limits), ('io', Counters), ('processMemory', ctypes.c_size_t),
                        ('jobMemory', ctypes.c_size_t), ('peakProcess', ctypes.c_size_t), ('peakJob', ctypes.c_size_t)]
        limits = Extended()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not api.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def assign(self, process):
        if not self.api.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())

    def active(self):
        class Accounting(ctypes.Structure):
            _fields_ = [('user', ctypes.c_int64), ('kernel', ctypes.c_int64),
                        ('periodUser', ctypes.c_int64), ('periodKernel', ctypes.c_int64),
                        ('pageFaults', w.DWORD), ('total', w.DWORD), ('active', w.DWORD), ('terminated', w.DWORD)]
        accounting = Accounting()
        if not self.api.QueryInformationJobObject(self.handle, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None):
            raise ctypes.WinError(ctypes.get_last_error())
        return accounting.active

    def terminate(self):
        if not self.api.TerminateJobObject(self.handle, 124):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def child(command_file, gate):
    # Do not launch any producer before the supervisor has assigned this gated
    # process to its Job Object. Descendants then inherit membership atomically.
    start = time.monotonic()
    while not gate.is_file():
        if time.monotonic() - start > 60:
            return 125
        time.sleep(0.05)
    command = json.loads(command_file.read_text(encoding='utf-8-sig'))
    return subprocess.run(command).returncode


def supervise(args):
    root = Path(args.receipt_dir)
    root.mkdir(parents=True, exist_ok=True)
    command_file = Path(args.command_file).resolve()
    command = json.loads(command_file.read_text(encoding='utf-8-sig'))
    if not isinstance(command, list) or not command or not all(isinstance(x, str) for x in command):
        raise ValueError('Expected nonempty executable/argument string array')
    gate = root / 'producer-go'
    if gate.exists() or (root / 'producer-budget.json').exists():
        raise ValueError('Receipt directory already contains an execution; no retry')
    effective = float(args.budget_seconds)
    if args.deadline_utc:
        remaining = (datetime.fromisoformat(args.deadline_utc.replace('Z', '+00:00')) - datetime.now(timezone.utc)).total_seconds()
        effective = min(effective, remaining)
    receipt = {'schemaVersion': 1, 'status': 'RUNNING', 'startUtc': utc(), 'endUtc': None,
               'budgetSeconds': args.budget_seconds, 'effectiveBudgetSeconds': effective,
               'preservationDeadlineUtc': args.deadline_utc, 'producerExit': None,
               'supervisorExit': None, 'processTreeTerminated': False,
               'activeProcessesBeforeCleanup': None, 'activeProcessesAfterCleanup': None,
               'stdout': 'stdout.log', 'stderr': 'stderr.log', 'command': command,
               'sourceSha': os.environ.get('GITHUB_SHA'), 'runId': os.environ.get('GITHUB_RUN_ID')}
    path = root / 'producer-budget.json'
    atomic_json(path, receipt)
    process = None
    job = WindowsJob()
    try:
        with (root / 'stdout.log').open('wb') as stdout, (root / 'stderr.log').open('wb') as stderr:
            if effective <= 0:
                receipt['status'], receipt['supervisorExit'] = 'TIMEOUT', 124
            else:
                process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--child', '--command-file', str(command_file), '--gate', str(gate)], stdout=stdout, stderr=stderr)
                try:
                    job.assign(process)
                except Exception:
                    # The unassigned child has not passed its gate; it cannot
                    # own producer descendants and is safe to terminate alone.
                    process.kill()
                    process.wait(timeout=15)
                    raise
                gate.write_text('GO\n', encoding='ascii')
                deadline = time.monotonic() + effective
                heartbeat = 0
                while process.poll() is None:
                    if time.monotonic() >= deadline:
                        receipt['status'], receipt['supervisorExit'] = 'TIMEOUT', 124
                        break
                    if time.monotonic() >= heartbeat:
                        phase_file = root / 'phase-current.json'
                        phase = json.loads(phase_file.read_text(encoding='utf-8-sig')) if phase_file.is_file() else None
                        print('OPENCL_PRODUCER_PROGRESS=' + json.dumps({'utc': utc(), 'phase': phase}), flush=True)
                        heartbeat = time.monotonic() + 30
                    time.sleep(0.2)
                if receipt['status'] != 'TIMEOUT':
                    receipt['producerExit'] = process.returncode
                    receipt['supervisorExit'] = process.returncode
                    receipt['status'] = 'PASS' if process.returncode == 0 else 'FAIL'
    except Exception as error:
        receipt['status'], receipt['supervisorExit'] = 'FAIL', 125
        receipt['error'] = str(error)
    finally:
        try:
            receipt['activeProcessesBeforeCleanup'] = job.active()
            job.terminate()
            until = time.monotonic() + 15
            while job.active() and time.monotonic() < until:
                time.sleep(0.1)
            receipt['activeProcessesAfterCleanup'] = job.active()
            receipt['processTreeTerminated'] = receipt['activeProcessesAfterCleanup'] == 0
            if not receipt['processTreeTerminated']:
                receipt['status'], receipt['supervisorExit'] = 'FAIL', 125
            if process is not None:
                process.wait(timeout=15)
        except Exception as error:
            receipt['cleanupError'] = str(error)
            receipt['status'], receipt['supervisorExit'] = 'FAIL', 125
        finally:
            job.close()
        phase_file = root / 'phase-current.json'
        if phase_file.is_file():
            receipt['lastPhase'] = json.loads(phase_file.read_text(encoding='utf-8-sig'))
        receipt['endUtc'] = utc()
        atomic_json(path, receipt)
    print('OPENCL_PRODUCER_RESULT=' + receipt['status'], flush=True)
    return receipt['supervisorExit']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--command-file', required=True)
    parser.add_argument('--receipt-dir')
    parser.add_argument('--budget-seconds', type=int, default=19800)
    parser.add_argument('--deadline-utc')
    parser.add_argument('--child', action='store_true')
    parser.add_argument('--gate')
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('Windows Job Object supervision requires Windows')
    if args.child:
        return child(Path(args.command_file), Path(args.gate))
    if not args.receipt_dir or args.budget_seconds <= 0:
        parser.error('Positive budget and receipt directory required')
    return supervise(args)

if __name__ == '__main__':
    sys.exit(main())
