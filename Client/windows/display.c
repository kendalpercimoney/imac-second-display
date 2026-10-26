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

// Showing the picture: Direct3D 9Ex, and the DXVA2 video processor.
//
// The decoder writes into DXVA2 surfaces on this device, and the video
// processor converts them to RGB straight into the back buffer, so a picture
// never leaves the GPU. The conversion is told explicitly that the stream is
// BT.709 at video range, which is what the host's VUI says and what its capture
// produces. Left to guess, a video processor goes by the picture size or by
// nothing at all, and drivers differ; guessing BT.601 shifts foliage and skin
// by over ten code values.
//
// Telling it is not the same as it listening, so the first picture is
// preceded by a check: known colours, encoded as BT.709, through the same
// processor, read back and compared. The result goes to the host in STATS,
// which warns if it is off, as it does for the Mac client.
//
// Exclusive fullscreen by default, so the picture does not go through the
// desktop compositor and pick up a frame of its latency. A frame latency of
// one keeps Direct3D from queueing three frames ahead, which is its default.

#define COBJMACROS
#include "lswin.h"
#include <initguid.h>
#include <d3d9.h>
#include <dxva2api.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_dxva2.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FOURCC_NV12 ((D3DFORMAT)MAKEFOURCC('N', 'V', '1', '2'))

struct LSDisplay {
    HWND window;
    int windowed, width, height;
    IDirect3D9Ex *d3d;
    IDirect3DDevice9Ex *device;
    IDirect3DDeviceManager9 *manager;
    UINT reset_token;
    AVBufferRef *hw_device;
    IDirectXVideoProcessorService *service;

    /* Rebuilt whenever the incoming pictures change size. */
    IDirectXVideoProcessor *processor;
    UINT processor_width, processor_height;
    D3DFORMAT processor_format;
    DXVA2_VideoDesc desc;
    DXVA2_ProcAmpValues procamp;

    /* For pictures from the software decoder. */
    IDirect3DSurface9 *upload;
    UINT upload_width, upload_height;

    LONGLONG frame_time;
    double render_average;
    volatile uint32_t render_us, colour_flags;
    int colour_checked;
};

/* The same twelve colours the Mac client's check and Tests/LoopSend use:
 * mid-tones, because those are what a wrong matrix moves. */
static const int kPatches[12][3] = {
    {200, 120,  80}, { 80, 160,  80}, { 90, 150, 210}, {128, 128, 128},
    { 30,  30,  30}, {230, 230, 230}, {200,  40,  40}, { 40, 160, 160},
    {220, 200,  60}, {120,  60, 160}, {230, 140,  40}, {110,  80,  50},
};

static DXVA2_ExtendedFormat stream_format(void) {
    DXVA2_ExtendedFormat f;
    memset(&f, 0, sizeof(f));
    f.SampleFormat = DXVA2_SampleProgressiveFrame;
    f.VideoChromaSubsampling = DXVA2_VideoChromaSubsampling_MPEG2;
    f.NominalRange = DXVA2_NominalRange_16_235;
    f.VideoTransferMatrix = DXVA2_VideoTransferMatrix_BT709;
    f.VideoLighting = DXVA2_VideoLighting_dim;
    f.VideoPrimaries = DXVA2_VideoPrimaries_BT709;
    f.VideoTransferFunction = DXVA2_VideoTransFunc_sRGB;
    return f;
}

static DXVA2_Fixed32 opaque(void) {
    DXVA2_Fixed32 a;
    a.Fraction = 0;
    a.Value = 1;
    return a;
}

static void release_processor(LSDisplay *d) {
    if (d->processor) IDirectXVideoProcessor_Release(d->processor);
    d->processor = NULL;
    d->processor_width = d->processor_height = 0;
}

/* A video processor for pictures of this size and format, converting to the
 * back buffer's RGB. The progressive device is the plain one: no deinterlacing
 * to get wrong, and nothing to add latency. */
static int ensure_processor(LSDisplay *d, UINT width, UINT height, D3DFORMAT format) {
    if (d->processor && d->processor_width == width && d->processor_height == height
        && d->processor_format == format)
        return 0;
    release_processor(d);

    memset(&d->desc, 0, sizeof(d->desc));
    d->desc.SampleWidth = width;
    d->desc.SampleHeight = height;
    d->desc.SampleFormat = stream_format();
    d->desc.Format = format;
    d->desc.InputSampleFreq.Numerator = 60;
    d->desc.InputSampleFreq.Denominator = 1;
    d->desc.OutputFrameFreq = d->desc.InputSampleFreq;

    UINT count = 0;
    GUID *guids = NULL;
    HRESULT hr = IDirectXVideoProcessorService_GetVideoProcessorDeviceGuids(d->service, &d->desc, &count, &guids);
    if (FAILED(hr) || count == 0) {
        ls_log("no video processor takes %ux%u pictures (0x%08lx)", width, height, (unsigned long)hr);
        return -1;
    }
    GUID chosen = guids[0];
    for (UINT i = 0; i < count; i++)
        if (IsEqualGUID(&guids[i], &DXVA2_VideoProcProgressiveDevice)) chosen = guids[i];
    CoTaskMemFree(guids);

    hr = IDirectXVideoProcessorService_CreateVideoProcessor(d->service, &chosen, &d->desc,
                                                            D3DFMT_X8R8G8B8, 0, &d->processor);
    if (FAILED(hr)) {
        ls_log("could not create a video processor (0x%08lx)", (unsigned long)hr);
        return -1;
    }

    // Brightness, contrast, hue and saturation at the driver's defaults. Left
    // at zero, contrast zero is a black picture.
    DXVA2_ValueRange range;
    const UINT amps[4] = {DXVA2_ProcAmp_Brightness, DXVA2_ProcAmp_Contrast,
                          DXVA2_ProcAmp_Hue, DXVA2_ProcAmp_Saturation};
    DXVA2_Fixed32 *values[4] = {&d->procamp.Brightness, &d->procamp.Contrast,
                                &d->procamp.Hue, &d->procamp.Saturation};
    for (int i = 0; i < 4; i++) {
        memset(values[i], 0, sizeof(DXVA2_Fixed32));
        if (SUCCEEDED(IDirectXVideoProcessorService_GetProcAmpRange(d->service, &chosen, &d->desc,
                                                                    D3DFMT_X8R8G8B8, amps[i], &range)))
            *values[i] = range.DefaultValue;
        else if (amps[i] == DXVA2_ProcAmp_Contrast || amps[i] == DXVA2_ProcAmp_Saturation)
            values[i]->Value = 1;
    }

    d->processor_width = width;
    d->processor_height = height;
    d->processor_format = format;
    ls_log("video processor ready for %ux%u %s", width, height,
           IsEqualGUID(&chosen, &DXVA2_VideoProcProgressiveDevice) ? "(progressive device)" : "(driver's choice)");
    return 0;
}

/* The picture's rectangle on screen: as large as fits, same shape. */
static RECT fit(const LSDisplay *d, int width, int height) {
    RECT r = {0, 0, d->width, d->height};
    if ((int64_t)width * d->height > (int64_t)height * d->width) {
        int h = (int)((int64_t)d->width * height / width);
        r.top = (d->height - h) / 2;
        r.bottom = r.top + h;
    } else if ((int64_t)width * d->height < (int64_t)height * d->width) {
        int w = (int)((int64_t)d->height * width / height);
        r.left = (d->width - w) / 2;
        r.right = r.left + w;
    }
    return r;
}

static HRESULT blit(LSDisplay *d, IDirect3DSurface9 *source, int width, int height,
                    IDirect3DSurface9 *target, RECT target_rect, int target_width, int target_height) {
    DXVA2_VideoProcessBltParams params;
    memset(&params, 0, sizeof(params));
    params.TargetFrame = d->frame_time;
    params.TargetRect = target_rect;
    params.ConstrictionSize.cx = target_width;
    params.ConstrictionSize.cy = target_height;
    params.BackgroundColor.Y = 0x1000;          // black, in video-range YCbCr
    params.BackgroundColor.Cb = 0x8000;
    params.BackgroundColor.Cr = 0x8000;
    params.BackgroundColor.Alpha = 0xFFFF;
    params.DestFormat = stream_format();
    params.DestFormat.NominalRange = DXVA2_NominalRange_0_255;
    params.ProcAmpValues = d->procamp;
    params.Alpha = opaque();

    DXVA2_VideoSample sample;
    memset(&sample, 0, sizeof(sample));
    sample.Start = d->frame_time;
    sample.End = d->frame_time + 166667;
    sample.SampleFormat = stream_format();
    sample.SrcSurface = source;
    SetRect(&sample.SrcRect, 0, 0, width, height);
    sample.DstRect = target_rect;
    sample.PlanarAlpha = opaque();
    d->frame_time += 166667;

    return IDirectXVideoProcessor_VideoProcessBlt(d->processor, target, &params, &sample, 1, NULL);
}

/* Fills an NV12 surface with the twelve patches, encoded the way the host
 * encodes: BT.709, video range. */
static int fill_patches(IDirect3DSurface9 *surface, int width, int height) {
    D3DLOCKED_RECT locked;
    if (FAILED(IDirect3DSurface9_LockRect(surface, &locked, NULL, 0))) return -1;
    uint8_t *luma = (uint8_t *)locked.pBits;
    uint8_t *chroma = luma + (size_t)locked.Pitch * height;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            const int *c = kPatches[(y * 3 / height) * 4 + x * 4 / width];
            double r = c[0] / 255.0, g = c[1] / 255.0, b = c[2] / 255.0;
            double Y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            luma[(size_t)y * locked.Pitch + x] = (uint8_t)lround(16 + 219 * Y);
            if ((y & 1) == 0 && (x & 1) == 0) {
                uint8_t *uv = chroma + (size_t)(y / 2) * locked.Pitch + x;
                uv[0] = (uint8_t)lround(128 + 224 * (b - Y) / 1.8556);
                uv[1] = (uint8_t)lround(128 + 224 * (r - Y) / 1.5748);
            }
        }
    }
    IDirect3DSurface9_UnlockRect(surface);
    return 0;
}

/* Puts the patches through the video processor exactly as a picture would go,
 * reads the result back, and records the worst channel error. */
static void check_colour(LSDisplay *d, int width, int height) {
    d->colour_checked = 1;
    IDirect3DSurface9 *patches = NULL, *target = NULL, *readback = NULL;
    int worst = -1;
    if (FAILED(IDirect3DDevice9Ex_CreateOffscreenPlainSurface(d->device, width, height, FOURCC_NV12,
                                                              D3DPOOL_DEFAULT, &patches, NULL))
        || fill_patches(patches, width, height) != 0
        || FAILED(IDirect3DDevice9Ex_CreateRenderTarget(d->device, width, height, D3DFMT_X8R8G8B8,
                                                        D3DMULTISAMPLE_NONE, 0, FALSE, &target, NULL))
        || FAILED(IDirect3DDevice9Ex_CreateOffscreenPlainSurface(d->device, width, height, D3DFMT_X8R8G8B8,
                                                                 D3DPOOL_SYSTEMMEM, &readback, NULL))
        || ensure_processor(d, width, height, FOURCC_NV12) != 0) {
        ls_log("colour check: could not set up");
        goto done;
    }
    RECT whole = {0, 0, width, height};
    if (FAILED(blit(d, patches, width, height, target, whole, width, height))
        || FAILED(IDirect3DDevice9Ex_GetRenderTargetData(d->device, target, readback))) {
        ls_log("colour check: the video processor would not convert the patches");
        goto done;
    }
    D3DLOCKED_RECT locked;
    if (FAILED(IDirect3DSurface9_LockRect(readback, &locked, NULL, D3DLOCK_READONLY))) goto done;
    worst = 0;
    char detail[400] = "";
    for (int i = 0; i < 12; i++) {
        int cx = (int)((i % 4 + 0.5) * width / 4), cy = (int)((i / 4 + 0.5) * height / 3);
        int sum[3] = {0, 0, 0}, n = 0;
        for (int dy = -4; dy <= 4; dy++) {
            const uint8_t *row = (const uint8_t *)locked.pBits + (size_t)(cy + dy) * locked.Pitch;
            for (int dx = -4; dx <= 4; dx++) {
                const uint8_t *p = row + (size_t)(cx + dx) * 4;   // B G R X
                sum[0] += p[2]; sum[1] += p[1]; sum[2] += p[0]; n++;
            }
        }
        for (int c = 0; c < 3; c++) {
            int e = abs((sum[c] + n / 2) / n - kPatches[i][c]);
            if (e > worst) worst = e;
        }
        if (i < 3) {
            size_t used = strlen(detail);
            snprintf(detail + used, sizeof(detail) - used, "%s(%d,%d,%d) for (%d,%d,%d)", i ? ", " : "",
                     (sum[0] + n / 2) / n, (sum[1] + n / 2) / n, (sum[2] + n / 2) / n,
                     kPatches[i][0], kPatches[i][1], kPatches[i][2]);
        }
    }
    IDirect3DSurface9_UnlockRect(readback);
    ls_log("colour check: worst channel error %d code values%s; first patches %s", worst,
           worst > 4 ? " -- this driver is not converting as BT.709" : "", detail);

done:
    if (patches) IDirect3DSurface9_Release(patches);
    if (target) IDirect3DSurface9_Release(target);
    if (readback) IDirect3DSurface9_Release(readback);
    if (worst >= 0)
        d->colour_flags = LS_DECODER_COLOUR_CHECKED
                        | ((uint32_t)(worst > 255 ? 255 : worst) << LS_DECODER_COLOUR_ERROR_SHIFT);
}

/* Copies a software-decoded picture into an NV12 surface for the processor. */
static IDirect3DSurface9 *upload(LSDisplay *d, const AVFrame *frame) {
    UINT w = (UINT)frame->width, h = (UINT)frame->height;
    if (!d->upload || d->upload_width != w || d->upload_height != h) {
        if (d->upload) IDirect3DSurface9_Release(d->upload);
        d->upload = NULL;
        if (FAILED(IDirect3DDevice9Ex_CreateOffscreenPlainSurface(d->device, w, h, FOURCC_NV12,
                                                                  D3DPOOL_DEFAULT, &d->upload, NULL)))
            return NULL;
        d->upload_width = w;
        d->upload_height = h;
    }
    D3DLOCKED_RECT locked;
    if (FAILED(IDirect3DSurface9_LockRect(d->upload, &locked, NULL, D3DLOCK_DISCARD))) return NULL;
    uint8_t *luma = (uint8_t *)locked.pBits;
    uint8_t *chroma = luma + (size_t)locked.Pitch * h;
    for (UINT y = 0; y < h; y++)
        memcpy(luma + (size_t)y * locked.Pitch, frame->data[0] + (size_t)y * frame->linesize[0], w);
    for (UINT y = 0; y < h / 2; y++) {
        const uint8_t *u = frame->data[1] + (size_t)y * frame->linesize[1];
        const uint8_t *v = frame->data[2] + (size_t)y * frame->linesize[2];
        uint8_t *uv = chroma + (size_t)y * locked.Pitch;
        for (UINT x = 0; x < w / 2; x++) { uv[2 * x] = u[x]; uv[2 * x + 1] = v[x]; }
    }
    IDirect3DSurface9_UnlockRect(d->upload);
    return d->upload;
}

static int present(LSDisplay *d) {
    HRESULT hr = IDirect3DDevice9Ex_PresentEx(d->device, NULL, NULL, NULL, NULL, 0);
    // Occluded means another window is in front, for now; not an error.
    if (hr == D3DERR_DEVICEREMOVED || hr == D3DERR_DEVICEHUNG) {
        ls_log("the graphics device has gone (0x%08lx)", (unsigned long)hr);
        return -1;
    }
    return 0;
}

int ls_display_show_frame(LSDisplay *d, const AVFrame *frame) {
    uint64_t begin = ls_now_us();
    IDirect3DSurface9 *source;
    UINT width, height;
    D3DFORMAT format;
    if (frame->format == AV_PIX_FMT_DXVA2_VLD) {
        source = (IDirect3DSurface9 *)frame->data[3];
        D3DSURFACE_DESC desc;
        IDirect3DSurface9_GetDesc(source, &desc);
        // The decoder's surfaces are padded to whole macroblocks: 1088 lines
        // for 1080. The processor is made for the surface; only the picture
        // is drawn from it.
        width = desc.Width;
        height = desc.Height;
        format = desc.Format;
    } else if (frame->format == AV_PIX_FMT_YUV420P) {
        source = upload(d, frame);
        if (!source) return 0;
        width = d->upload_width;
        height = d->upload_height;
        format = FOURCC_NV12;
    } else {
        return 0;
    }

    if (!d->colour_checked) check_colour(d, frame->width, frame->height);
    if (ensure_processor(d, width, height, format) != 0) return 0;

    IDirect3DSurface9 *back = NULL;
    if (FAILED(IDirect3DDevice9Ex_GetBackBuffer(d->device, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back))) return 0;
    HRESULT hr = blit(d, source, frame->width, frame->height, back,
                      fit(d, frame->width, frame->height), d->width, d->height);
    IDirect3DSurface9_Release(back);
    if (FAILED(hr)) {
        static int complained;
        if (!complained++) ls_log("VideoProcessBlt failed (0x%08lx)", (unsigned long)hr);
        return 0;
    }
    int status = present(d);

    double micros = (double)(ls_now_us() - begin);
    d->render_average = d->render_average == 0 ? micros : d->render_average * 0.85 + micros * 0.15;
    d->render_us = (uint32_t)d->render_average;
    return status;
}

void ls_display_show_message(LSDisplay *d, const char *text) {
    // GDI draws into a system-memory surface, which is copied up and
    // stretched onto the back buffer: no D3DX, and no lockable back buffer.
    IDirect3DSurface9 *memory = NULL, *staging = NULL, *back = NULL;
    if (FAILED(IDirect3DDevice9Ex_CreateOffscreenPlainSurface(d->device, d->width, d->height, D3DFMT_X8R8G8B8,
                                                              D3DPOOL_SYSTEMMEM, &memory, NULL)))
        return;
    HDC dc;
    if (SUCCEEDED(IDirect3DSurface9_GetDC(memory, &dc))) {
        RECT all = {0, 0, d->width, d->height};
        HBRUSH dark = CreateSolidBrush(RGB(24, 26, 30));
        FillRect(dc, &all, dark);
        DeleteObject(dark);
        HFONT font = CreateFontA(-d->height / 40, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
                                 CLEARTYPE_QUALITY, 0, "Segoe UI");
        HGDIOBJ old = SelectObject(dc, font);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(200, 204, 210));
        RECT box = all;
        DrawTextA(dc, text, -1, &box, DT_CALCRECT | DT_CENTER | DT_WORDBREAK);
        int h = box.bottom - box.top;
        box.left = 0; box.right = d->width;
        box.top = (d->height - h) / 2; box.bottom = box.top + h;
        DrawTextA(dc, text, -1, &box, DT_CENTER | DT_WORDBREAK);
        SelectObject(dc, old);
        DeleteObject(font);
        IDirect3DSurface9_ReleaseDC(memory, dc);
    }
    if (SUCCEEDED(IDirect3DDevice9Ex_CreateOffscreenPlainSurface(d->device, d->width, d->height, D3DFMT_X8R8G8B8,
                                                                 D3DPOOL_DEFAULT, &staging, NULL))
        && SUCCEEDED(IDirect3DDevice9Ex_UpdateSurface(d->device, memory, NULL, staging, NULL))
        && SUCCEEDED(IDirect3DDevice9Ex_GetBackBuffer(d->device, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back))) {
        IDirect3DDevice9Ex_StretchRect(d->device, staging, NULL, back, NULL, D3DTEXF_NONE);
        present(d);
    }
    if (back) IDirect3DSurface9_Release(back);
    if (staging) IDirect3DSurface9_Release(staging);
    IDirect3DSurface9_Release(memory);
}

LSDisplay *ls_display_create(HWND window, int windowed, char *error, size_t error_size) {
    LSDisplay *d = (LSDisplay *)calloc(1, sizeof(*d));
    if (!d) { snprintf(error, error_size, "out of memory"); return NULL; }
    d->window = window;
    d->windowed = windowed;
    HRESULT hr = Direct3DCreate9Ex(D3D_SDK_VERSION, &d->d3d);
    if (FAILED(hr)) {
        snprintf(error, error_size, "Direct3D 9Ex is not available (0x%08lx)", (unsigned long)hr);
        goto fail;
    }

    D3DDISPLAYMODEEX mode;
    memset(&mode, 0, sizeof(mode));
    mode.Size = sizeof(mode);
    IDirect3D9Ex_GetAdapterDisplayModeEx(d->d3d, D3DADAPTER_DEFAULT, &mode, NULL);
    D3DADAPTER_IDENTIFIER9 adapter;
    if (SUCCEEDED(IDirect3D9Ex_GetAdapterIdentifier(d->d3d, D3DADAPTER_DEFAULT, 0, &adapter)))
        ls_log("graphics: %s, driver %u.%u.%u.%u; screen %ux%u at %u Hz", adapter.Description,
               HIWORD(adapter.DriverVersion.HighPart), LOWORD(adapter.DriverVersion.HighPart),
               HIWORD(adapter.DriverVersion.LowPart), LOWORD(adapter.DriverVersion.LowPart),
               mode.Width, mode.Height, mode.RefreshRate);
    d->width = (int)mode.Width;
    d->height = (int)mode.Height;

    D3DPRESENT_PARAMETERS pp;
    memset(&pp, 0, sizeof(pp));
    pp.BackBufferWidth = mode.Width;
    pp.BackBufferHeight = mode.Height;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferCount = 1;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = window;
    pp.Windowed = windowed ? TRUE : FALSE;
    pp.FullScreen_RefreshRateInHz = windowed ? 0 : mode.RefreshRate;
    // Wait for the vertical blank, as the Mac client does: no tearing.
    pp.PresentationInterval = D3DPRESENT_INTERVAL_ONE;

    // Multithreaded because the decoder uses the device from its own thread.
    DWORD flags = D3DCREATE_HARDWARE_VERTEXPROCESSING | D3DCREATE_MULTITHREADED | D3DCREATE_FPU_PRESERVE;
    hr = IDirect3D9Ex_CreateDeviceEx(d->d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, window, flags, &pp,
                                     windowed ? NULL : &mode, &d->device);
    if (FAILED(hr) && !windowed) {
        ls_log("exclusive fullscreen refused (0x%08lx); using a borderless window instead", (unsigned long)hr);
        d->windowed = 1;
        pp.Windowed = TRUE;
        pp.FullScreen_RefreshRateInHz = 0;
        hr = IDirect3D9Ex_CreateDeviceEx(d->d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, window, flags, &pp,
                                         NULL, &d->device);
    }
    if (FAILED(hr)) {
        snprintf(error, error_size, "could not create a Direct3D device (0x%08lx)", (unsigned long)hr);
        goto fail;
    }
    IDirect3DDevice9Ex_SetMaximumFrameLatency(d->device, 1);
    ls_log("presenting %s, vsync on, frame latency 1", d->windowed ? "in a window" : "exclusive fullscreen");

    hr = DXVA2CreateDirect3DDeviceManager9(&d->reset_token, &d->manager);
    if (SUCCEEDED(hr)) hr = IDirect3DDeviceManager9_ResetDevice(d->manager, (IDirect3DDevice9 *)d->device, d->reset_token);
    if (SUCCEEDED(hr)) hr = DXVA2CreateVideoService((IDirect3DDevice9 *)d->device, &IID_IDirectXVideoProcessorService,
                                                    (void **)&d->service);
    if (FAILED(hr)) {
        snprintf(error, error_size, "DXVA2 is not available on this graphics driver (0x%08lx)", (unsigned long)hr);
        goto fail;
    }

    // FFmpeg is handed our device manager rather than making its own device,
    // so its surfaces live on the device that draws them. It does not take
    // ownership: with no free function set, the manager stays ours.
    d->hw_device = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_DXVA2);
    if (d->hw_device) {
        AVDXVA2DeviceContext *hw = (AVDXVA2DeviceContext *)((AVHWDeviceContext *)d->hw_device->data)->hwctx;
        hw->devmgr = d->manager;
        if (av_hwdevice_ctx_init(d->hw_device) < 0) av_buffer_unref(&d->hw_device);
    }
    if (!d->hw_device) ls_log("FFmpeg would not take the DXVA2 device; decoding will be in software");
    return d;

fail:
    ls_display_destroy(d);
    return NULL;
}

void ls_display_destroy(LSDisplay *d) {
    if (!d) return;
    release_processor(d);
    if (d->upload) IDirect3DSurface9_Release(d->upload);
    av_buffer_unref(&d->hw_device);
    if (d->service) IDirectXVideoProcessorService_Release(d->service);
    if (d->manager) IDirect3DDeviceManager9_Release(d->manager);
    if (d->device) IDirect3DDevice9Ex_Release(d->device);
    if (d->d3d) IDirect3D9Ex_Release(d->d3d);
    free(d);
}

AVBufferRef *ls_display_hw_device(LSDisplay *d) { return d->hw_device; }
uint32_t ls_display_colour_flags(const LSDisplay *d) { return d->colour_flags; }
uint32_t ls_display_render_us(const LSDisplay *d) { return d->render_us; }
