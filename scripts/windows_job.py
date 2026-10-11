"""Windows process-tree ownership for the bounded verification companion."""

from __future__ import annotations

import ctypes
import os
import subprocess
import time
from ctypes import wintypes


JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9
JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION = 1
CREATE_SUSPENDED = 0x00000004
CREATE_UNICODE_ENVIRONMENT = 0x00000400
EXTENDED_STARTUPINFO_PRESENT = 0x00080000
WAIT_OBJECT_0 = 0
WAIT_TIMEOUT = 258
WAIT_FAILED = 0xFFFFFFFF
INFINITE = 0xFFFFFFFF


class BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_longlong),
        ("PerJobUserTimeLimit", ctypes.c_longlong),
        ("LimitFlags", wintypes.DWORD),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", wintypes.DWORD),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", wintypes.DWORD),
        ("SchedulingClass", wintypes.DWORD),
    ]


class IO_COUNTERS(ctypes.Structure):
    _fields_ = [
        ("ReadOperationCount", ctypes.c_ulonglong),
        ("WriteOperationCount", ctypes.c_ulonglong),
        ("OtherOperationCount", ctypes.c_ulonglong),
        ("ReadTransferCount", ctypes.c_ulonglong),
        ("WriteTransferCount", ctypes.c_ulonglong),
        ("OtherTransferCount", ctypes.c_ulonglong),
    ]


class EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", BASIC_LIMIT_INFORMATION),
        ("IoInfo", IO_COUNTERS),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


class BASIC_ACCOUNTING_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("TotalUserTime", ctypes.c_longlong),
        ("TotalKernelTime", ctypes.c_longlong),
        ("ThisPeriodTotalUserTime", ctypes.c_longlong),
        ("ThisPeriodTotalKernelTime", ctypes.c_longlong),
        ("TotalPageFaults", wintypes.DWORD),
        ("TotalProcesses", wintypes.DWORD),
        ("ActiveProcesses", wintypes.DWORD),
        ("TotalTerminatedProcesses", wintypes.DWORD),
    ]


class WindowsJobProcess:
    """Launch one suspended command and own it plus all descendants in a job."""

    def __init__(self, argv, cwd, env, output_stream):
        if os.name != "nt":
            raise OSError("WindowsJobProcess is available only on Windows")

        import _winapi
        import msvcrt

        self._winapi = _winapi
        self._kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self._configure_kernel()
        self.argv = list(argv)
        self.pid = None
        self.returncode = None
        self._process = None
        self._job = None
        self._closed = False

        job = self._kernel.CreateJobObjectW(None, None)
        if not job:
            raise ctypes.WinError(ctypes.get_last_error(), "CreateJobObjectW failed")

        input_handle = None
        input_was_inheritable = None
        output_handle = None
        output_was_inheritable = None
        process_handle = None
        thread_handle = None
        assigned = False
        try:
            output_handle = msvcrt.get_osfhandle(output_stream.fileno())
            output_was_inheritable = os.get_handle_inheritable(output_handle)
            limits = EXTENDED_LIMIT_INFORMATION()
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if not self._kernel.SetInformationJobObject(
                job,
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
                ctypes.byref(limits),
                ctypes.sizeof(limits),
            ):
                raise ctypes.WinError(
                    ctypes.get_last_error(), "SetInformationJobObject failed"
                )

            input_handle = _winapi.CreateFile(
                "NUL",
                0x80000000,  # GENERIC_READ
                0x00000001 | 0x00000002,  # FILE_SHARE_READ | FILE_SHARE_WRITE
                0,
                3,  # OPEN_EXISTING
                0x00000080,  # FILE_ATTRIBUTE_NORMAL
                0,
            )
            input_was_inheritable = os.get_handle_inheritable(input_handle)
            os.set_handle_inheritable(input_handle, True)
            os.set_handle_inheritable(output_handle, True)

            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= 0x00000100  # STARTF_USESTDHANDLES
            startup.hStdInput = input_handle
            startup.hStdOutput = output_handle
            startup.hStdError = output_handle
            # _winapi turns this list into PROC_THREAD_ATTRIBUTE_HANDLE_LIST.
            startup.lpAttributeList = {"handle_list": [input_handle, output_handle]}
            flags = (
                CREATE_SUSPENDED
                | CREATE_UNICODE_ENVIRONMENT
                | EXTENDED_STARTUPINFO_PRESENT
            )
            process_handle, thread_handle, pid, _thread_id = _winapi.CreateProcess(
                None,
                subprocess.list2cmdline(self.argv),
                None,
                None,
                True,
                flags,
                env,
                os.fspath(cwd) if cwd is not None else None,
                startup,
            )

            # The child inherited duplicates of these handles. Restore the
            # parent copies before assignment/resume so they cannot leak into
            # a later unrelated process launched by this Python process.
            os.set_handle_inheritable(input_handle, input_was_inheritable)
            input_was_inheritable = None
            _winapi.CloseHandle(input_handle)
            input_handle = None
            os.set_handle_inheritable(output_handle, output_was_inheritable)
            output_was_inheritable = None

            # The primary thread is still suspended, so it cannot create a
            # descendant before this process is owned by the kill-on-close job.
            if not self._kernel.AssignProcessToJobObject(job, process_handle):
                error = ctypes.get_last_error()
                self._abort_suspended(process_handle, None)
                process_handle = None
                raise ctypes.WinError(
                    error,
                    "AssignProcessToJobObject failed; refusing an unowned process",
                )
            assigned = True

            if self._kernel.ResumeThread(thread_handle) == 0xFFFFFFFF:
                error = ctypes.get_last_error()
                self._abort_suspended(process_handle, job)
                process_handle = None
                raise ctypes.WinError(error, "ResumeThread failed")

            _winapi.CloseHandle(thread_handle)
            thread_handle = None
            self._process = process_handle
            self._job = job
            self.pid = pid
            process_handle = None
            job = None
        except BaseException:
            if process_handle is not None:
                self._abort_suspended(process_handle, job if assigned else None)
            raise
        finally:
            try:
                if thread_handle is not None:
                    _winapi.CloseHandle(thread_handle)
            finally:
                try:
                    if process_handle is not None:
                        _winapi.CloseHandle(process_handle)
                finally:
                    try:
                        if input_handle is not None:
                            try:
                                if input_was_inheritable is not None:
                                    os.set_handle_inheritable(
                                        input_handle, input_was_inheritable
                                    )
                            finally:
                                _winapi.CloseHandle(input_handle)
                    finally:
                        try:
                            if (
                                output_handle is not None
                                and output_was_inheritable is not None
                            ):
                                os.set_handle_inheritable(
                                    output_handle, output_was_inheritable
                                )
                        finally:
                            if job is not None:
                                self._kernel.CloseHandle(job)

    def _configure_kernel(self):
        kernel = self._kernel
        kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        kernel.CreateJobObjectW.restype = wintypes.HANDLE
        kernel.SetInformationJobObject.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
        ]
        kernel.SetInformationJobObject.restype = wintypes.BOOL
        kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        kernel.AssignProcessToJobObject.restype = wintypes.BOOL
        kernel.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        kernel.TerminateJobObject.restype = wintypes.BOOL
        kernel.QueryInformationJobObject.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
            ctypes.c_void_p,
        ]
        kernel.QueryInformationJobObject.restype = wintypes.BOOL
        kernel.ResumeThread.argtypes = [wintypes.HANDLE]
        kernel.ResumeThread.restype = wintypes.DWORD
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL

    def _active_processes_in(self, job):
        accounting = BASIC_ACCOUNTING_INFORMATION()
        if not self._kernel.QueryInformationJobObject(
            job,
            JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION,
            ctypes.byref(accounting),
            ctypes.sizeof(accounting),
            None,
        ):
            raise ctypes.WinError(
                ctypes.get_last_error(), "QueryInformationJobObject failed"
            )
        return accounting.ActiveProcesses

    def _active_processes(self):
        return self._active_processes_in(self._job)

    def _abort_suspended(self, process_handle, job_handle):
        if job_handle is not None:
            self._kernel.TerminateJobObject(job_handle, 1)
        else:
            self._winapi.TerminateProcess(process_handle, 1)
        result = self._winapi.WaitForSingleObject(process_handle, 5000)
        if result != WAIT_OBJECT_0:
            raise OSError("could not wait for a failed suspended process launch")
        if job_handle is not None:
            deadline = time.monotonic() + 5
            while self._active_processes_in(job_handle) != 0:
                if time.monotonic() >= deadline:
                    raise TimeoutError(
                        "failed Windows process launch left owned descendants alive"
                    )
                time.sleep(0.01)

    def poll(self):
        if self.returncode is not None:
            return self.returncode
        result = self._winapi.WaitForSingleObject(self._process, 0)
        if result == WAIT_TIMEOUT:
            return None
        if result == WAIT_FAILED:
            raise ctypes.WinError(ctypes.get_last_error(), "process poll failed")
        if result != WAIT_OBJECT_0:
            raise OSError(f"unexpected process wait result: {result}")
        self.returncode = self._winapi.GetExitCodeProcess(self._process)
        return self.returncode

    def wait(self, timeout=None):
        if self.returncode is not None:
            return self.returncode
        if timeout is None:
            milliseconds = INFINITE
        else:
            milliseconds = max(0, min(INFINITE - 1, int(timeout * 1000 + 0.999)))
        result = self._winapi.WaitForSingleObject(self._process, milliseconds)
        if result == WAIT_TIMEOUT:
            raise subprocess.TimeoutExpired(self.argv, timeout)
        if result == WAIT_FAILED:
            raise ctypes.WinError(ctypes.get_last_error(), "process wait failed")
        if result != WAIT_OBJECT_0:
            raise OSError(f"unexpected process wait result: {result}")
        self.returncode = self._winapi.GetExitCodeProcess(self._process)
        return self.returncode

    def kill(self):
        if self._job is None:
            return
        if not self._kernel.TerminateJobObject(self._job, 1):
            # A concurrently completed job is already fully terminated.
            if self._active_processes() != 0:
                raise ctypes.WinError(
                    ctypes.get_last_error(), "TerminateJobObject failed"
                )

    def wait_for_job(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            if self._active_processes() == 0:
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("owned Windows process descendants did not exit")
            time.sleep(min(0.01, remaining))

    def close(self):
        if self._closed:
            return
        failure = None
        try:
            self.kill()
            if self._job is not None:
                self.wait_for_job(5)
        except BaseException as exc:
            failure = exc
        finally:
            if self._job is not None:
                self._kernel.CloseHandle(self._job)
                self._job = None
            if self._process is not None:
                self._winapi.CloseHandle(self._process)
                self._process = None
            self._closed = True
        if failure is not None:
            raise failure
