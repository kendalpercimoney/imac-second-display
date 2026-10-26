// This file is part of LanScreen.
// Copyright (C) 2026 Kendal Percimoney
//
// LanScreen is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
//
// LanScreen is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with
// this program. If not, see <https://www.gnu.org/licenses/>.

// LanScreen client for Windows 7, phase 0: show the stream, measure it.
//
//   lanscreen.exe [-host 10.0.0.1] [-videoPort 5000] [-controlPort 5001] [-windowed]
//
// Esc quits. Everything worth knowing goes to lanscreen.log beside the program,
// and the numbers go to the host, whose panel shows them as for the Mac client.

#include "lswin.h"
#include <libavutil/frame.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ log */

static FILE *log_file;
static CRITICAL_SECTION log_lock;
static LARGE_INTEGER counter_frequency;

uint64_t ls_now_us(void) {
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (uint64_t)(now.QuadPart / counter_frequency.QuadPart * 1000000
                      + now.QuadPart % counter_frequency.QuadPart * 1000000 / counter_frequency.QuadPart);
}

void ls_log_open(void) {
    QueryPerformanceFrequency(&counter_frequency);
    InitializeCriticalSection(&log_lock);
    char path[MAX_PATH];
    DWORD length = GetModuleFileNameA(NULL, path, MAX_PATH);
    while (length > 0 && path[length - 1] != '\\') length--;
    snprintf(path + length, sizeof(path) - length, "lanscreen.log");
    log_file = fopen(path, "w");
}

void ls_log(const char *format, ...) {
    char line[1024];
    SYSTEMTIME t;
    GetLocalTime(&t);
    int used = snprintf(line, sizeof(line), "%02d:%02d:%02d.%03d  ", t.wHour, t.wMinute, t.wSecond,
                        t.wMilliseconds);
    va_list args;
    va_start(args, format);
    vsnprintf(line + used, sizeof(line) - used, format, args);
    va_end(args);
    EnterCriticalSection(&log_lock);
    if (log_file) { fprintf(log_file, "%s\n", line); fflush(log_file); }
    LeaveCriticalSection(&log_lock);
    OutputDebugStringA(line);
    OutputDebugStringA("\n");
}

/* ----------------------------------------------------------------- app */

typedef struct {
    LSDisplay *display;
    LSNetwork *network;
    LSDecode *decode;
    HANDLE frame_ready;
    CRITICAL_SECTION frame_lock;
    AVFrame *pending;       /* the newest picture not yet shown */
    volatile LONG streaming;
    uint32_t frames_shown, frames_replaced;
} App;

static App app;

/* Decoding thread: keep only the newest picture. One that is replaced before
 * it is drawn is simply not shown -- nothing depends on a picture having been
 * displayed, only on its having been decoded, so this is not a gap. */
static void frame_decoded(void *context, const AVFrame *frame) {
    (void)context;
    EnterCriticalSection(&app.frame_lock);
    if (app.pending->buf[0]) { av_frame_unref(app.pending); app.frames_replaced++; }
    av_frame_ref(app.pending, frame);
    LeaveCriticalSection(&app.frame_lock);
    SetEvent(app.frame_ready);
}

/* Receive thread. */
static void unit_received(void *context, const uint8_t *annexb, size_t length,
                          uint32_t timestamp, int is_keyframe) {
    (void)context;
    ls_decode_submit(app.decode, annexb, length, timestamp, is_keyframe);
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    switch (message) {
    case WM_KEYDOWN:
        if (w == VK_ESCAPE) PostQuitMessage(0);
        return 0;
    case WM_SETCURSOR:
        // The pointer is in the video, burned in by the host.
        SetCursor(NULL);
        return TRUE;
    case WM_CLOSE:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(window, message, w, l);
}

static const char *argument(const char *name, const char *fallback) {
    for (int i = 1; i + 1 < __argc; i++)
        if (_stricmp(__argv[i], name) == 0) return __argv[i + 1];
    return fallback;
}

static int flag(const char *name) {
    for (int i = 1; i < __argc; i++)
        if (_stricmp(__argv[i], name) == 0) return 1;
    return 0;
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR command_line, int show) {
    (void)previous; (void)command_line; (void)show;
    ls_log_open();
    // Real pixels, not ones scaled for a high-DPI setting.
    SetProcessDPIAware();

    const char *host = argument("-host", "10.0.0.1");
    uint16_t video_port = (uint16_t)atoi(argument("-videoPort", "5000"));
    uint16_t control_port = (uint16_t)atoi(argument("-controlPort", "5001"));
    int windowed = flag("-windowed");
    int screen_width = GetSystemMetrics(SM_CXSCREEN), screen_height = GetSystemMetrics(SM_CYSCREEN);
    OSVERSIONINFOA os;
    memset(&os, 0, sizeof(os));
    os.dwOSVersionInfoSize = sizeof(os);
    GetVersionExA(&os);
    ls_log("LanScreen for Windows, phase 0; Windows %lu.%lu build %lu %s; host %s, video port %u, control port %u",
           os.dwMajorVersion, os.dwMinorVersion, os.dwBuildNumber, os.szCSDVersion, host,
           (unsigned)video_port, (unsigned)control_port);

    WNDCLASSA wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = window_proc;
    wc.hInstance = instance;
    wc.lpszClassName = "LanScreen";
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    RegisterClassA(&wc);
    HWND window = CreateWindowExA(WS_EX_TOPMOST, "LanScreen", "LanScreen", WS_POPUP | WS_VISIBLE,
                                  0, 0, screen_width, screen_height, NULL, NULL, instance, NULL);

    char error[512];
    app.display = ls_display_create(window, windowed, error, sizeof(error));
    if (!app.display) {
        ls_log("%s", error);
        MessageBoxA(NULL, error, "LanScreen", MB_ICONERROR);
        return 1;
    }
    char waiting[512];
    snprintf(waiting, sizeof(waiting),
             "Waiting for the Mac at %s\n\nStart streaming from LanScreen in its menu bar.\n"
             "Esc quits. Details are in lanscreen.log.", host);
    ls_display_show_message(app.display, waiting);

    app.frame_ready = CreateEventA(NULL, FALSE, FALSE, NULL);
    InitializeCriticalSection(&app.frame_lock);
    app.pending = av_frame_alloc();

    LSNetworkConfig config = {host, video_port, control_port, (uint16_t)screen_width, (uint16_t)screen_height};
    app.network = ls_network_start(&config, unit_received, NULL, error, sizeof(error));
    if (!app.network) {
        ls_log("%s", error);
        ls_display_show_message(app.display, error);
        MessageBoxA(window, error, "LanScreen", MB_ICONERROR);
        ls_display_destroy(app.display);
        return 1;
    }
    app.decode = ls_decode_start(ls_display_hw_device(app.display), frame_decoded, NULL, app.network);
    if (!app.decode || !app.pending || !app.frame_ready) {
        ls_log("out of memory");
        return 1;
    }
    ls_network_send_hello(app.network);

    AVFrame *showing = av_frame_alloc();
    uint64_t next_tick = ls_now_us() + 1000000;
    int ticks = 0, running = 1;
    while (running) {
        DWORD wait = MsgWaitForMultipleObjectsEx(1, &app.frame_ready, 100, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (wait == WAIT_OBJECT_0) {
            EnterCriticalSection(&app.frame_lock);
            av_frame_move_ref(showing, app.pending);
            LeaveCriticalSection(&app.frame_lock);
            if (showing->buf[0]) {
                if (!app.streaming) {
                    app.streaming = 1;
                    // Keep the screen on while there is a picture to look at.
                    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
                    ls_log("stream started");
                }
                if (ls_display_show_frame(app.display, showing) != 0) running = 0;
                app.frames_shown++;
                // Straight back to the decoder's pool.
                av_frame_unref(showing);
            }
        }
        MSG message;
        while (PeekMessageA(&message, NULL, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) running = 0;
            TranslateMessage(&message);
            DispatchMessageA(&message);
        }

        uint64_t now = ls_now_us();
        if (now < next_tick) continue;
        next_tick = now + 1000000;
        ticks++;

        // A frame whose tail was lost just before the screen went still never
        // finishes, and nothing else will reveal it. Only a keyframe repairs it.
        if (app.streaming && ls_network_partial_frame_ms(app.network) > 500)
            ls_network_request_keyframe(app.network);

        // The host pings every second, so four seconds of silence is gone.
        int64_t quiet = ls_network_ms_since_contact(app.network);
        if (app.streaming && quiet > 4000) {
            app.streaming = 0;
            SetThreadExecutionState(ES_CONTINUOUS);
            ls_log("the host went quiet; waiting for it");
            ls_network_reset_stream(app.network);
            ls_decode_reset(app.decode);
            ls_display_show_message(app.display, waiting);
        }

        ls_stats stats;
        memset(&stats, 0, sizeof(stats));
        ls_network_counters(app.network, &stats);
        ls_decode_counters(app.decode, &stats);
        stats.render_us = ls_display_render_us(app.display);
        stats.decoder_flags |= ls_display_colour_flags(app.display);
        ls_network_send_stats(app.network, &stats);
        // Until the picture arrives, keep saying hello: the host forces a
        // keyframe each time it hears one, so starting in either order works.
        if (!app.streaming) ls_network_send_hello(app.network);

        if (ticks % 10 == 0 && app.streaming)
            ls_log("decoded %u, shown %u (%u replaced before drawing), dropped %u, corrupt %u; "
                   "packets %u, lost %u; decode %.2f ms, render %.2f ms, %s",
                   stats.frames_decoded, app.frames_shown, app.frames_replaced, stats.frames_dropped,
                   stats.frames_corrupt, stats.packets_received, stats.packets_lost,
                   stats.decode_us / 1000.0, stats.render_us / 1000.0,
                   stats.decoder_flags & LS_DECODER_HARDWARE ? "hardware" : "software");
    }

    ls_log("quitting");
    // In this order: the receiver feeds the decoder, and the decoder asks the
    // network for keyframes.
    ls_network_stop_video(app.network);
    ls_decode_stop(app.decode);
    ls_network_stop(app.network);
    av_frame_free(&showing);
    av_frame_free(&app.pending);
    ls_display_destroy(app.display);
    SetThreadExecutionState(ES_CONTINUOUS);
    return 0;
}
