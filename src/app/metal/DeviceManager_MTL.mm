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

        CAMetalLayer* pLayer = [CAMetalLayer layer];
        pLayer.device = (__bridge id<MTLDevice>)m_pMTLDevice;
        pLayer.pixelFormat = pixelFormat;
        pLayer.framebufferOnly = YES;
        pLayer.drawableSize = CGSizeMake(fbWidth, fbHeight);
        pLayer.maximumDrawableCount = m_BackBufferCount;
        pLayer.displaySyncEnabled = m_DeviceParams.vsyncEnabled;

        [pView setLayer:pLayer];
        [pView setWantsLayer:YES];

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

        // A zero-sized drawable (window not laid out yet, occluded, or minimized)
        // must not reach nvrhi: the swapchain texture desc and any dependent
        // render targets would be created with zero extents, which Metal rejects.
        CGSize drawableSize = [pLayer drawableSize];
        if (drawableSize.width < 1.0 || drawableSize.height < 1.0)
            return false;

        // On resize (or contentsScale change), invalidate the cached nvrhi
        // handles so they are recreated with the current drawable size.
        if (uint32_t(drawableSize.width) != m_SwapChainWidth ||
            uint32_t(drawableSize.height) != m_SwapChainHeight)
        {
            // Keep the handles alive in m_AllDrawableHandles; just detach them
            // from the slots. Framebuffers get rebuilt below / per-slot.
            for (auto& img : m_SwapChainImages)
            {
                img.rhiHandle = nullptr;
                img.pTexture = nullptr;
            }
            m_SwapChainWidth = uint32_t(drawableSize.width);
            m_SwapChainHeight = uint32_t(drawableSize.height);
        }

        // nextDrawable blocks until one is available (frame pacing)
        id<CAMetalDrawable> drawable = [pLayer nextDrawable];
        if (!drawable)
            return false;

        if (m_pCurrentDrawable)
            CFRelease(m_pCurrentDrawable);
        m_pCurrentDrawable = (void*)CFBridgingRetain(drawable);

        MTL::Texture* pTex = (MTL::Texture*)[drawable texture];

        // Find or create the nvrhi handle for this drawable texture
        uint32_t slot = UINT32_MAX;
        for (uint32_t i = 0; i < m_SwapChainImages.size(); i++)
        {
            if (m_SwapChainImages[i].pTexture == pTex && m_SwapChainImages[i].rhiHandle)
            {
                slot = i;
                break;
            }
        }
        if (slot == UINT32_MAX)
        {
            // Round-robin replacement
            slot = m_NextSwapChainSlot;
            m_NextSwapChainSlot = (m_NextSwapChainSlot + 1) % uint32_t(m_SwapChainImages.size());
            m_SwapChainImages[slot].pTexture = pTex;

            nvrhi::TextureDesc texDesc;
            texDesc.width = m_SwapChainWidth;
            texDesc.height = m_SwapChainHeight;
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
