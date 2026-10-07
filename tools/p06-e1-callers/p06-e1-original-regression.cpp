// Original public export regression. No reopen helper or rights amplification.
#include "common.hpp"
#include <d3dkmthk.h>
#include <io.h>
#include <fcntl.h>
using namespace p06;

static std::string run_id, output_dir;
constexpr ACCESS_MASK native_read = SECTION_MAP_READ;
constexpr ACCESS_MASK native_query = SECTION_QUERY;
constexpr uint32_t sentinel = 0xa5a5a5a5u;
static_assert(native_read == 0x4 && native_query == 0x1, "Native Section rights");
static_assert(sizeof(PUBLIC_OBJECT_BASIC_INFORMATION) == 56, "Public basic object ABI");
static_assert(offsetof(PUBLIC_OBJECT_BASIC_INFORMATION, GrantedAccess) == 4, "Access offset");
static_assert(sizeof(OBJECT_ATTRIBUTES) == (sizeof(void*) == 8 ? 48 : 24), "Native OA ABI");
static_assert(sizeof(UNICODE_STRING) == (sizeof(void*) == 8 ? 16 : 8), "Native name ABI");

static void phase(const char* name) {
    printf("DIAG RUN_ID=%s PID=%lu PHASE=%s\n", run_id.c_str(), GetCurrentProcessId(), name);
}
static std::string artifact(const std::string& label) {
    return output_dir + "\\" + run_id + "-pid-" + std::to_string(GetCurrentProcessId()) + "-" + label;
}
static void save_raw(const std::string& label, const void* data, DWORD size) {
    auto path = artifact(label);
    Handle file(CreateFileA(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                            CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
    require(file.h != INVALID_HANDLE_VALUE, "Refuse missing/overwritten raw evidence");
    write_exact(file.h, data, size);
    require(FlushFileBuffers(file.h) != 0, "Raw evidence flush");
    printf("RAW RUN_ID=%s PID=%lu PATH=%s BYTES=%lu\n", run_id.c_str(),
           GetCurrentProcessId(), path.c_str(), size);
}
// Redirect before process_evidence: producer and consumer never share a stdout file.
static void consumer_logs() {
    for (bool err : {false, true}) {
        auto path = artifact(err ? "consumer.stderr.txt" : "consumer.stdout.txt");
        HANDLE raw = CreateFileA(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        require(raw != INVALID_HANDLE_VALUE, "Create unique consumer log");
        int fd = _open_osfhandle((intptr_t)raw, _O_WRONLY | _O_BINARY);
        if (fd == -1) { CloseHandle(raw); throw std::runtime_error("Consumer log fd"); }
        FILE* stream = err ? stderr : stdout;
        int ok = _dup2(fd, _fileno(stream));
        _close(fd);
        require(ok == 0, "Redirect consumer stream");
        require(SetStdHandle(err ? STD_ERROR_HANDLE : STD_OUTPUT_HANDLE,
                             (HANDLE)_get_osfhandle(_fileno(stream))) != 0,
                "Set consumer standard handle");
    }
}
using NtQuery = LONG(NTAPI*)(HANDLE, ULONG, PVOID, ULONG, PULONG);
static NtQuery query_function() {
    auto fn = (NtQuery)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryObject");
    require(fn != nullptr, "NtQueryObject export");
    return fn;
}
static std::wstring object_type(HANDLE h) {
    alignas(8) unsigned char raw[4096];
    memset(raw, 0xa5, sizeof(raw));
    ULONG returned = 0;
    LONG status = query_function()(h, 2, raw, sizeof(raw), &returned);
    printf("TYPE_QUERY PID=%lu HANDLE=%p NTSTATUS=%08lx RETURN_LENGTH=%lu\n",
           GetCurrentProcessId(), h, (unsigned long)status, returned);
    require(status == 0, "ObjectTypeInformation failed");
    auto info = (PUBLIC_OBJECT_TYPE_INFORMATION*)raw;
    auto begin = (uintptr_t)info->TypeName.Buffer;
    auto end = begin + info->TypeName.Length;
    require(info->TypeName.Length % 2 == 0 && begin >= (uintptr_t)raw &&
            end >= begin && end <= (uintptr_t)raw + sizeof(raw), "Object type string bounds");
    return std::wstring(info->TypeName.Buffer, info->TypeName.Length / 2);
}
struct Measurement {
    ACCESS_MASK access;
    Record record;
    std::wstring name;
};
static Measurement measure(HANDLE h, const char* label) {
    phase(label);
    PUBLIC_OBJECT_BASIC_INFORMATION basic;
    memset(&basic, 0xa5, sizeof(basic));
    ULONG returned = 0;
    LONG status = query_function()(h, 0, &basic, sizeof(basic), &returned);
    printf("BASIC RUN_ID=%s PID=%lu PHASE=%s HANDLE=%p NTSTATUS=%08lx RETURN_LENGTH=%lu\n",
           run_id.c_str(), GetCurrentProcessId(), label, h, (unsigned long)status, returned);
    save_raw(std::string(label) + "-basic.bin", &basic, sizeof(basic));
    require(status == 0 && returned == sizeof(basic), "ObjectBasicInformation not observed");
    printf("GRANTED_ACCESS RUN_ID=%s PID=%lu PHASE=%s HANDLE=%p MASK=%08lx HANDLE_COUNT=%lu POINTER_COUNT=%lu\n",
           run_id.c_str(), GetCurrentProcessId(), label, h, basic.GrantedAccess,
           basic.HandleCount, basic.PointerCount);
    auto type = object_type(h);
    require(type == L"Section", "Genuine carrier must be Section");
    Measurement m{basic.GrantedAccess, {}, object_name(h)};
    snapshot(h, m.record, true);
    printf("OBJECT RUN_ID=%s PID=%lu PHASE=%s HANDLE=%p TYPE=%s NAME=%s ID=%s VERSION=%u\n",
           run_id.c_str(), GetCurrentProcessId(), label, h, utf8(type).c_str(),
           utf8(m.name).c_str(), hex(m.record.carrier_id, 16).c_str(), m.record.version);
    return m;
}
static void same_object(HANDLE a, HANDLE b, const char* label) {
    using Compare = BOOL(WINAPI*)(HANDLE, HANDLE);
    auto fn = (Compare)GetProcAddress(GetModuleHandleW(L"kernelbase.dll"), "CompareObjectHandles");
    require(fn != nullptr, "CompareObjectHandles unavailable");
    SetLastError(0);
    BOOL same = fn(a, b);
    DWORD error = GetLastError();
    printf("SAME_OBJECT RUN_ID=%s PID=%lu PHASE=%s A=%p B=%p SAME=%d WIN32_ERROR=%lu\n",
           run_id.c_str(), GetCurrentProcessId(), label, a, b, int(same), error);
    require(same != 0, "Comparison handles refer to different objects");
}
static void same_record(const Measurement& a, const Measurement& b) {
    require(a.name == b.name && memcmp(&a.record, &b.record, sizeof(Record)) == 0,
            "Controlled handle changed record/name");
}
static const char* classification(uint32_t status) {
    static const char* names[] = {"SUCCESS", "INVALID_HANDLE", "WRONG_TYPE", "WRONG_NAME",
        "CARRIER_ID_MISMATCH", "WRONG_OWNER", "WRONG_DACL", "UNSUPPORTED_VERSION"};
    return status < 8 ? names[status] : "UNKNOWN_PROTOCOL_VALUE";
}
struct AttestResult {
    LONG external;
    uint32_t returned;
    bool observed;
    bool passed() const { return external == 0 && observed && returned == 0; }
};
struct KmtDiagnostic {
    HMODULE gdi = nullptr;
    D3DKMT_HANDLE adapter = 0, device = 0;
    PFND3DKMT_ESCAPE escape_fn = nullptr;
    void open(const Vulkan& v) {
        require(v.id.deviceLUIDValid != 0, "Selected Vulkan LUID unavailable");
        gdi = LoadLibraryW(L"gdi32.dll");
        require(gdi != nullptr, "Load gdi32");
        auto open_fn = (PFND3DKMT_OPENADAPTERFROMLUID)GetProcAddress(gdi, "D3DKMTOpenAdapterFromLuid");
        auto create_fn = (PFND3DKMT_CREATEDEVICE)GetProcAddress(gdi, "D3DKMTCreateDevice");
        escape_fn = (PFND3DKMT_ESCAPE)GetProcAddress(gdi, "D3DKMTEscape");
        require(open_fn && create_fn && escape_fn, "KMT functions absent");
        D3DKMT_OPENADAPTERFROMLUID a{};
        memcpy(&a.AdapterLuid, v.id.deviceLUID, 8);
        LONG status = open_fn(&a);
        printf("KMT_OPEN PID=%lu LUID=%s NTSTATUS=%08lx\n", GetCurrentProcessId(),
               hex(v.id.deviceLUID, 8).c_str(), (unsigned long)status);
        require(status == 0, "Open selected KMT adapter");
        adapter = a.hAdapter;
        D3DKMT_CREATEDEVICE d{}; d.hAdapter = adapter;
        status = create_fn(&d);
        printf("KMT_CREATE PID=%lu NTSTATUS=%08lx ADAPTER=%08x DEVICE=%08x\n",
               GetCurrentProcessId(), (unsigned long)status, adapter, d.hDevice);
        require(status == 0, "Create KMT device");
        device = d.hDevice;
    }
    AttestResult attest(HANDLE h, const Measurement& m, const char* label) {
        phase(label);
        CarrierRequest request{};
        init(request, 9);
        memcpy(request.carrier_id, m.record.carrier_id, 16);
        request.expected_record_version = 2;
        request.user_handle = (uint64_t)(uintptr_t)h;
        request.status = sentinel;
        CarrierRequest before = request;
        save_raw(std::string(label) + "-attest-before.bin", &request, sizeof(request));
        D3DKMT_ESCAPE escape{};
        escape.hAdapter = adapter; escape.hDevice = device;
        escape.Type = D3DKMT_ESCAPE_DRIVERPRIVATE;
        escape.pPrivateDriverData = &request; escape.PrivateDriverDataSize = sizeof(request);
        LONG status = escape_fn(&escape);
        save_raw(std::string(label) + "-attest-after.bin", &request, sizeof(request));
        bool observed = request.status != sentinel && request.status <= 7;
        printf("ATTEST RUN_ID=%s PID=%lu PHASE=%s HANDLE=%p ID=%s EXPECTED_VERSION=2 SIZE=%zu EXTERNAL_NTSTATUS=%08lx STATUS_BEFORE=%08x STATUS_AFTER=%08x BUFFER_CHANGED=%d ATTEST_CLASSIFICATION=%s GENERATION_SLOT=UNUSED_ZERO_FIELDS\n",
               run_id.c_str(), GetCurrentProcessId(), label, h, hex(m.record.carrier_id, 16).c_str(),
               sizeof(request), (unsigned long)status, before.status, request.status,
               int(memcmp(&before, &request, sizeof(request)) != 0),
               observed ? classification(request.status) : "NOT_OBSERVED");
        return {status, request.status, observed};
    }
    ~KmtDiagnostic() {
        if (device) {
            D3DKMT_DESTROYDEVICE d{}; d.hDevice = device;
            auto fn = (PFND3DKMT_DESTROYDEVICE)GetProcAddress(gdi, "D3DKMTDestroyDevice");
            LONG status = fn(&d);
            printf("KMT_DESTROY PID=%lu NTSTATUS=%08lx\n", GetCurrentProcessId(), (unsigned long)status);
            cleanup_ok &= status == 0;
        }
        if (adapter) {
            D3DKMT_CLOSEADAPTER a{}; a.hAdapter = adapter;
            auto fn = (PFND3DKMT_CLOSEADAPTER)GetProcAddress(gdi, "D3DKMTCloseAdapter");
            LONG status = fn(&a);
            printf("KMT_CLOSE PID=%lu NTSTATUS=%08lx\n", GetCurrentProcessId(), (unsigned long)status);
            cleanup_ok &= status == 0;
        }
        if (gdi) FreeLibrary(gdi);
    }
};
static VkResult diagnostic_import(Vulkan& v, HANDLE h, const char* label) {
    phase(label);
    Semaphore consumer(v, false);
    VkResult result = v.import_handle(consumer.s, h);
    printf("PUBLIC_IMPORT RUN_ID=%s PID=%lu PHASE=%s HANDLE=%p RESULT=%d ORIGINAL_PUBLIC_HANDLE=1\n",
           run_id.c_str(), GetCurrentProcessId(), label, h, int(result));
    return result;
}
static void comparison(Vulkan& v, KmtDiagnostic& k, HANDLE a, ACCESS_MASK producer_access) {
    auto ma = measure(a, "A-received");
    require(ma.access == producer_access, "Cross-process SAME_ACCESS changed rights");
    HANDLE raw = nullptr;
    require(DuplicateHandle(GetCurrentProcess(), a, GetCurrentProcess(), &raw,
                            0, FALSE, DUPLICATE_SAME_ACCESS) != 0, "Consumer diagnostic SAME_ACCESS");
    Handle duplicate(raw);
    auto md = measure(duplicate.h, "A-diagnostic-duplicate");
    require(md.access == ma.access, "Diagnostic SAME_ACCESS changed rights");
    same_object(a, duplicate.h, "A-vs-diagnostic-duplicate"); same_record(ma, md);
    printf("DUPLICATE_ROLE=HARNESS_DIAGNOSTIC MESA_INTERNAL_HANDLE=NOT_OBSERVED SAME_ACCESS_EQUIVALENCE=SOURCE_INFERENCE\n");
    duplicate.reset();
    auto ar = k.attest(a, ma, "A");
    auto avk = diagnostic_import(v, a, "A");
    require(ma.access == (native_read | native_query), "Original received handle requires exact access 0x5");
    require(ar.passed(), "Original HANDLE direct ATTEST must return updated success");
    require(avk == VK_SUCCESS, "Original public Vulkan import must pass");
    printf("ORIGINAL_PUBLIC_EXPORT_REGRESSION=PASS DIAGNOSTIC_REOPEN=PROHIBITED\n");
    auto final = measure(a, "A-after-comparison");
    same_record(ma, final);
}
static int diagnostic_consumer(HANDLE replies) {
    {
        Vulkan v; v.open(); KmtDiagnostic k; k.open(v);
        Reply ready{0, GetCurrentProcessId(), 0}; write_exact(replies, &ready, sizeof(ready));
        Packet p{}; read_exact(GetStdHandle(STD_INPUT_HANDLE), &p, sizeof(p), 30000);
        require(p.op == Import && p.e1 && p.handle != 0, "Diagnostic import packet");
        {
            Handle a((HANDLE)(uintptr_t)p.handle);
            comparison(v, k, a.h, ACCESS_MASK(p.value));
        }
        require(cleanup_ok, "Consumer HANDLE cleanup failed");
        Reply done{0, GetCurrentProcessId(), 0}; write_exact(replies, &done, sizeof(done));
        read_exact(GetStdHandle(STD_INPUT_HANDLE), &p, sizeof(p), 15000);
        require(p.op == Quit, "Only comparison and Quit allowed");
    }
    require(cleanup_ok, "KMT cleanup failed");
    Reply done{0, GetCurrentProcessId(), 0}; write_exact(replies, &done, sizeof(done));
    return 0;
}
static int producer() {
    std::wstring name;
    {
        Vulkan v; v.open(); v.work();
        Semaphore sem(v, true); Handle a = v.export_handle(sem.s);
        auto m = measure(a.h, "A-producer-export"); name = m.name;
        require(m.access == (native_read | native_query), "Public export must grant exact native 0x5");
        char exe[2048]; require(GetModuleFileNameA(nullptr, exe, sizeof(exe)) > 0, "Self exe path");
        Child child(exe);
        printf("PRODUCER_LIFETIME PID=%lu CHILD=%lu SEMAPHORE_AND_ORIGINAL_HANDLE_LIVE=1\n", GetCurrentProcessId(), child.pid);
        require(child.call(Import, a.h, m.access, 0, true).result == 0, "Diagnostic consumer completion");
        child.finish();
        auto after = measure(a.h, "A-producer-after-child"); same_record(m, after);
        a.reset(); sem.reset();
    }
    reclaimed(name);
    require(cleanup_ok, "Final cleanup failure");
    printf("DIAGNOSTIC_ROUND=COMPLETE GREEN_A=NOT_PROMOTED PUBLISHES=0 REAL_FAULTS_ADDED=0\n");
    return 0;
}
int main(int argc, char** argv) {
    try {
        const char* rid = getenv("P06_DIAG_RUN_ID"); const char* dir = getenv("P06_DIAG_OUTPUT_DIR");
        require(rid && dir, "Diagnostic run/output environment required");
        run_id = rid; output_dir = dir;
        require(run_id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") == std::string::npos,
                "Invalid run ID");
        require(argc >= 2, "Diagnostic mode required");
        if (strcmp(argv[1], "--consumer") == 0) consumer_logs();
        process_evidence(argc, argv); phase(argv[1]);
        printf("LAYOUT REQUEST=%zu STATUS_OFFSET=%zu HANDLE_OFFSET=%zu RECORD=%zu BASIC=%zu ACCESS_OFFSET=%zu OA=%zu UNICODE=%zu PACKET=%zu REPLY=%zu\n",
               sizeof(CarrierRequest), offsetof(CarrierRequest, status), offsetof(CarrierRequest, user_handle),
               sizeof(Record), sizeof(PUBLIC_OBJECT_BASIC_INFORMATION), offsetof(PUBLIC_OBJECT_BASIC_INFORMATION, GrantedAccess),
               sizeof(OBJECT_ATTRIBUTES), sizeof(UNICODE_STRING), sizeof(Packet), sizeof(Reply));
        if (strcmp(argv[1], "--smoke") == 0) { printf("DIAGNOSTIC_ABI_SMOKE=PASS DRIVER_CALLS=0\n"); return 0; }
        require(getenv("HELIOS_P06_E1_CARRIER_EXPORT") && strcmp(getenv("HELIOS_P06_E1_CARRIER_EXPORT"), "1") == 0,
                "E1 gate must be set before process start");
        if (strcmp(argv[1], "--consumer") == 0) {
            require(argc == 3, "Consumer reply pipe missing");
            return diagnostic_consumer((HANDLE)(uintptr_t)strtoull(argv[2], nullptr, 10));
        }
        require(argc == 2 && strcmp(argv[1], "producer") == 0, "Only focused producer mode authorized");
        return producer();
    } catch (const std::exception& e) {
        fprintf(stderr, "DIAGNOSTIC_STOP RUN_ID=%s PID=%lu MESSAGE=%s CLEANUP_OK=%d\n",
                run_id.c_str(), GetCurrentProcessId(), e.what(), int(cleanup_ok));
        return 1;
    }
}
