// escape_owner_probe.c — the T1b gate instrument for the escape trust boundary.
//
// Exercises, in order:
//   1. QUERY_STATS dump (v1 through v4) — the "counters byte-identical across a
//      session" half of the gate, and the context_full_drops reading R312's
//      untracked-context policy depends on.
//   2. A bad-magic escape        -> must be refused (ESCAPE_BAD_HEADER).
//   3. An unknown verb (0x0007)  -> must be refused (ESCAPE_UNKNOWN_VERB).
//   4. RELEASE_BLOB with hDevice = NULL against the LIVE DWM PRIMARY's resource
//      id (read from QUERY_SCANOUT) -> must be refused (EscNoDev), with the
//      primary still live afterwards and DWM still composing.
//   5. CTX_DESTROY for a context owned by ANOTHER device -> must be refused
//      (EscCtxOwn), with the victim context still usable.
//
// ⚠ TESTS 4 AND 5 ARE DESTRUCTIVE ON A PRE-T1b KMD. Before 22.22.180.0, owner 0
// matched every blob the KMD had adopted for a WDDM allocation, so test 4 would
// unmap+unref the DWM primary behind the live allocation's back (host "invalid
// res_id" -> CS error -> DWM kill). Run them only against a KMD that carries
// R311/R312; that is the point of the test.
//
// Build (WinLibs g++ on win11 — no clang-cl on the box):
//   g++ -O2 -o C:\Users\Rupansh\helios-probe\escape_owner_probe.exe ^
//       Z:\tools\escape_owner_probe.c -I"Z:\icd\win-build\wdk-include" -lgdi32
#include <windows.h>
#include <stdio.h>
#include <stddef.h>

#ifndef _NTDEF_
typedef LONG NTSTATUS, *PNTSTATUS;
#endif
#include <d3dkmthk.h>
#ifndef NT_SUCCESS
#define NT_SUCCESS(Status) (((NTSTATUS)(Status)) >= 0)
#endif

/* protocol/src/escape.rs is the AUTHORITY for every opcode below — these are a
 * hand-kept C mirror of it and must be re-checked against it when it changes.
 * 2026-08-05: QUERY_SCANOUT was 0x000Bu here, which is REGISTER_FENCE_EVENT in
 * protocol/src/escape.rs (kmd_render/src/ddi/escape.rs:365 dispatches 0x000B to
 * escape_register_fence_event). The probe was aiming a query-scanout-shaped
 * buffer at the fence-event registrar and printing whatever came back. */
#define HELIOS_ESCAPE_MAGIC 0x48454C53u /* 'HELS' */
#define HELIOS_ESCAPE_VERSION 1u
#define HELIOS_ESCAPE_CTX_CREATE 0x0002u
#define HELIOS_ESCAPE_CTX_DESTROY 0x0003u
#define HELIOS_ESCAPE_ALLOC_BLOB 0x0004u
#define HELIOS_ESCAPE_PRESENT_BLOB 0x0007u /* defined in protocol, never dispatched */
#define HELIOS_ESCAPE_RELEASE_BLOB 0x0008u
#define HELIOS_ESCAPE_QUERY_STATS 0x000Au
#define HELIOS_ESCAPE_QUERY_SCANOUT 0x000Du
#define VIRTIO_GPU_CAPSET_VENUS 4u

/* winnt.h defines these as DWORD; we compare against NTSTATUS. */
#undef STATUS_INVALID_PARAMETER
#undef STATUS_NOT_IMPLEMENTED
#undef STATUS_INVALID_DEVICE_REQUEST
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xC000000DL)
#define STATUS_NOT_IMPLEMENTED ((NTSTATUS)0xC0000002L)
#define STATUS_INVALID_DEVICE_REQUEST ((NTSTATUS)0xC0000010L)

struct helios_escape_header {
    UINT magic, cmd_type, version, size;
};
struct helios_escape_ctx_create {
    struct helios_escape_header hdr;
    UINT capset_id;
    UINT out_ctx_id;
};
struct helios_escape_ctx_destroy {
    struct helios_escape_header hdr;
    UINT ctx_id, padding;
};
struct helios_escape_release_blob {
    struct helios_escape_header hdr;
    UINT ctx_id, resource_id, flags, padding;
};
/* protocol/src/escape.rs HeliosEscapeQueryStats (v1, 88 bytes) */
struct helios_escape_query_stats {
    struct helios_escape_header hdr;
    UINT64 out_window_used;
    UINT64 out_window_len;
    UINT out_blobs_live, out_blobs_cap, out_blobs_high_water, out_blob_full_rejects;
    UINT out_resources_live, out_resources_cap, out_resources_high_water, out_resource_full_rejects;
    UINT out_contexts_live, out_context_full_drops;
    UINT out_window_range_drops, out_ctrl_timeouts;
    UINT out_take_live_misses, out_adopt_dead_rejects;
};
/* v2 extension (KMD 22.22.54+) */
struct helios_escape_query_stats_v2 {
    struct helios_escape_query_stats v1;
    UINT out_fence_events_live, out_fence_events_high_water;
    UINT out_fence_event_registers, out_fence_event_signals;
    UINT out_fence_event_already_complete, out_fence_event_overflows;
    UINT out_fence_event_dup_rejects, out_fence_event_invalid;
    UINT out_fence_event_cancels, out_fence_event_teardown_drops;
    UINT out_mappings_live, out_mappings_cap, out_mappings_high_water;
    UINT out_mapping_full_rejects, out_map_pages_fails, out_window_alloc_rejects;
};
/* v3 extension (KMD 22.22.180+, T1b): the escape-refusal family + the counters
   R315 made reportable. */
struct helios_escape_query_stats_v3 {
    struct helios_escape_query_stats_v2 v2;
    UINT out_escape_bad_header, out_escape_unknown_verb, out_escape_short_buffer;
    UINT out_escape_device_gone, out_escape_no_device, out_escape_foreign_ctx;
    UINT out_async_ctrl_resp_errors, out_cpu_host_unmap_count;
    UINT out_dma_alloc_fails, out_mmio_map_fails, out_mmio_cache_full;
    UINT out_query_scanout_retries;
};
/* v4 extension: registered async-present stream evidence. */
struct helios_escape_query_stats_v4 {
    struct helios_escape_query_stats_v3 v3;
    UINT out_present_streams_live, out_present_streams_cap;
    UINT out_present_streams_high_water, out_present_stream_registers;
    UINT out_present_stream_tags, out_present_stream_markers;
    UINT out_present_stream_retires, out_present_stream_rejects;
};

/* V5 append-only P06 diagnostic snapshot. */
struct helios_escape_query_stats_v5 {
    struct helios_escape_query_stats_v4 v4;
    UINT64 out_p06_diag_version;
    UINT64 submit_assigned_count, last_submit_ctx, last_submit_ring;
    UINT64 last_submit_wire_fence, last_submit_time;
    UINT64 event_register_count, last_register_fence, last_register_result;
    UINT64 last_register_response, last_register_time;
    UINT64 async_error_drain_count, last_error_fence, last_error_response, last_error_time;
    UINT64 event_signal_count, last_signal_fence, last_signal_time;
    UINT64 event_unregister_count, last_unregister_fence, last_unregister_result;
    UINT64 last_unregister_response, last_unregister_time;
    UINT64 last_submit_previous_wire_fence;
};
_Static_assert(sizeof(struct helios_escape_query_stats) == 88, "QUERY_STATS v1 size");
_Static_assert(sizeof(struct helios_escape_query_stats_v2) == 152, "QUERY_STATS v2 size");
_Static_assert(sizeof(struct helios_escape_query_stats_v3) == 200, "QUERY_STATS v3 size");
_Static_assert(sizeof(struct helios_escape_query_stats_v4) == 232, "QUERY_STATS v4 size");
_Static_assert(sizeof(struct helios_escape_query_stats_v5) == 424, "QUERY_STATS v5 size");
_Static_assert(offsetof(struct helios_escape_query_stats_v5, v4) == 0, "V4 prefix offset");
_Static_assert(offsetof(struct helios_escape_query_stats_v5, out_p06_diag_version) == 232, "V5 discriminator offset");
_Static_assert(offsetof(struct helios_escape_query_stats_v5, last_submit_previous_wire_fence) == 416, "previous wire fence offset");

/* HeliosEscapeQueryScanout */
struct helios_escape_query_scanout {
    struct helios_escape_header hdr;
    UINT64 out_alloc_size;
    UINT out_resource_id, out_width, out_height, out_dxgi_format;
    UINT out_pitch, out_plane_offset, out_memory_type_index, out_generation;
    UINT reserved[2];
};

static D3DKMT_HANDLE g_adapter, g_device_a, g_device_b;
static LUID g_adapter_luid;

static NTSTATUS escape_on_adapter(D3DKMT_HANDLE adapter, D3DKMT_HANDLE device,
                                 void* buf, UINT size) {
    D3DKMT_ESCAPE esc;
    memset(&esc, 0, sizeof(esc));
    esc.hAdapter = adapter;
    esc.hDevice = device; /* 0 = the forgeable owner value this probe tests */
    esc.Type = D3DKMT_ESCAPE_DRIVERPRIVATE;
    esc.pPrivateDriverData = buf;
    esc.PrivateDriverDataSize = size;
    return D3DKMTEscape(&esc);
}

static NTSTATUS escape_on(D3DKMT_HANDLE device, void* buf, UINT size) {
    return escape_on_adapter(g_adapter, device, buf, size);
}

static int destroy_device(D3DKMT_HANDLE device) {
    D3DKMT_DESTROYDEVICE dd;
    memset(&dd, 0, sizeof(dd));
    dd.hDevice = device;
    return NT_SUCCESS(D3DKMTDestroyDevice(&dd));
}

static int close_adapter(D3DKMT_HANDLE adapter) {
    D3DKMT_CLOSEADAPTER ca;
    memset(&ca, 0, sizeof(ca));
    ca.hAdapter = adapter;
    return NT_SUCCESS(D3DKMTCloseAdapter(&ca));
}

static void hdr_init(struct helios_escape_header* h, UINT verb, UINT size) {
    h->magic = HELIOS_ESCAPE_MAGIC;
    h->cmd_type = verb;
    h->version = HELIOS_ESCAPE_VERSION;
    h->size = size;
}

/* Find Helios the way the ICD does: only its KMD answers the CTX_CREATE escape.
   Leaves two devices open on the adapter (A = victim, B = attacker). */
static int open_helios(UINT* out_ctx_a) {
    D3DKMT_ENUMADAPTERS2 ea;
    memset(&ea, 0, sizeof(ea));
    if (!NT_SUCCESS(D3DKMTEnumAdapters2(&ea)) || ea.NumAdapters == 0) {
        printf("EnumAdapters2 failed\n");
        return 1;
    }
    ea.pAdapters = (D3DKMT_ADAPTERINFO*)calloc(ea.NumAdapters, sizeof(D3DKMT_ADAPTERINFO));
    if (!ea.pAdapters) {
        printf("adapter enumeration allocation failed\n");
        return 1;
    }
    if (!NT_SUCCESS(D3DKMTEnumAdapters2(&ea))) {
        printf("EnumAdapters2(2) failed\n");
        return 1;
    }
    for (UINT i = 0; i < ea.NumAdapters; i++) {
        D3DKMT_HANDLE h = ea.pAdapters[i].hAdapter;
        D3DKMT_CREATEDEVICE cd;
        memset(&cd, 0, sizeof(cd));
        cd.hAdapter = h;
        const NTSTATUS create_status = D3DKMTCreateDevice(&cd);
        if (!NT_SUCCESS(create_status)) {
            close_adapter(h);
            continue;
        }
        g_adapter = h;
        g_adapter_luid = ea.pAdapters[i].AdapterLuid;
        g_device_a = cd.hDevice;

        struct helios_escape_ctx_create cc;
        memset(&cc, 0, sizeof(cc));
        hdr_init(&cc.hdr, HELIOS_ESCAPE_CTX_CREATE, sizeof(cc));
        cc.capset_id = VIRTIO_GPU_CAPSET_VENUS;
        NTSTATUS est = escape_on(g_device_a, &cc, sizeof(cc));
        if (NT_SUCCESS(est) && cc.out_ctx_id != 0) {
            *out_ctx_a = cc.out_ctx_id;
            D3DKMT_CREATEDEVICE cd2;
            memset(&cd2, 0, sizeof(cd2));
            cd2.hAdapter = h;
            if (NT_SUCCESS(D3DKMTCreateDevice(&cd2))) {
                g_device_b = cd2.hDevice;
            }
            printf("helios adapter luid=%08x:%08x deviceA=%#x deviceB=%#x ctxA=%u\n",
                   (unsigned)ea.pAdapters[i].AdapterLuid.HighPart,
                   (unsigned)ea.pAdapters[i].AdapterLuid.LowPart, (unsigned)g_device_a,
                   (unsigned)g_device_b, cc.out_ctx_id);
            free(ea.pAdapters);
            return 0;
        }
        destroy_device(cd.hDevice);
        close_adapter(h);
        g_adapter = 0;
        g_device_a = 0;
    }
    free(ea.pAdapters);
    printf("no adapter answered the Helios CTX_CREATE escape\n");
    return 1;
}

static int dump_stats(const char* label, struct helios_escape_query_stats* out) {
    struct helios_escape_query_stats_v4 v4;
    memset(&v4, 0, sizeof(v4));
    hdr_init(&v4.v3.v2.v1.hdr, HELIOS_ESCAPE_QUERY_STATS, sizeof(v4));
    NTSTATUS st4 = escape_on(g_device_a, &v4, sizeof(v4));
    struct helios_escape_query_stats qs;
    memset(&qs, 0, sizeof(qs));
    hdr_init(&qs.hdr, HELIOS_ESCAPE_QUERY_STATS, sizeof(qs));
    NTSTATUS st = escape_on(g_device_a, &qs, sizeof(qs));
    if (!NT_SUCCESS(st)) {
        printf("[%s] QUERY_STATS st=0x%08x\n", label, (unsigned)st);
        return 1;
    }
    if (NT_SUCCESS(st4) && v4.out_present_streams_cap != 0) {
        printf("[%s] V3 escape_refusals: bad_header=%u unknown_verb=%u short_buffer=%u "
               "device_gone=%u no_device=%u foreign_ctx=%u | ctrl_resp_errors=%u "
               "ddi_unmaps=%u | hal: dma_fails=%u mmio_fails=%u cache_full=%u | "
               "qs_retries=%u\n",
               label, v4.v3.out_escape_bad_header, v4.v3.out_escape_unknown_verb,
               v4.v3.out_escape_short_buffer, v4.v3.out_escape_device_gone,
               v4.v3.out_escape_no_device, v4.v3.out_escape_foreign_ctx,
               v4.v3.out_async_ctrl_resp_errors, v4.v3.out_cpu_host_unmap_count,
               v4.v3.out_dma_alloc_fails, v4.v3.out_mmio_map_fails,
               v4.v3.out_mmio_cache_full, v4.v3.out_query_scanout_retries);
        printf("[%s] V4 present_streams: live=%u/%u hw=%u registers=%u tags=%u "
               "markers=%u retires=%u rejects=%u\n",
               label, v4.out_present_streams_live, v4.out_present_streams_cap,
               v4.out_present_streams_high_water, v4.out_present_stream_registers,
               v4.out_present_stream_tags, v4.out_present_stream_markers,
               v4.out_present_stream_retires, v4.out_present_stream_rejects);
    } else {
        /* V1-V3 KMDs accept a larger declared query and write only their known
           prefix, so success alone does not prove V4. A nonzero fixed capacity
           is the appended-version discriminator. */
        printf("[%s] V4 QUERY_STATS unavailable: st=0x%08x cap=%u (older KMD)\n",
               label, (unsigned)st4, v4.out_present_streams_cap);
    }
    printf("[%s] blobs=%u/%u hw=%u rej=%u | resources=%u/%u hw=%u rej=%u | "
           "contexts=%u drops=%u | window=%llu/%llu rangedrops=%u | ctrl_timeouts=%u "
           "take_live_misses=%u adopt_dead=%u\n",
           label, qs.out_blobs_live, qs.out_blobs_cap, qs.out_blobs_high_water,
           qs.out_blob_full_rejects, qs.out_resources_live, qs.out_resources_cap,
           qs.out_resources_high_water, qs.out_resource_full_rejects, qs.out_contexts_live,
           qs.out_context_full_drops, (unsigned long long)qs.out_window_used,
           (unsigned long long)qs.out_window_len, qs.out_window_range_drops, qs.out_ctrl_timeouts,
           qs.out_take_live_misses, qs.out_adopt_dead_rejects);
    if (out) {
        *out = qs;
    }
    return 0;
}

static int dump_stats_v5(const char* label) {
    struct helios_escape_query_stats_v5 v5;
    memset(&v5, 0xA5, sizeof(v5));
    hdr_init(&v5.v4.v3.v2.v1.hdr, HELIOS_ESCAPE_QUERY_STATS, sizeof(v5));
    NTSTATUS st = escape_on(g_device_a, &v5, sizeof(v5));
    const struct helios_escape_query_stats_v4 *v4 = &v5.v4;
    FILETIME ft;
    LARGE_INTEGER qpc;
    GetSystemTimePreciseAsFileTime(&ft);
    QueryPerformanceCounter(&qpc);
    const ULONGLONG utc_filetime = ((ULONGLONG)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    printf("utc_filetime=%llu qpc=%lld pid=%lu tid=%lu luid=%08x:%08x device=%#x [%s] QUERY_STATS_V5 raw=0x%08x nt_success=%u cap=%u diag_version=%llu "
           "submit_count=%llu last_submit_fence=%llu register_count=%llu "
           "last_submit_previous_fence=%llu register_fence=%llu register_result=%llu register_response=%llu "
           "error_drain_count=%llu error_fence=%llu error_response=%llu signal_count=%llu signal_fence=%llu "
           "unregister_count=%llu unregister_fence=%llu unregister_result=%llu unregister_response=%llu\n",
           (unsigned long long)utc_filetime, (long long)qpc.QuadPart,
           (unsigned long)GetCurrentProcessId(), (unsigned long)GetCurrentThreadId(),
           (unsigned)g_adapter_luid.HighPart,
           (unsigned)g_adapter_luid.LowPart, (unsigned)g_device_a,
           label, (unsigned)st, NT_SUCCESS(st), v4->out_present_streams_cap,
           (unsigned long long)v5.out_p06_diag_version,
           (unsigned long long)v5.submit_assigned_count,
           (unsigned long long)v5.last_submit_wire_fence,
           (unsigned long long)v5.event_register_count,
           (unsigned long long)v5.last_submit_previous_wire_fence,
           (unsigned long long)v5.last_register_fence,
           (unsigned long long)v5.last_register_result,
           (unsigned long long)v5.last_register_response,
           (unsigned long long)v5.async_error_drain_count,
           (unsigned long long)v5.last_error_fence,
           (unsigned long long)v5.last_error_response,
           (unsigned long long)v5.event_signal_count,
           (unsigned long long)v5.last_signal_fence,
           (unsigned long long)v5.event_unregister_count,
           (unsigned long long)v5.last_unregister_fence,
           (unsigned long long)v5.last_unregister_result,
           (unsigned long long)v5.last_unregister_response);
    return !NT_SUCCESS(st) || v4->out_present_streams_cap != 64 ||
           v5.out_p06_diag_version != 1;
}

static int dump_stats_v5_monitor(UINT interval_ms, UINT duration_ms) {
    if (!interval_ms || duration_ms % interval_ms)
        return 1;
    const UINT sample_count = duration_ms / interval_ms + 1;
    int failed = 0;
    for (UINT sample = 0; sample < sample_count; sample++) {
        char label[32];
        snprintf(label, sizeof(label), "monitor-%u", sample);
        failed |= dump_stats_v5(label);
        if (sample + 1 != sample_count)
            Sleep(interval_ms);
    }
    return failed;
}

static int v5_query_supported(D3DKMT_HANDLE adapter, D3DKMT_HANDLE device) {
    struct helios_escape_query_stats_v5 v5;
    memset(&v5, 0xA5, sizeof(v5));
    hdr_init(&v5.v4.v3.v2.v1.hdr, HELIOS_ESCAPE_QUERY_STATS, sizeof(v5));
    const NTSTATUS status = escape_on_adapter(adapter, device, &v5, sizeof(v5));
    const int supported = NT_SUCCESS(status) &&
                          v5.v4.out_present_streams_cap == 64 &&
                          v5.out_p06_diag_version == 1;
    printf("adapter_candidate v5_raw=0x%08x nt_success=%u cap=%u diag_version=%llu supported=%u\n",
           (unsigned)status, NT_SUCCESS(status),
           v5.v4.out_present_streams_cap,
           (unsigned long long)v5.out_p06_diag_version, supported);
    return supported;
}

static int v5_reader_open(LUID *luid, D3DKMT_HANDLE *adapter,
                          D3DKMT_HANDLE *device) {
    D3DKMT_ENUMADAPTERS2 ea;
    memset(&ea, 0, sizeof(ea));
    NTSTATUS status = D3DKMTEnumAdapters2(&ea);
    printf("enum_adapters_count raw=0x%08x nt_success=%u count=%u\n",
           (unsigned)status, NT_SUCCESS(status), (unsigned)ea.NumAdapters);
    if (!NT_SUCCESS(status) || !ea.NumAdapters)
        return 1;
    const UINT capacity = ea.NumAdapters;
    D3DKMT_ADAPTERINFO *items = calloc(capacity, sizeof(*items));
    if (!items)
        return 1;
    ea.pAdapters = items;
    status = D3DKMTEnumAdapters2(&ea);
    printf("enum_adapters_data raw=0x%08x nt_success=%u count=%u\n",
           (unsigned)status, NT_SUCCESS(status), (unsigned)ea.NumAdapters);
    if (!NT_SUCCESS(status)) {
        free(items);
        return 1;
    }
    int found = 0;
    for (UINT i = 0; i < ea.NumAdapters; i++) {
        D3DKMT_CREATEDEVICE create;
        memset(&create, 0, sizeof(create));
        create.hAdapter = items[i].hAdapter;
        const NTSTATUS status = D3DKMTCreateDevice(&create);
        printf("adapter_candidate luid=%08x:%08x create_raw=0x%08x nt_success=%u device=%#x\n",
               (unsigned)items[i].AdapterLuid.HighPart,
               (unsigned)items[i].AdapterLuid.LowPart, (unsigned)status,
               NT_SUCCESS(status), (unsigned)create.hDevice);
        if (!NT_SUCCESS(status)) {
            D3DKMT_CLOSEADAPTER close;
            memset(&close, 0, sizeof(close));
            close.hAdapter = items[i].hAdapter;
            const NTSTATUS close_status = D3DKMTCloseAdapter(&close);
            printf("adapter_candidate create_failed close_raw=0x%08x close_nt_success=%u\n",
                   (unsigned)close_status, NT_SUCCESS(close_status));
            continue;
        }
        if (!v5_query_supported(items[i].hAdapter, create.hDevice)) {
            D3DKMT_DESTROYDEVICE destroy;
            memset(&destroy, 0, sizeof(destroy));
            destroy.hDevice = create.hDevice;
            const NTSTATUS dst = D3DKMTDestroyDevice(&destroy);
            D3DKMT_CLOSEADAPTER close;
            memset(&close, 0, sizeof(close));
            close.hAdapter = items[i].hAdapter;
            const NTSTATUS cst = D3DKMTCloseAdapter(&close);
            printf("adapter_candidate rejected destroy_raw=0x%08x nt_success=%u close_raw=0x%08x nt_success=%u\n",
                   (unsigned)dst, NT_SUCCESS(dst), (unsigned)cst, NT_SUCCESS(cst));
            continue;
        }
        *adapter = items[i].hAdapter;
        *device = create.hDevice;
        *luid = items[i].AdapterLuid;
        found = 1;
        break;
    }
    free(items);
    return !found;
}

static int v5_reader_close(D3DKMT_HANDLE adapter, D3DKMT_HANDLE device) {
    D3DKMT_DESTROYDEVICE destroy;
    memset(&destroy, 0, sizeof(destroy));
    destroy.hDevice = device;
    const NTSTATUS dst = D3DKMTDestroyDevice(&destroy);
    D3DKMT_CLOSEADAPTER close;
    memset(&close, 0, sizeof(close));
    close.hAdapter = adapter;
    const NTSTATUS cst = D3DKMTCloseAdapter(&close);
    printf("teardown destroy_raw=0x%08x destroy_nt_success=%u close_raw=0x%08x close_nt_success=%u\n",
           (unsigned)dst, NT_SUCCESS(dst), (unsigned)cst, NT_SUCCESS(cst));
    return !NT_SUCCESS(dst) || !NT_SUCCESS(cst);
}

static int run_v5_reader(int monitor, UINT interval_ms, UINT duration_ms) {
    LUID luid;
    D3DKMT_HANDLE adapter = 0, device = 0;
    if (v5_reader_open(&luid, &adapter, &device))
        return 1;
    g_adapter = adapter;
    g_adapter_luid = luid;
    g_device_a = device;
    int failed = monitor ? dump_stats_v5_monitor(interval_ms, duration_ms)
                         : dump_stats_v5("once");
    failed |= v5_reader_close(adapter, device);
    return failed;
}

static int query_scanout(struct helios_escape_query_scanout* qs) {
    memset(qs, 0, sizeof(*qs));
    hdr_init(&qs->hdr, HELIOS_ESCAPE_QUERY_SCANOUT, sizeof(*qs));
    NTSTATUS st = escape_on(g_device_a, qs, sizeof(*qs));
    printf("QUERY_SCANOUT st=0x%08x resid=%u %ux%u pitch=%u gen=%u\n", (unsigned)st,
           qs->out_resource_id, qs->out_width, qs->out_height, qs->out_pitch, qs->out_generation);
    return !NT_SUCCESS(st);
}

int main(int argc, char** argv) {
    if (argc > 1 && strcmp(argv[1], "--v5-once") == 0)
        return run_v5_reader(0, 0, 0);
    if (argc > 1 && strcmp(argv[1], "--v5-monitor") == 0) {
        const UINT interval = argc > 2 ? (UINT)strtoul(argv[2], NULL, 10) : 100;
        const UINT duration = argc > 3 ? (UINT)strtoul(argv[3], NULL, 10) : 2000;
        return run_v5_reader(1, interval, duration);
    }
    int destructive = (argc > 1 && strcmp(argv[1], "--attack") == 0);
    /* Optional explicit victim resource id for test 4. QUERY_SCANOUT only
       reports the KMD-owned LINEAR direct primary, which may not be published;
       the service key's ScRid (the ACTIVE scanout resource) is the other live,
       KMD-adopted (owner-0) blob behind the desktop, and is the same class of
       target. */
    UINT victim = (argc > 2) ? (UINT)strtoul(argv[2], NULL, 0) : 0;
    UINT ctx_a = 0;
    if (open_helios(&ctx_a) != 0) {
        return 1;
    }

    struct helios_escape_query_stats before;
    dump_stats("start", &before);

    /* --- 2. bad magic --- */
    struct helios_escape_ctx_destroy bad;
    memset(&bad, 0, sizeof(bad));
    hdr_init(&bad.hdr, HELIOS_ESCAPE_CTX_DESTROY, sizeof(bad));
    bad.hdr.magic = 0xDEADBEEFu;
    bad.ctx_id = ctx_a;
    NTSTATUS st = escape_on(g_device_a, &bad, sizeof(bad));
    printf("bad-magic escape       st=0x%08x %s\n", (unsigned)st,
           st == STATUS_INVALID_PARAMETER ? "(PASS: refused)" : "(FAIL: expected INVALID_PARAMETER)");

    /* --- 3. unknown verb --- */
    struct helios_escape_header unk;
    hdr_init(&unk, HELIOS_ESCAPE_PRESENT_BLOB, sizeof(unk));
    st = escape_on(g_device_a, &unk, sizeof(unk));
    printf("unknown verb 0x0007    st=0x%08x %s\n", (unsigned)st,
           st == STATUS_NOT_IMPLEMENTED ? "(PASS: refused)" : "(FAIL: expected NOT_IMPLEMENTED)");

    if (!destructive) {
        printf("\nSkipping the ownership attacks (pass --attack to run them; they are\n"
               "DESTRUCTIVE against a pre-22.22.180.0 KMD).\n");
    } else {
        /* --- 4. owner==0 RELEASE_BLOB against the live DWM primary --- */
        struct helios_escape_query_scanout sc;
        int have_scanout = (query_scanout(&sc) == 0 && sc.out_resource_id != 0);
        if (have_scanout) {
            victim = sc.out_resource_id;
        }
        if (victim != 0) {
            struct helios_escape_release_blob rb;
            memset(&rb, 0, sizeof(rb));
            hdr_init(&rb.hdr, HELIOS_ESCAPE_RELEASE_BLOB, sizeof(rb));
            rb.ctx_id = ctx_a; /* nonzero: the KMD rejects ctx_id 0 outright */
            rb.resource_id = victim;
            st = escape_on(0 /* hDevice = NULL: the forged owner */, &rb, sizeof(rb));
            printf("owner=0 RELEASE_BLOB(live resid=%u) st=0x%08x %s\n", victim,
                   (unsigned)st,
                   st == STATUS_INVALID_PARAMETER ? "(PASS: refused)"
                                                  : "(FAIL: the KMD accepted a forged owner)");
            struct helios_escape_query_scanout after_sc;
            if (have_scanout && query_scanout(&after_sc) == 0) {
                printf("primary after attack   resid=%u %s\n", after_sc.out_resource_id,
                       after_sc.out_resource_id == sc.out_resource_id
                           ? "(PASS: unchanged)"
                           : "(FAIL: the primary was destroyed)");
            }
        } else {
            printf("no victim resource id (pass one as argv[2], e.g. the service key's "
                   "ScRid); skipping the owner=0 attack\n");
        }

        /* --- 5. cross-device CTX_DESTROY --- */
        if (g_device_b != 0) {
            struct helios_escape_ctx_destroy cd;
            memset(&cd, 0, sizeof(cd));
            hdr_init(&cd.hdr, HELIOS_ESCAPE_CTX_DESTROY, sizeof(cd));
            cd.ctx_id = ctx_a; /* device A's context, destroyed from device B */
            st = escape_on(g_device_b, &cd, sizeof(cd));
            printf("cross-device CTX_DESTROY(ctx=%u) st=0x%08x %s\n", ctx_a, (unsigned)st,
                   st == STATUS_INVALID_DEVICE_REQUEST
                       ? "(PASS: refused)"
                       : "(FAIL: one device destroyed another's context)");
        }
    }

    struct helios_escape_query_stats after;
    dump_stats("end", &after);
    printf("\ndelta: blobs_live %+d  contexts_live %+d  context_full_drops %+d\n",
           (int)after.out_blobs_live - (int)before.out_blobs_live,
           (int)after.out_contexts_live - (int)before.out_contexts_live,
           (int)after.out_context_full_drops - (int)before.out_context_full_drops);

    /* Clean up our own context so the probe stays state-neutral. */
    struct helios_escape_ctx_destroy cd;
    memset(&cd, 0, sizeof(cd));
    hdr_init(&cd.hdr, HELIOS_ESCAPE_CTX_DESTROY, sizeof(cd));
    cd.ctx_id = ctx_a;
    st = escape_on(g_device_a, &cd, sizeof(cd));
    printf("own CTX_DESTROY        st=0x%08x %s\n", (unsigned)st,
           NT_SUCCESS(st) ? "(PASS: owner keeps its rights)" : "(FAIL: owner-scoping is too strict)");

    if (g_device_b) {
        destroy_device(g_device_b);
    }
    destroy_device(g_device_a);
    close_adapter(g_adapter);
    return 0;
}
