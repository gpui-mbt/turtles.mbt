/* Windows-only scoped process ownership for the turtles CLI. */

#ifdef _WIN32

#include <windows.h>
#include <moonbit.h>
#include <stddef.h>
#include <stdlib.h>
#include <wchar.h>

typedef struct turtles_windows_process {
  HANDLE job;
  HANDLE process;
  DWORD pid;
  HANDLE *members;
  DWORD member_count;
  int members_captured;
} turtles_windows_process;

static __declspec(thread) DWORD turtles_windows_last_error = ERROR_SUCCESS;

static void set_last_error(DWORD error) {
  turtles_windows_last_error = error;
}

static int32_t query_active_processes(HANDLE job, DWORD *active) {
  JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
  if (!QueryInformationJobObject(
        job,
        JobObjectBasicAccountingInformation,
        &info,
        sizeof(info),
        NULL)) {
    set_last_error(GetLastError());
    return -1;
  }
  *active = info.ActiveProcesses;
  set_last_error(ERROR_SUCCESS);
  return 0;
}

static int capture_job_members(turtles_windows_process *process) {
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
  JOBOBJECT_BASIC_PROCESS_ID_LIST *process_ids = NULL;
  SIZE_T base_size = offsetof(JOBOBJECT_BASIC_PROCESS_ID_LIST, ProcessIdList);
  SIZE_T capacity = 8;
  SIZE_T buffer_size = 0;
  DWORD error = ERROR_SUCCESS;

  if (process->members_captured)
    return 0;

  /*
   * Stop job members from admitting more processes before taking the PID
   * snapshot. Existing members may exceed this limit; Windows applies the
   * limit to future process association attempts.
   */
  if (!QueryInformationJobObject(
        process->job,
        JobObjectExtendedLimitInformation,
        &limits,
        sizeof(limits),
        NULL)) {
    set_last_error(GetLastError());
    return -1;
  }
  limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
  limits.BasicLimitInformation.ActiveProcessLimit = 1;
  if (!SetInformationJobObject(
        process->job,
        JobObjectExtendedLimitInformation,
        &limits,
        sizeof(limits))) {
    set_last_error(GetLastError());
    return -1;
  }

  for (;;) {
    if (capacity > ((SIZE_T)-1 - base_size) / sizeof(ULONG_PTR)) {
      set_last_error(ERROR_NOT_ENOUGH_MEMORY);
      return -1;
    }
    buffer_size = base_size + capacity * sizeof(ULONG_PTR);
    process_ids = (JOBOBJECT_BASIC_PROCESS_ID_LIST *)HeapAlloc(
      GetProcessHeap(), HEAP_ZERO_MEMORY, buffer_size);
    if (!process_ids) {
      set_last_error(ERROR_NOT_ENOUGH_MEMORY);
      return -1;
    }
    if (!QueryInformationJobObject(
          process->job,
          JobObjectBasicProcessIdList,
          process_ids,
          (DWORD)buffer_size,
          NULL)) {
      error = GetLastError();
      HeapFree(GetProcessHeap(), 0, process_ids);
      process_ids = NULL;
      if (error != ERROR_MORE_DATA) {
        set_last_error(error);
        return -1;
      }
      if (capacity > ((SIZE_T)-1) / 2) {
        set_last_error(ERROR_NOT_ENOUGH_MEMORY);
        return -1;
      }
      capacity *= 2;
      continue;
    }
    if (process_ids->NumberOfProcessIdsInList <
        process_ids->NumberOfAssignedProcesses) {
      SIZE_T required = process_ids->NumberOfAssignedProcesses;
      HeapFree(GetProcessHeap(), 0, process_ids);
      process_ids = NULL;
      if (required <= capacity) {
        if (capacity > ((SIZE_T)-1) / 2) {
          set_last_error(ERROR_NOT_ENOUGH_MEMORY);
          return -1;
        }
        required = capacity * 2;
      }
      capacity = required;
      continue;
    }
    break;
  }

  if (process_ids->NumberOfProcessIdsInList > 0) {
    process->members = (HANDLE *)HeapAlloc(
      GetProcessHeap(),
      HEAP_ZERO_MEMORY,
      process_ids->NumberOfProcessIdsInList * sizeof(HANDLE));
    if (!process->members) {
      HeapFree(GetProcessHeap(), 0, process_ids);
      set_last_error(ERROR_NOT_ENOUGH_MEMORY);
      return -1;
    }
  }

  for (DWORD i = 0; i < process_ids->NumberOfProcessIdsInList; i++) {
    DWORD pid = (DWORD)process_ids->ProcessIdList[i];
    HANDLE member;
    BOOL in_job = FALSE;
    DWORD wait_status;

    if (pid == 0 || pid == process->pid)
      continue;
    member = OpenProcess(
      SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
      FALSE,
      pid);
    if (!member) {
      error = GetLastError();
      /* A listed process may have exited while the snapshot was opened. */
      if (error == ERROR_INVALID_PARAMETER)
        continue;
      HeapFree(GetProcessHeap(), 0, process_ids);
      set_last_error(error);
      return -1;
    }
    if (!IsProcessInJob(member, process->job, &in_job)) {
      error = GetLastError();
      CloseHandle(member);
      HeapFree(GetProcessHeap(), 0, process_ids);
      set_last_error(error);
      return -1;
    }
    if (!in_job) {
      wait_status = WaitForSingleObject(member, 0);
      CloseHandle(member);
      if (wait_status == WAIT_OBJECT_0)
        continue;
      HeapFree(GetProcessHeap(), 0, process_ids);
      set_last_error(
        wait_status == WAIT_FAILED ? GetLastError() : ERROR_INVALID_DATA);
      return -1;
    }
    process->members[process->member_count++] = member;
  }

  HeapFree(GetProcessHeap(), 0, process_ids);
  process->members_captured = 1;
  set_last_error(ERROR_SUCCESS);
  return 0;
}

static int members_have_exited(turtles_windows_process *process) {
  DWORD status = WaitForSingleObject(process->process, 0);
  if (status == WAIT_TIMEOUT)
    return 0;
  if (status == WAIT_FAILED) {
    set_last_error(GetLastError());
    return -1;
  }
  if (status != WAIT_OBJECT_0) {
    set_last_error(ERROR_GEN_FAILURE);
    return -1;
  }
  for (DWORD i = 0; i < process->member_count; i++) {
    status = WaitForSingleObject(process->members[i], 0);
    if (status == WAIT_TIMEOUT)
      return 0;
    if (status == WAIT_FAILED) {
      set_last_error(GetLastError());
      return -1;
    }
    if (status != WAIT_OBJECT_0) {
      set_last_error(ERROR_GEN_FAILURE);
      return -1;
    }
  }
  set_last_error(ERROR_SUCCESS);
  return 1;
}

static void close_if_valid(HANDLE handle) {
  if (handle && handle != INVALID_HANDLE_VALUE)
    CloseHandle(handle);
}

MOONBIT_FFI_EXPORT
void *turtles_windows_spawn_scoped_process(
  moonbit_string_t command_line,
  moonbit_string_t working_directory,
  moonbit_string_t output_path
) {
  HANDLE job = NULL;
  HANDLE output = INVALID_HANDLE_VALUE;
  HANDLE input = INVALID_HANDLE_VALUE;
  LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
  SIZE_T attributes_size = 0;
  BOOL attributes_initialized = FALSE;
  PROCESS_INFORMATION process_info;
  STARTUPINFOEXW startup;
  LPWSTR mutable_command_line = NULL;
  HANDLE inherited_handles[2] = { NULL, NULL };
  turtles_windows_process *result = NULL;
  DWORD error = ERROR_SUCCESS;
  SECURITY_ATTRIBUTES inheritable = {
    sizeof(SECURITY_ATTRIBUTES), NULL, TRUE
  };
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;

  ZeroMemory(&process_info, sizeof(process_info));
  ZeroMemory(&startup, sizeof(startup));
  ZeroMemory(&limits, sizeof(limits));

  job = CreateJobObjectW(NULL, NULL);
  if (!job) {
    error = GetLastError();
    goto fail;
  }
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(
        job,
        JobObjectExtendedLimitInformation,
        &limits,
        sizeof(limits))) {
    error = GetLastError();
    goto fail;
  }

  output = CreateFileW(
    (LPWSTR)output_path,
    GENERIC_WRITE,
    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    &inheritable,
    CREATE_ALWAYS,
    FILE_ATTRIBUTE_NORMAL,
    NULL);
  if (output == INVALID_HANDLE_VALUE) {
    error = GetLastError();
    goto fail;
  }
  input = CreateFileW(
    L"NUL",
    GENERIC_READ,
    FILE_SHARE_READ | FILE_SHARE_WRITE,
    &inheritable,
    OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL,
    NULL);
  if (input == INVALID_HANDLE_VALUE) {
    error = GetLastError();
    goto fail;
  }

  InitializeProcThreadAttributeList(NULL, 1, 0, &attributes_size);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
    error = GetLastError();
    goto fail;
  }
  attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(
    GetProcessHeap(), 0, attributes_size);
  if (!attributes) {
    error = ERROR_NOT_ENOUGH_MEMORY;
    goto fail;
  }
  if (!InitializeProcThreadAttributeList(attributes, 1, 0, &attributes_size)) {
    error = GetLastError();
    goto fail;
  }
  attributes_initialized = TRUE;
  inherited_handles[0] = input;
  inherited_handles[1] = output;
  if (!UpdateProcThreadAttribute(
        attributes,
        0,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        inherited_handles,
        sizeof(inherited_handles),
        NULL,
        NULL)) {
    error = GetLastError();
    goto fail;
  }

  mutable_command_line = _wcsdup(command_line);
  if (!mutable_command_line) {
    error = ERROR_NOT_ENOUGH_MEMORY;
    goto fail;
  }
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = input;
  startup.StartupInfo.hStdOutput = output;
  startup.StartupInfo.hStdError = output;
  startup.lpAttributeList = attributes;

  if (!CreateProcessW(
        NULL,
        mutable_command_line,
        NULL,
        NULL,
        TRUE,
        CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT |
          CREATE_UNICODE_ENVIRONMENT,
        NULL,
        (LPWSTR)working_directory,
        &startup.StartupInfo,
        &process_info)) {
    error = GetLastError();
    goto fail;
  }

  /* The suspended process cannot create descendants before job assignment. */
  if (!AssignProcessToJobObject(job, process_info.hProcess)) {
    error = GetLastError();
    TerminateProcess(process_info.hProcess, 1);
    WaitForSingleObject(process_info.hProcess, 5000);
    goto fail;
  }
  if (ResumeThread(process_info.hThread) == (DWORD)-1) {
    error = GetLastError();
    TerminateJobObject(job, 1);
    WaitForSingleObject(process_info.hProcess, 5000);
    goto fail;
  }

  result = (turtles_windows_process *)malloc(sizeof(*result));
  if (!result) {
    error = ERROR_NOT_ENOUGH_MEMORY;
    TerminateJobObject(job, 1);
    WaitForSingleObject(process_info.hProcess, 5000);
    goto fail;
  }
  result->job = job;
  result->process = process_info.hProcess;
  result->pid = process_info.dwProcessId;
  result->members = NULL;
  result->member_count = 0;
  result->members_captured = 0;
  job = NULL;
  process_info.hProcess = NULL;
  set_last_error(ERROR_SUCCESS);
  goto cleanup;

fail:
  set_last_error(error ? error : ERROR_GEN_FAILURE);
  if (process_info.hProcess) {
    /* A process created suspended but not yet assigned must not escape. */
    TerminateProcess(process_info.hProcess, 1);
    WaitForSingleObject(process_info.hProcess, 5000);
  }
  free(result);

cleanup:
  if (process_info.hThread)
    CloseHandle(process_info.hThread);
  close_if_valid(process_info.hProcess);
  close_if_valid(input);
  close_if_valid(output);
  if (attributes) {
    if (attributes_initialized)
      DeleteProcThreadAttributeList(attributes);
    HeapFree(GetProcessHeap(), 0, attributes);
  }
  free(mutable_command_line);
  close_if_valid(job);
  return result;
}

MOONBIT_FFI_EXPORT
int32_t turtles_windows_process_is_null(void *opaque) {
  return opaque == NULL;
}

MOONBIT_FFI_EXPORT
int32_t turtles_windows_process_is_exited(void *opaque) {
  turtles_windows_process *process = (turtles_windows_process *)opaque;
  DWORD status = WaitForSingleObject(process->process, 0);
  if (status == WAIT_OBJECT_0) {
    set_last_error(ERROR_SUCCESS);
    return 1;
  }
  if (status == WAIT_TIMEOUT) {
    set_last_error(ERROR_SUCCESS);
    return 0;
  }
  set_last_error(status == WAIT_FAILED ? GetLastError() : ERROR_GEN_FAILURE);
  return -1;
}

MOONBIT_FFI_EXPORT
int32_t turtles_windows_process_exit_code(void *opaque) {
  turtles_windows_process *process = (turtles_windows_process *)opaque;
  DWORD code = 0;
  if (!GetExitCodeProcess(process->process, &code)) {
    set_last_error(GetLastError());
    return 0;
  }
  set_last_error(ERROR_SUCCESS);
  return (int32_t)code;
}

MOONBIT_FFI_EXPORT
int32_t turtles_windows_job_active_processes(void *opaque) {
  turtles_windows_process *process = (turtles_windows_process *)opaque;
  DWORD active = 0;
  if (query_active_processes(process->job, &active) < 0)
    return -1;
  return (int32_t)active;
}

MOONBIT_FFI_EXPORT
int32_t turtles_windows_job_terminate(void *opaque) {
  turtles_windows_process *process = (turtles_windows_process *)opaque;
  int capture_status = capture_job_members(process);
  DWORD capture_error = capture_status < 0 ? turtles_windows_last_error : ERROR_SUCCESS;
  if (!TerminateJobObject(process->job, 1) && capture_error == ERROR_SUCCESS)
    capture_error = GetLastError();
  if (capture_error != ERROR_SUCCESS) {
    set_last_error(capture_error);
    return -1;
  }
  set_last_error(ERROR_SUCCESS);
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t turtles_windows_job_members_exited(void *opaque) {
  turtles_windows_process *process = (turtles_windows_process *)opaque;
  if (!process->members_captured) {
    set_last_error(ERROR_INVALID_STATE);
    return -1;
  }
  return members_have_exited(process);
}

MOONBIT_FFI_EXPORT
int32_t turtles_windows_process_close(void *opaque) {
  turtles_windows_process *process = (turtles_windows_process *)opaque;
  DWORD active = 0;
  DWORD error = ERROR_SUCCESS;
  int members_exited = 1;
  if (!process)
    return 0;
  if (process->members_captured) {
    members_exited = members_have_exited(process);
    if (members_exited != 1) {
      error = members_exited < 0 ? turtles_windows_last_error : ERROR_PROCESS_ABORTED;
      TerminateJobObject(process->job, 1);
    }
  } else {
    if (query_active_processes(process->job, &active) < 0) {
      error = turtles_windows_last_error;
      TerminateJobObject(process->job, 1);
    } else if (active > 0) {
      error = ERROR_PROCESS_ABORTED;
      TerminateJobObject(process->job, 1);
    }
  }
  if (!CloseHandle(process->process) && error == ERROR_SUCCESS)
    error = GetLastError();
  for (DWORD i = 0; i < process->member_count; i++) {
    if (!CloseHandle(process->members[i]) && error == ERROR_SUCCESS)
      error = GetLastError();
  }
  if (process->members)
    HeapFree(GetProcessHeap(), 0, process->members);
  /* Closing the final job handle is the last-resort tree-kill guarantee. */
  if (!CloseHandle(process->job) && error == ERROR_SUCCESS)
    error = GetLastError();
  free(process);
  set_last_error(error);
  return error == ERROR_SUCCESS ? 0 : -1;
}

MOONBIT_FFI_EXPORT
int32_t turtles_windows_process_last_error(void) {
  return (int32_t)turtles_windows_last_error;
}

#endif
