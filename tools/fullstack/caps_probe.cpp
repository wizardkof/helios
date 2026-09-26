#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <d3d12.h>
#include <dxgi1_6.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "probe_common.h"

#pragma comment(lib, "bcrypt.lib")

namespace {

std::string hex(const BYTE* bytes, ULONG size) {
    static const char digits[] = "0123456789abcdef";
    std::string result;
    result.reserve(static_cast<size_t>(size) * 2);
    for (ULONG i = 0; i < size; ++i) {
        result.push_back(digits[bytes[i] >> 4]);
        result.push_back(digits[bytes[i] & 15]);
    }
    return result;
}

std::string layout_hash(const char* name, size_t size, unsigned pointer_bits) {
    const std::string input = std::string(name) + "|" + std::to_string(size) + "|" +
                              std::to_string(D3D12_SDK_VERSION) + "|" +
                              std::to_string(pointer_bits);
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD object_size = 0;
    DWORD returned = 0;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0 ||
        BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                          reinterpret_cast<PUCHAR>(&object_size), sizeof(object_size),
                          &returned, 0) < 0) {
        if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
        return {};
    }
    std::vector<BYTE> object(object_size);
    BYTE digest[32]{};
    NTSTATUS status = BCryptCreateHash(algorithm, &hash, object.data(), object_size,
                                       nullptr, 0, 0);
    if (status >= 0) {
        status = BCryptHashData(hash,
                                reinterpret_cast<PUCHAR>(const_cast<char*>(input.data())),
                                static_cast<ULONG>(input.size()), 0);
    }
    if (status >= 0) status = BCryptFinishHash(hash, digest, sizeof(digest), 0);
    if (hash) BCryptDestroyHash(hash);
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return status >= 0 ? hex(digest, sizeof(digest)) : std::string{};
}

std::string quote(const std::string& value) {
    return helios_fullstack::json_string(value);
}

std::string record(const char* struct_name, size_t struct_size,
                   const std::string& layout, HRESULT hr,
                   const std::string& value) {
    if (FAILED(hr)) {
        char hresult[16]{};
        std::snprintf(hresult, sizeof(hresult), "0x%08lX", static_cast<unsigned long>(hr));
        return "{\"status\":\"QUERY_FAILED\",\"hresult\":" + quote(hresult) + "}";
    }
    return "{\"status\":\"QUERIED\",\"struct_name\":" + quote(struct_name) +
           ",\"struct_size\":" + std::to_string(struct_size) +
           ",\"payload_bytes\":" + std::to_string(struct_size) +
           ",\"layout_hash\":" + quote(layout) + ",\"value\":" + value + "}";
}

template <typename T>
void add_layout(std::string& layouts, bool& first, const char* name, unsigned pointer_bits) {
    if (!first) layouts += ",";
    first = false;
    const size_t size = sizeof(T);
    layouts += quote(name) + ":{\"size\":" + std::to_string(size) +
               ",\"layout_hash\":" + quote(layout_hash(name, size, pointer_bits)) + "}";
}

void add_query(std::string& queries, bool& first, const char* id, const char* type,
               size_t size, const std::string& layout, HRESULT hr,
               const std::string& value) {
    if (!first) queries += ",";
    first = false;
    queries += quote(id) + ":" + record(type, size, layout, hr, value);
}

std::string number(unsigned value) { return std::to_string(value); }
std::string boolean(BOOL value) { return value ? "true" : "false"; }

} // namespace

int main(int argc, char** argv) {
    if (argc != 4) {
        std::fprintf(stderr, "usage: caps_probe.exe <adapter-luid-high:low> <source-fingerprint> <output.json>\n");
        return 2;
    }
    const std::string wanted_luid(argv[1]);
    const std::string source_fingerprint(argv[2]);
    const char* output_path = argv[3];
    if (source_fingerprint.size() != 64) {
        std::fprintf(stderr, "source fingerprint must be a 64-character SHA-256\n");
        return 2;
    }

    IDXGIFactory1* factory = nullptr;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return 3;
    IDXGIAdapter1* selected = nullptr;
    DXGI_ADAPTER_DESC1 selected_desc{};
    for (UINT index = 0;; ++index) {
        IDXGIAdapter1* adapter = nullptr;
        if (factory->EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND) break;
        DXGI_ADAPTER_DESC1 desc{};
        adapter->GetDesc1(&desc);
        char luid[24]{};
        std::snprintf(luid, sizeof(luid), "%08lX:%08lX",
                      static_cast<unsigned long>(desc.AdapterLuid.HighPart),
                      static_cast<unsigned long>(desc.AdapterLuid.LowPart));
        if (wanted_luid == luid) {
            selected = adapter;
            selected_desc = desc;
            break;
        }
        adapter->Release();
    }
    if (!selected) {
        factory->Release();
        std::fprintf(stderr, "requested adapter LUID was not enumerated\n");
        return 4;
    }

    ID3D12Device* device = nullptr;
    hr = D3D12CreateDevice(selected, D3D_FEATURE_LEVEL_11_0,
                           IID_PPV_ARGS(&device));
    if (FAILED(hr)) {
        selected->Release();
        factory->Release();
        std::fprintf(stderr, "D3D12 device creation at FL11_0 failed\n");
        return 5;
    }

    const unsigned pointer_bits = static_cast<unsigned>(sizeof(void*) * 8);
    std::string layouts = "{";
    bool first_layout = true;
    add_layout<D3D12_FEATURE_DATA_SHADER_MODEL>(layouts, first_layout, "D3D12_FEATURE_DATA_SHADER_MODEL", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_D3D12_OPTIONS>(layouts, first_layout, "D3D12_FEATURE_DATA_D3D12_OPTIONS", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_D3D12_OPTIONS1>(layouts, first_layout, "D3D12_FEATURE_DATA_D3D12_OPTIONS1", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_D3D12_OPTIONS2>(layouts, first_layout, "D3D12_FEATURE_DATA_D3D12_OPTIONS2", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_D3D12_OPTIONS3>(layouts, first_layout, "D3D12_FEATURE_DATA_D3D12_OPTIONS3", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_D3D12_OPTIONS5>(layouts, first_layout, "D3D12_FEATURE_DATA_D3D12_OPTIONS5", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_D3D12_OPTIONS6>(layouts, first_layout, "D3D12_FEATURE_DATA_D3D12_OPTIONS6", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_D3D12_OPTIONS7>(layouts, first_layout, "D3D12_FEATURE_DATA_D3D12_OPTIONS7", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_D3D12_OPTIONS8>(layouts, first_layout, "D3D12_FEATURE_DATA_D3D12_OPTIONS8", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_ROOT_SIGNATURE>(layouts, first_layout, "D3D12_FEATURE_DATA_ROOT_SIGNATURE", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_GPU_VIRTUAL_ADDRESS_SUPPORT>(layouts, first_layout, "D3D12_FEATURE_DATA_GPU_VIRTUAL_ADDRESS_SUPPORT", pointer_bits);
    add_layout<D3D12_FEATURE_DATA_FEATURE_LEVELS>(layouts, first_layout, "D3D12_FEATURE_DATA_FEATURE_LEVELS", pointer_bits);
    layouts += "}";

    std::string queries = "{";
    bool first_query = true;
    auto layout = [](const char* name, size_t size, unsigned bits) { return layout_hash(name, size, bits); };

    D3D12_FEATURE_DATA_SHADER_MODEL shader{};
    shader.HighestShaderModel = D3D_SHADER_MODEL_6_5;
    HRESULT qhr = device->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, &shader, sizeof(shader));
    add_query(queries, first_query, "F01", "D3D12_FEATURE_DATA_SHADER_MODEL", sizeof(shader), layout("D3D12_FEATURE_DATA_SHADER_MODEL", sizeof(shader), pointer_bits), qhr,
              quote(number(static_cast<unsigned>(shader.HighestShaderModel))));

    D3D12_FEATURE_DATA_D3D12_OPTIONS options{};
    HRESULT options_hr = device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS, &options, sizeof(options));
    const char* options_type = "D3D12_FEATURE_DATA_D3D12_OPTIONS";
    const size_t options_size = sizeof(options);
    const auto options_layout = layout(options_type, options_size, pointer_bits);
    add_query(queries, first_query, "F06", options_type, options_size, options_layout, options_hr, number(options.ResourceBindingTier));
    add_query(queries, first_query, "F07", options_type, options_size, options_layout, options_hr, number(options.TiledResourcesTier));
    add_query(queries, first_query, "F08", options_type, options_size, options_layout, options_hr, number(options.ConservativeRasterizationTier));
    add_query(queries, first_query, "F15", options_type, options_size, options_layout, options_hr, boolean(options.OutputMergerLogicOp));
    add_query(queries, first_query, "F16", options_type, options_size, options_layout, options_hr,
              boolean(options.VPAndRTArrayIndexFromAnyShaderFeedingRasterizerSupportedWithoutGSEmulation));
    add_query(queries, first_query, "H02", options_type, options_size, options_layout, options_hr, boolean(options.ROVsSupported));

    D3D12_FEATURE_DATA_D3D12_OPTIONS1 options1{};
    HRESULT options1_hr = device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS1, &options1, sizeof(options1));
    const char* options1_type = "D3D12_FEATURE_DATA_D3D12_OPTIONS1";
    const size_t options1_size = sizeof(options1);
    const auto options1_layout = layout(options1_type, options1_size, pointer_bits);
    add_query(queries, first_query, "F14", options1_type, options1_size, options1_layout, options1_hr, boolean(options1.WaveOps));
    add_query(queries, first_query, "F20", options1_type, options1_size, options1_layout, options1_hr, boolean(options1.Int64ShaderOps));

    D3D12_FEATURE_DATA_D3D12_OPTIONS2 options2{};
    HRESULT options2_hr = device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS2, &options2, sizeof(options2));
    const char* options2_type = "D3D12_FEATURE_DATA_D3D12_OPTIONS2";
    add_query(queries, first_query, "F10", options2_type, sizeof(options2), layout(options2_type, sizeof(options2), pointer_bits), options2_hr,
              boolean(options2.DepthBoundsTestSupported));

    D3D12_FEATURE_DATA_D3D12_OPTIONS3 options3{};
    HRESULT options3_hr = device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS3, &options3, sizeof(options3));
    const char* options3_type = "D3D12_FEATURE_DATA_D3D12_OPTIONS3";
    const size_t options3_size = sizeof(options3);
    const auto options3_layout = layout(options3_type, options3_size, pointer_bits);
    add_query(queries, first_query, "F11", options3_type, options3_size, options3_layout, options3_hr, number(options3.WriteBufferImmediateSupportFlags));
    add_query(queries, first_query, "F17", options3_type, options3_size, options3_layout, options3_hr, boolean(options3.CopyQueueTimestampQueriesSupported));
    add_query(queries, first_query, "F18", options3_type, options3_size, options3_layout, options3_hr, boolean(options3.CastingFullyTypedFormatSupported));

    D3D12_FEATURE_DATA_D3D12_OPTIONS5 options5{};
    HRESULT options5_hr = device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5, &options5, sizeof(options5));
    const char* options5_type = "D3D12_FEATURE_DATA_D3D12_OPTIONS5";
    add_query(queries, first_query, "F02", options5_type, sizeof(options5), layout(options5_type, sizeof(options5), pointer_bits), options5_hr,
              number(options5.RaytracingTier));

    D3D12_FEATURE_DATA_D3D12_OPTIONS6 options6{};
    HRESULT options6_hr = device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS6, &options6, sizeof(options6));
    const char* options6_type = "D3D12_FEATURE_DATA_D3D12_OPTIONS6";
    add_query(queries, first_query, "F03", options6_type, sizeof(options6), layout(options6_type, sizeof(options6), pointer_bits), options6_hr,
              number(options6.VariableShadingRateTier));

    D3D12_FEATURE_DATA_D3D12_OPTIONS7 options7{};
    HRESULT options7_hr = device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS7, &options7, sizeof(options7));
    const char* options7_type = "D3D12_FEATURE_DATA_D3D12_OPTIONS7";
    const size_t options7_size = sizeof(options7);
    const auto options7_layout = layout(options7_type, options7_size, pointer_bits);
    add_query(queries, first_query, "F04", options7_type, options7_size, options7_layout, options7_hr, number(options7.MeshShaderTier));
    add_query(queries, first_query, "F05", options7_type, options7_size, options7_layout, options7_hr, number(options7.SamplerFeedbackTier));

    D3D12_FEATURE_DATA_D3D12_OPTIONS8 options8{};
    HRESULT options8_hr = device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS8, &options8, sizeof(options8));
    const char* options8_type = "D3D12_FEATURE_DATA_D3D12_OPTIONS8";
    add_query(queries, first_query, "F19", options8_type, sizeof(options8), layout(options8_type, sizeof(options8), pointer_bits), options8_hr,
              boolean(options8.UnalignedBlockTexturesSupported));

    D3D12_FEATURE_DATA_ROOT_SIGNATURE root_signature{};
    root_signature.HighestVersion = D3D_ROOT_SIGNATURE_VERSION_1_1;
    HRESULT root_hr = device->CheckFeatureSupport(D3D12_FEATURE_ROOT_SIGNATURE, &root_signature, sizeof(root_signature));
    const char* root_type = "D3D12_FEATURE_DATA_ROOT_SIGNATURE";
    add_query(queries, first_query, "F09", root_type, sizeof(root_signature), layout(root_type, sizeof(root_signature), pointer_bits), root_hr,
              number(root_signature.HighestVersion));

    D3D12_FEATURE_DATA_GPU_VIRTUAL_ADDRESS_SUPPORT va{};
    HRESULT va_hr = device->CheckFeatureSupport(D3D12_FEATURE_GPU_VIRTUAL_ADDRESS_SUPPORT, &va, sizeof(va));
    const char* va_type = "D3D12_FEATURE_DATA_GPU_VIRTUAL_ADDRESS_SUPPORT";
    std::string va_value = "{\"resource_bits\":" + number(va.MaxGPUVirtualAddressBitsPerResource) +
                           ",\"process_bits\":" + number(va.MaxGPUVirtualAddressBitsPerProcess) + "}";
    const size_t va_size = sizeof(va);
    add_query(queries, first_query, "F12", va_type, va_size, layout(va_type, va_size, pointer_bits), va_hr, va_value);
    add_query(queries, first_query, "F13", va_type, va_size, layout(va_type, va_size, pointer_bits), va_hr, va_value);

    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_12_2, D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_0};
    D3D12_FEATURE_DATA_FEATURE_LEVELS level_data{};
    level_data.NumFeatureLevels = static_cast<UINT>(_countof(levels));
    level_data.pFeatureLevelsRequested = levels;
    HRESULT level_hr = device->CheckFeatureSupport(D3D12_FEATURE_FEATURE_LEVELS, &level_data, sizeof(level_data));
    const bool reports_122 = SUCCEEDED(level_hr) && level_data.MaxSupportedFeatureLevel >= D3D_FEATURE_LEVEL_12_2;
    ID3D12Device* device_122 = nullptr;
    HRESULT create_122_hr = D3D12CreateDevice(selected, D3D_FEATURE_LEVEL_12_2,
                                              IID_PPV_ARGS(&device_122));
    if (device_122) device_122->Release();
    char create_hr[16]{};
    std::snprintf(create_hr, sizeof(create_hr), "0x%08lX", static_cast<unsigned long>(create_122_hr));
    add_query(queries, first_query, "F23", "D3D12_FEATURE_DATA_FEATURE_LEVELS", sizeof(level_data),
              layout("D3D12_FEATURE_DATA_FEATURE_LEVELS", sizeof(level_data), pointer_bits),
              S_OK,
              "{\"create_device_hresult\":" + quote(create_hr) +
              ",\"device_created\":" + std::string(SUCCEEDED(create_122_hr) ? "true" : "false") + "}");
    queries += "}";

    char luid_text[24]{};
    std::snprintf(luid_text, sizeof(luid_text), "%08lX:%08lX",
                  static_cast<unsigned long>(selected_desc.AdapterLuid.HighPart),
                  static_cast<unsigned long>(selected_desc.AdapterLuid.LowPart));
    std::string json = "{\"schema_version\":1,\"source_fingerprint\":" + quote(source_fingerprint) +
        ",\"adapter\":{\"name\":" + quote(helios_fullstack::utf8(selected_desc.Description)) +
        ",\"luid\":" + quote(luid_text) + "},\"architecture\":" +
        quote(pointer_bits == 64 ? "x64" : "x86") + ",\"pointer_bits\":" + number(pointer_bits) +
        ",\"queries\":" + queries + ",\"feature_level_query\":{\"status\":" +
        quote(SUCCEEDED(level_hr) ? "QUERIED" : "QUERY_FAILED") + ",\"max\":" +
        number(static_cast<unsigned>(level_data.MaxSupportedFeatureLevel)) +
        ",\"reports_12_2\":" + (reports_122 ? "true" : "false") +
        ",\"create_12_2_hresult\":" + quote(create_hr) + "},\"layouts\":" + layouts + "}";

    FILE* output = nullptr;
    if (fopen_s(&output, output_path, "wb") != 0 || !output) {
        device->Release(); selected->Release(); factory->Release();
        std::fprintf(stderr, "cannot open output path\n");
        return 6;
    }
    std::fwrite(json.data(), 1, json.size(), output);
    std::fwrite("\n", 1, 1, output);
    std::fclose(output);
    device->Release();
    selected->Release();
    factory->Release();
    return SUCCEEDED(level_hr) ? 0 : 7;
}
