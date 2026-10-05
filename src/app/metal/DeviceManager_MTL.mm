/*
 * Copyright (c) 2014-2021, NVIDIA CORPORATION. All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#include <donut/app/DeviceManager.h>
#include <donut/app/DeviceManager_MTL.h>

#include <nvrhi/metal.h>
#include <nvrhi/validation.h>

#import <Metal/Metal.hpp>
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

// glfw3.h is already included via DeviceManager.h; expose the Cocoa native accessors
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>

using namespace donut;
using namespace donut::app;

bool DeviceManager_MTL::createDevice()
{
    nvrhi::metal::DeviceDesc deviceDesc;
    deviceDesc.errorCB = &DefaultMessageCallback::GetInstance();
    deviceDesc.aftermathEnabled = false;

    m_NvrhiDevice = nvrhi::metal::createDevice(deviceDesc);
    if (!m_NvrhiDevice)
    {
        log::error("Metal: failed to create nvrhi device");
        return false;
    }

    // The nvrhi device owns the MTL::Device; share it with the swapchain layer.
    m_pMTLDevice = m_NvrhiDevice->getNativeDevice();
    m_pMTLDevice->retain();

    m_RendererString = "Metal (" + std::string(m_pMTLDevice->name()->utf8String()) + ")";
    log::message(m_DeviceParams.infoLogSeverity, "Metal device: %s", m_RendererString.c_str());

    if (m_DeviceParams.enableNvrhiValidationLayer)
    {
        m_ValidationLayer = nvrhi::validation::createValidationLayer(m_NvrhiDevice);
    }

    return true;
}

bool DeviceManager_MTL::createSwapChain()
{
    m_SwapChainImages.clear();

    if (!m_Window || !m_pMTLDevice)
        return false;

    int fbWidth = 0, fbHeight = 0;
    glfwGetFramebufferSize(m_Window, &fbWidth, &fbHeight);
    if (fbWidth == 0 || fbHeight == 0)
    {
        log::warning("Metal: Swapchain size is zero");
        return true;
    }

    MTLPixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm;
    nvrhi::Format format = nvrhi::Format::BGRA8_UNORM;
    switch (m_DeviceParams.swapChainFormat)
    {
    case nvrhi::Format::SRGBA8_UNORM:
        pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
        format = nvrhi::Format::SRGBA8_UNORM;
        break;
    case nvrhi::Format::SBGRA8_UNORM:
        pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        format = nvrhi::Format::SBGRA8_UNORM;
        break;
    case nvrhi::Format::RGBA8_UNORM:
        pixelFormat = MTLPixelFormatRGBA8Unorm;
        format = nvrhi::Format::RGBA8_UNORM;
        break;
    default:
        break;
    }

    @autoreleasepool
    {
        NSWindow* pNSWindow = glfwGetCocoaWindow(m_Window);
        NSView* pView = [pNSWindow contentView];

        // Adding the layer as a SUB-LAYER (rather than replacing the view's
        // layer) keeps AppKit's layout of the view intact. Replacing the
        // layer of GLFW's content view breaks its geometry management and
        // produces degenerate drawables (4x4 / 1x1) and negative-height
        // layout warnings.
        CAMetalLayer* pLayer = [CAMetalLayer layer];
        pLayer.device = (__bridge id<MTLDevice>)m_pMTLDevice;
        pLayer.pixelFormat = pixelFormat;
        // The DUMP_PREFIX frame dump (see Present) blits from the drawable.
        pLayer.framebufferOnly = getenv("DUMP_PREFIX") == nullptr;
        pLayer.frame = pView.bounds;
        pLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        // Render at 1x: the framework sizes window-management structures
        // (depth buffer, viewport state) from glfwGetWindowSize, which is in
        // points. A retina-scale drawable (bounds * backingScaleFactor) would
        // disagree with those sizes and render into a sub-rectangle.
        pLayer.contentsScale = 1.0;
        pLayer.maximumDrawableCount = m_BackBufferCount;
        pLayer.displaySyncEnabled = m_DeviceParams.vsyncEnabled;

        [pView setWantsLayer:YES];
        [pView.layer addSublayer:pLayer];

        m_pMetalLayer = (void*)CFBridgingRetain(pLayer);
    }

    // Drawable textures are acquired per frame from the layer; the nvrhi
    // handles are created lazily in BeginFrame, keyed by the texture pointer.
    m_SwapChainImages.resize(m_BackBufferCount);
    m_SwapChainIndex = 0;

    (void)format;

    return true;
}

void DeviceManager_MTL::destroySwapChain()
{
    for (auto& img : m_SwapChainImages)
    {
        img.rhiHandle = nullptr;
        img.pTexture = nullptr;
    }
    m_SwapChainImages.clear();
    m_AllDrawableHandles.clear();
    m_SwapChainIndex = 0;
    m_NextSwapChainSlot = 0;
    m_SwapChainWidth = 0;
    m_SwapChainHeight = 0;

    if (m_pCurrentDrawable)
    {
        CFRelease(m_pCurrentDrawable);
        m_pCurrentDrawable = nullptr;
    }

    if (m_pMetalLayer)
    {
        CAMetalLayer* pLayer = (CAMetalLayer*)CFBridgingRelease(m_pMetalLayer);
        m_pMetalLayer = nullptr;
        @autoreleasepool
        {
            [pLayer removeFromSuperlayer];
            pLayer = nil;
        }
    }
}

bool DeviceManager_MTL::CreateInstanceInternal()
{
    return true;
}

bool DeviceManager_MTL::EnumerateAdapters(std::vector<AdapterInfo>& outAdapters)
{
    outAdapters.clear();

    MTL::Device* pDevice = MTL::CreateSystemDefaultDevice();
    if (!pDevice)
        return false;

    AdapterInfo adapterInfo;
    adapterInfo.name = pDevice->name()->utf8String();
    adapterInfo.vendorID = 0;
    adapterInfo.deviceID = 0;
    adapterInfo.dedicatedVideoMemory = 0;

    outAdapters.push_back(std::move(adapterInfo));
    pDevice->release();
    return true;
}

bool DeviceManager_MTL::CreateDevice()
{
    return createDevice();
}

bool DeviceManager_MTL::CreateSwapChain()
{
    return createSwapChain();
}

void DeviceManager_MTL::DestroyDeviceAndSwapChain()
{
    destroySwapChain();

    m_NvrhiDevice = nullptr;
    m_ValidationLayer = nullptr;
    m_RendererString.clear();

    if (m_pMTLDevice)
    {
        m_pMTLDevice->release();
        m_pMTLDevice = nullptr;
    }
}

bool DeviceManager_MTL::BeginFrame()
{
    if (!m_pMetalLayer)
        return true;

    @autoreleasepool
    {
        CAMetalLayer* pLayer = (__bridge CAMetalLayer*)m_pMetalLayer;

        // nextDrawable blocks until one is available (frame pacing)
        id<CAMetalDrawable> drawable = [pLayer nextDrawable];
        if (!drawable)
            return false;

        if (m_pCurrentDrawable)
            CFRelease(m_pCurrentDrawable);
        m_pCurrentDrawable = (void*)CFBridgingRetain(drawable);

        MTL::Texture* pTex = (MTL::Texture*)[drawable texture];

        // The drawable texture's dimensions are authoritative - the layer can
        // resize its drawables at any time (window resize, display change,
        // AppKit layout). A zero/tiny drawable (window not laid out yet,
        // occluded, or minimized) must not reach nvrhi: the swapchain texture
        // desc and any dependent render targets would be created with zero
        // extents, which Metal rejects.
        uint32_t texWidth = uint32_t(pTex->width());
        uint32_t texHeight = uint32_t(pTex->height());
        if (texWidth < 1 || texHeight < 1)
            return false;

        // On any size change, detach the cached handles from the slots (they
        // stay alive in m_AllDrawableHandles). Framebuffers are rebuilt
        // below / per-slot when the new-size handles appear.
        if (texWidth != m_SwapChainWidth || texHeight != m_SwapChainHeight)
        {
            for (auto& img : m_SwapChainImages)
            {
                img.rhiHandle = nullptr;
                img.pTexture = nullptr;
            }
            m_SwapChainWidth = texWidth;
            m_SwapChainHeight = texHeight;
        }

        // Find or create the nvrhi handle for this drawable texture. Matching
        // by pointer alone is unsafe: MTLTexture allocations are freed and
        // reused as the layer resizes its drawable pool (window resize,
        // display change), so a stale handle could wrap a DIFFERENT-sized
        // texture that happens to live at the same address. Verify the
        // wrapped desc dimensions as well.
        uint32_t slot = UINT32_MAX;
        for (uint32_t i = 0; i < m_SwapChainImages.size(); i++)
        {
            if (m_SwapChainImages[i].pTexture == pTex && m_SwapChainImages[i].rhiHandle)
            {
                const nvrhi::TextureDesc& handleDesc = m_SwapChainImages[i].rhiHandle->getDesc();
                if (handleDesc.width == texWidth && handleDesc.height == texHeight)
                {
                    slot = i;
                    break;
                }
            }
        }
        if (slot == UINT32_MAX)
        {
            // Round-robin replacement
            slot = m_NextSwapChainSlot;
            m_NextSwapChainSlot = (m_NextSwapChainSlot + 1) % uint32_t(m_SwapChainImages.size());
            m_SwapChainImages[slot].pTexture = pTex;

            nvrhi::TextureDesc texDesc;
            texDesc.width = texWidth;
            texDesc.height = texHeight;
            texDesc.format = m_DeviceParams.swapChainFormat;
            if (texDesc.format != nvrhi::Format::SRGBA8_UNORM &&
                texDesc.format != nvrhi::Format::SBGRA8_UNORM &&
                texDesc.format != nvrhi::Format::RGBA8_UNORM)
                texDesc.format = nvrhi::Format::BGRA8_UNORM;
            texDesc.debugName = "Swap chain image";
            texDesc.initialState = nvrhi::ResourceStates::Present;
            texDesc.keepInitialState = true;
            texDesc.isRenderTarget = true;

            m_SwapChainImages[slot].rhiHandle = m_NvrhiDevice->createHandleForNativeTexture(
                nvrhi::ObjectTypes::Nvrhi_MTL_Texture,
                nvrhi::Object(pTex),
                texDesc
            );
            m_AllDrawableHandles.push_back(m_SwapChainImages[slot].rhiHandle);
        }

        m_SwapChainIndex = slot;

        // The base class builds swapchain framebuffers in BackBufferResized()
        // while the backbuffer handles are still null (they only exist after
        // drawable acquisition, i.e. now). Rebuild unless the slot's
        // framebuffer already targets this drawable's texture. Check the
        // colour-only framebuffer: the with-depth one reports the depth
        // buffer's size even when its colour attachment is null or stale.
        // A resize gives the slot a new texture, so this also covers resizes.
        nvrhi::IFramebuffer* pCurrentFB = GetFramebuffer(slot, false);
        const bool fbMatchesDrawable = pCurrentFB
            && !pCurrentFB->getDesc().colorAttachments.empty()
            && pCurrentFB->getDesc().colorAttachments[0].texture == m_SwapChainImages[slot].rhiHandle;
        if (!fbMatchesDrawable)
        {
            BackBufferResized();
        }

        return true;
    }
}

bool DeviceManager_MTL::Present()
{
    if (!m_pCurrentDrawable)
        return true;

    @autoreleasepool
    {
        // Present on the nvrhi graphics queue so presentation is ordered after
        // all rendering command buffers submitted through nvrhi.
        MTL::CommandQueue* pQueue = (MTL::CommandQueue*)m_NvrhiDevice->getNativeQueue(
            nvrhi::ObjectTypes::Nvrhi_MTL_CommandQueue, nvrhi::CommandQueue::Graphics);

        if (pQueue)
        {
            MTL::CommandBuffer* pCommandBuffer = pQueue->commandBuffer();
            id<CAMetalDrawable> drawable = (id<CAMetalDrawable>)CFBridgingRelease(m_pCurrentDrawable);
            m_pCurrentDrawable = nullptr;

            // Keep the present ordered after all rendering submitted so far
            // (Metal does not order command buffers on a queue by itself).
            m_NvrhiDevice->attachSubmitOrdering(pCommandBuffer);

            // Smoke-test support: DUMP_PREFIX=/tmp/x [DUMP_FRAME=5] captures the
            // frame's drawable into <prefix>_frame<N>.ppm and exits. Lets CI /
            // scripts verify that samples actually render (not just run).
            static const char* s_dumpPrefix = getenv("DUMP_PREFIX");
            static int s_dumpFrameTarget = -1;
            static int s_presentedFrames = 0;
            const int presentFrame = s_presentedFrames++;
            if (s_dumpPrefix && s_dumpFrameTarget < 0)
            {
                const char* f = getenv("DUMP_FRAME");
                s_dumpFrameTarget = f ? atoi(f) : 5;
            }

            MTL::Buffer* pDumpBuffer = nullptr;
            uint32_t dumpW = 0, dumpH = 0;
            if (s_dumpPrefix && presentFrame == s_dumpFrameTarget)
            {
                MTL::Texture* pTex = (MTL::Texture*)[drawable texture];
                dumpW = uint32_t(pTex->width());
                dumpH = uint32_t(pTex->height());
                pDumpBuffer = m_pMTLDevice->newBuffer(uint64_t(dumpW) * dumpH * 4, MTL::ResourceStorageModeShared);
            }

            if (pDumpBuffer)
            {
                MTL::BlitCommandEncoder* pBlit = pCommandBuffer->blitCommandEncoder();
                MTL::Texture* pTex = (MTL::Texture*)[drawable texture];
                pBlit->copyFromTexture(pTex, 0, 0,
                    MTL::Origin(0, 0, 0), MTL::Size(dumpW, dumpH, 1),
                    pDumpBuffer, 0, dumpW * 4, dumpW * 4 * dumpH);
                pBlit->endEncoding();

                pCommandBuffer->presentDrawable((MTL::Drawable*)drawable);
                pCommandBuffer->commit();
                pCommandBuffer->waitUntilCompleted();

                const uint8_t* src = static_cast<const uint8_t*>(pDumpBuffer->contents());
                FILE* f2 = fopen((std::string(s_dumpPrefix) + "_frame" + std::to_string(presentFrame) + ".ppm").c_str(), "wb");
                if (f2)
                {
                    // drawable is BGRA8 sRGB - write RGB
                    fprintf(f2, "P6\n%u %u\n255\n", dumpW, dumpH);
                    std::vector<uint8_t> rowbuf(size_t(dumpW) * 3);
                    for (uint32_t y = 0; y < dumpH; y++)
                    {
                        const uint8_t* row = src + uint64_t(y) * dumpW * 4;
                        for (uint32_t x = 0; x < dumpW; x++)
                        {
                            rowbuf[x * 3 + 0] = row[x * 4 + 2];
                            rowbuf[x * 3 + 1] = row[x * 4 + 1];
                            rowbuf[x * 3 + 2] = row[x * 4 + 0];
                        }
                        fwrite(rowbuf.data(), 1, rowbuf.size(), f2);
                    }
                    fclose(f2);
                    printf("DUMP: wrote %s_frame%d.ppm (%ux%u)\n", s_dumpPrefix, presentFrame, dumpW, dumpH);
                }
                exit(0);
            }

            pCommandBuffer->presentDrawable((MTL::Drawable*)drawable);
            pCommandBuffer->commit();
        }
    }

    return true;
}

donut::app::DeviceManager* donut::app::DeviceManager::CreateMTL()
{
    return new DeviceManager_MTL();
}
