#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <cstdio>
#include <string>

namespace helios_fullstack {

inline std::string utf8(const wchar_t* value) {
    if (!value || !*value) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) return {};
    std::string result(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value, -1, &result[0], size, nullptr, nullptr);
    result.pop_back();
    return result;
}

inline std::string json_string(const std::string& value) {
    std::string result;
    result.reserve(value.size() + 2);
    result.push_back('"');
    for (const unsigned char ch : value) {
        switch (ch) {
        case '"': result += "\\\""; break;
        case '\\': result += "\\\\"; break;
        case '\b': result += "\\b"; break;
        case '\f': result += "\\f"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default:
            if (ch < 0x20) {
                char escaped[7]{};
                std::snprintf(escaped, sizeof(escaped), "\\u%04x", ch);
                result += escaped;
            } else {
                result.push_back(static_cast<char>(ch));
            }
        }
    }
    result.push_back('"');
    return result;
}

inline void print_result(const char* api, const wchar_t* adapter, LUID luid, HRESULT hr) {
    char luid_text[24]{};
    std::snprintf(luid_text, sizeof(luid_text), "%08lX:%08lX",
                  static_cast<unsigned long>(luid.HighPart),
                  static_cast<unsigned long>(luid.LowPart));
    const std::string adapter_utf8 = utf8(adapter);
    std::printf("HELIOS_PROBE_RESULT={\"schema_version\":1,\"api\":%s,\"adapter\":%s,\"luid\":%s,\"hr\":\"0x%08lX\",\"created\":%s}\n",
                json_string(api).c_str(), json_string(adapter_utf8).c_str(),
                json_string(luid_text).c_str(), static_cast<unsigned long>(hr),
                SUCCEEDED(hr) ? "true" : "false");
    std::fflush(stdout);
}

} // namespace helios_fullstack
