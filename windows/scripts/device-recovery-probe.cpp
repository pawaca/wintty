// Standalone integration probe for the embedded DLL. Removes only this
// process's D3D12 device, never the adapter or another process's device.
// Usage: device-recovery-probe.exe <absolute ghostty.dll path>
#include <windows.h>
#include <d3d12.h>
#include <cstdio>
#include <cstring>
#include <atomic>
#include "../../include/ghostty.h"
#pragma comment(lib, "d3d12.lib")

#define IMPORT(name) auto p_##name = reinterpret_cast<decltype(&name)>(GetProcAddress(dll, #name)); if (!p_##name) return 90
static void wake(void*) {}
static std::atomic<int> abandoned_count{0};
static bool action(ghostty_app_t, ghostty_target_s, ghostty_action_s a) {
    if (a.tag == GHOSTTY_ACTION_RENDERER_HEALTH && a.action.renderer_health == GHOSTTY_RENDERER_HEALTH_ABANDONED) ++abandoned_count;
    return true;
}
static ghostty_clipboard_read_result_e read_clipboard(void*, ghostty_clipboard_e, void*, const char* const*, size_t, bool) { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE; }
static void confirm_clipboard(void*, const ghostty_clipboard_confirm_s*, void*, ghostty_clipboard_request_e) {}
static void write_clipboard(void*, ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool) {}
static void receive(void*, const uint8_t*, size_t) {}
static void resized(void*, uint16_t, uint16_t, uint32_t, uint32_t) {}
static void log_message(uint32_t level, const char* scope, uintptr_t scope_len, const char* message, uintptr_t message_len, void*) {
    if (level >= 2) { std::fprintf(stderr, "%.*s: %.*s\n", int(scope_len), scope, int(message_len), message); std::fflush(stderr); }
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) return 91;
    HMODULE dll = LoadLibraryW(argv[1]);
    if (!dll) { std::printf("load_error=%lu\n", GetLastError()); return 92; }
    IMPORT(ghostty_init); IMPORT(ghostty_log_set_callback);
    IMPORT(ghostty_config_new); IMPORT(ghostty_config_finalize); IMPORT(ghostty_config_free);
    IMPORT(ghostty_app_new); IMPORT(ghostty_app_free); IMPORT(ghostty_app_tick);
    IMPORT(ghostty_surface_config_new); IMPORT(ghostty_surface_new); IMPORT(ghostty_surface_free);
    IMPORT(ghostty_surface_set_occlusion); IMPORT(ghostty_surface_write_buffer);
    IMPORT(ghostty_surface_get_d3d12_device); IMPORT(ghostty_surface_shared_texture);
    p_ghostty_log_set_callback(log_message, nullptr);
    if (p_ghostty_init(0, nullptr) != 0) return 93;
    auto cfg = p_ghostty_config_new(); if (!cfg) return 94;
    // Intentionally do not load the user's configuration or start any process.
    p_ghostty_config_finalize(cfg);
    ghostty_runtime_config_s runtime{};
    runtime.wakeup_cb = wake; runtime.action_cb = action;
    runtime.read_clipboard_cb = read_clipboard; runtime.confirm_read_clipboard_cb = confirm_clipboard; runtime.write_clipboard_cb = write_clipboard;
    auto app = p_ghostty_app_new(&runtime, cfg); if (!app) return 95;
    auto make = [&]() {
        auto opts = p_ghostty_surface_config_new();
        opts.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
        opts.platform.windows.shared_texture = {true, 320, 160};
        opts.scale_factor = 1; opts.font_size = 12; opts.width = 320; opts.height = 160;
        opts.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED;
        opts.receive_buffer = receive; opts.receive_resize = resized;
        auto s = p_ghostty_surface_new(app, &opts);
        if (s) { const char* text = "device recovery probe\r\n"; p_ghostty_surface_write_buffer(s, reinterpret_cast<const uint8_t*>(text), std::strlen(text)); }
        return s;
    };
    auto pump = [&](DWORD ms) { ULONGLONG end = GetTickCount64() + ms; do { p_ghostty_app_tick(app); Sleep(20); } while (GetTickCount64() < end); };
    auto version = [&](ghostty_surface_t s) { ghostty_surface_shared_texture_s state{}; p_ghostty_surface_shared_texture(s, &state); return state.version; };
    auto remove = [&](ghostty_surface_t s) {
        auto dev = static_cast<ID3D12Device*>(p_ghostty_surface_get_d3d12_device(s));
        if (!dev) return false;
        ID3D12Device5* control = nullptr;
        if (FAILED(dev->QueryInterface(IID_PPV_ARGS(&control)))) return false;
        control->RemoveDevice(); control->Release(); return true;
    };
    auto live = make(), hidden = make();
    if (!live || !hidden) return 96;
    pump(1500); p_ghostty_surface_set_occlusion(hidden, false); pump(300);
    auto old_live = version(live), old_hidden = version(hidden);
    if (!old_live || !old_hidden || !remove(live)) return 97;
    pump(6000);
    auto live_dev = static_cast<ID3D12Device*>(p_ghostty_surface_get_d3d12_device(live));
    bool recovered = live_dev && SUCCEEDED(live_dev->GetDeviceRemovedReason()) && version(live) > old_live;
    bool hidden_released = p_ghostty_surface_get_d3d12_device(hidden) == nullptr;
    std::printf("visible_recovered=%d hidden_released=%d\n", recovered, hidden_released); std::fflush(stdout);
    if (!recovered || !hidden_released) return 10;
    p_ghostty_surface_set_occlusion(hidden, true); pump(2000);
    bool restored = version(hidden) > old_hidden;
    std::printf("hidden_restored=%d\n", restored); std::fflush(stdout);
    if (!restored) return 11;
    // A loss while every surface is hidden must release all references too.
    p_ghostty_surface_set_occlusion(live, false); p_ghostty_surface_set_occlusion(hidden, false); pump(200);
    if (!remove(live)) return 98;
    pump(3000);
    bool all_released = !p_ghostty_surface_get_d3d12_device(live) && !p_ghostty_surface_get_d3d12_device(hidden);
    std::printf("all_hidden_released=%d\n", all_released); std::fflush(stdout);
    if (!all_released) return 12;
    p_ghostty_surface_set_occlusion(live, true); p_ghostty_surface_set_occlusion(hidden, true); pump(2000);
    bool both_restored = p_ghostty_surface_get_d3d12_device(live) && p_ghostty_surface_get_d3d12_device(hidden);
    std::printf("both_restored=%d\n", both_restored); std::fflush(stdout);
    if (!both_restored) return 13;
    p_ghostty_surface_free(hidden);
    // Exhaust the existing rapid-loss budget. An abandoned surface must
    // release its final backend reference so a new surface can still work.
    bool abandoned_released = false;
    for (int loss = 0; loss < 4; ++loss) {
        if (!remove(live)) return 99;
        pump(2500);
        if (abandoned_count.load() > 0) {
            abandoned_released = !p_ghostty_surface_get_d3d12_device(live);
            break;
        }
    }
    auto fresh = make();
    pump(1500);
    bool fresh_created = fresh && p_ghostty_surface_get_d3d12_device(fresh);
    std::printf("abandoned_released=%d fresh_created=%d\n", abandoned_released, fresh_created); std::fflush(stdout);
    if (fresh) p_ghostty_surface_free(fresh);
    p_ghostty_surface_free(live);
    p_ghostty_app_free(app); p_ghostty_config_free(cfg);
    // The DLL has process-lifetime background work; let normal process exit
    // unload it after all surfaces and the app have been released.
    return abandoned_released && fresh_created ? 0 : 14;
}
