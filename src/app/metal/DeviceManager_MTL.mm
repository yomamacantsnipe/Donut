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
#import <MetalKit/MetalKit.hpp>

using namespace donut;
using namespace donut::app;

static constexpr uint32_t kGraphicsQueueIndex = 0;

#define CHECK(a) if (!(a)) { return false; }

// Helper to convert NSString to std::string
static std::string nsStringToString(NSString* str)
{
    if (!str) return "";
    const char* cStr = [str UTF8String];
    return std::string(cStr ? cStr : "");
}

bool DeviceManager_MTL::createDevice()
{
    MTL::Device* pDevice = MTL::CreateSystemDefaultDevice();
    if (!pDevice)
    {
        log::error("Metal: No system device available");
        return false;
    }

    pDevice->retain();
    m_pMTLDevice = pDevice;

    m_RendererString = "Metal (" + nsStringToString(pDevice->name()) + ")";
    log::message(m_DeviceParams.infoLogSeverity, "Metal device: %s", m_RendererString.c_str());

    m_pMTLCommandQueue = pDevice->newCommandQueue();
    m_pMTLCommandQueue->retain();

    nvrhi::metal::DeviceDesc deviceDesc;
    deviceDesc.errorCB = &DefaultMessageCallback::GetInstance();
    deviceDesc.aftermathEnabled = false;

    m_NvrhiDevice = nvrhi::metal::createDevice(deviceDesc);

    if (m_DeviceParams.enableNvrhiValidationLayer)
    {
        m_ValidationLayer = nvrhi::validation::createValidationLayer(m_NvrhiDevice);
    }

    return true;
}

bool DeviceManager_MTL::createSwapChain()
{
    m_SwapChainImages.clear();
    m_CommittedCommandBuffers.clear();

    uint32_t width = 0, height = 0;

    if (m_pMTKView)
    {
        width = uint32_t(m_pMTKView->pixelSize().width);
        height = uint32_t(m_pMTKView->pixelSize().height);
    }
    else if (m_Window)
    {
        int w, h;
        glfwGetFramebufferSize(m_Window, &w, &h);
        width = static_cast<uint32_t>(w);
        height = static_cast<uint32_t>(h);
    }

    if (width == 0 || height == 0)
    {
        log::warning("Metal: Swapchain size is zero");
        return true;
    }

    size_t numImages = 3;
    if (m_pMTKView)
    {
        numImages = m_pMTKView->maximumDrawableCount();
        if (numImages < 2) numImages = 2;
        if (numImages > 4) numImages = 4;
    }

    MTL::PixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm;

    nvrhi::Format format = m_DeviceParams.swapChainFormat;
    if (format == nvrhi::Format::SRGBA8_UNORM)
    {
        pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
        format = nvrhi::Format::SRGBA8_UNORM;
    }
    else if (format == nvrhi::Format::BGRA8_UNORM)
    {
        pixelFormat = MTLPixelFormatBGRA8Unorm;
    }
    else if (format == nvrhi::Format::RGBA8_UNORM)
    {
        pixelFormat = MTLPixelFormatRGBA8Unorm;
    }
    else
    {
        format = nvrhi::Format::RGBA8_UNORM;
    }

    for (size_t i = 0; i < numImages; i++)
    {
        SwapChainImage sci;

        if (m_pMTKView)
        {
            // MetalKit manages drawables, we'll get the texture from the drawable at runtime
            sci.pTexture = nullptr; // Will be set from drawable in BeginFrame
        }
        else
        {
            // For non-MetalKit case (headless), create our own textures
            auto textureDesc = MTL::TextureDescriptor::alloc()->init();
            textureDesc->setTextureType(MTL::TextureType2D);
            textureDesc->setWidth(width);
            textureDesc->setHeight(height);
            textureDesc->setPixelFormat(pixelFormat);
            textureDesc->setSampleCount(m_DeviceParams.swapChainSampleCount);
            textureDesc->setUsage(MTL::TextureUsageRenderTarget);
            textureDesc->setStorageMode(MTL::StorageModePrivate);
            textureDesc->allocStorage();

            sci.pTexture = m_pMTLDevice->newTexture(textureDesc);
            textureDesc->release();
        }

        if (sci.pTexture)
        {
            nvrhi::TextureDesc texDesc;
            texDesc.width = width;
            texDesc.height = height;
            texDesc.format = format;
            texDesc.debugName = "Swap chain image";
            texDesc.initialState = nvrhi::ResourceStates::Present;
            texDesc.keepInitialState = true;
            texDesc.isRenderTarget = true;

            sci.rhiHandle = m_NvrhiDevice->createHandleForNativeTexture(
                nvrhi::ObjectTypes::Nvrhi_MTL_Texture,
                nvrhi::Object(sci.pTexture),
                texDesc
            );
        }

        m_SwapChainImages.push_back(sci);
    }

    m_SwapChainIndex = 0;

    return true;
}

void DeviceManager_MTL::destroySwapChain()
{
    for (auto& img : m_SwapChainImages)
    {
        if (img.rhiHandle)
        {
            img.rhiHandle->getNativeObject(nvrhi::ObjectTypes::Nvrhi_MTL_Texture);
            img.rhiHandle = nullptr;
        }
        if (img.pTexture)
        {
            img.pTexture->release();
            img.pTexture = nullptr;
        }
    }
    m_SwapChainImages.clear();

    for (auto* pCB : m_CommittedCommandBuffers)
    {
        pCB->release();
    }
    m_CommittedCommandBuffers.clear();
}

bool DeviceManager_MTL::CreateInstanceInternal()
{
    if (m_DeviceParams.enableDebugRuntime)
    {
        // Metal validation is typically enabled via environment variable on macOS
    }

    return true;
}

bool DeviceManager_MTL::EnumerateAdapters(std::vector<AdapterInfo>& outAdapters)
{
    outAdapters.clear();

    MTL::Device* pDevice = MTL::CreateSystemDefaultDevice();
    if (!pDevice)
        return false;

    AdapterInfo adapterInfo;
    adapterInfo.name = nsStringToString(pDevice->name());
    adapterInfo.vendorID = 0;
    adapterInfo.deviceID = 0;
    adapterInfo.dedicatedVideoMemory = 0;

    outAdapters.push_back(std::move(adapterInfo));
    pDevice->release();
    return true;
}

bool DeviceManager_MTL::CreateDevice()
{
    m_pMTLDevice = MTL::CreateSystemDefaultDevice();
    if (!m_pMTLDevice)
    {
        log::error("Metal: No system device available");
        return false;
    }
    m_pMTLDevice->retain();

    m_pMTLCommandQueue = m_pMTLDevice->newCommandQueue();
    m_pMTLCommandQueue->retain();

    m_RendererString = "Metal (" + nsStringToString(m_pMTLDevice->name()) + ")";
    log::message(m_DeviceParams.infoLogSeverity, "Metal device: %s", m_RendererString.c_str());

    nvrhi::metal::DeviceDesc deviceDesc;
    deviceDesc.errorCB = &DefaultMessageCallback::GetInstance();
    deviceDesc.aftermathEnabled = false;

    m_NvrhiDevice = nvrhi::metal::createDevice(deviceDesc);

    if (m_DeviceParams.enableNvrhiValidationLayer)
    {
        m_ValidationLayer = nvrhi::validation::createValidationLayer(m_NvrhiDevice);
    }

    return true;
}

bool DeviceManager_MTL::CreateSwapChain()
{
    // Create MTKView for the window on macOS
    #if defined(__APPLE__)
    if (m_Window)
    {
        id pNSView = glfwGetCocoaView(m_Window);
        if ([pNSView isKindOfClass:[NSView class]])
        {
            NSView* pView = static_cast<NSView*>(pNSView);

            @autoreleasepool
            {
                m_pMTKView = [[MTKView alloc] initWithFrame:[pView frame] pixelFormat:MTLPixelFormatBGRA8Unorm];
                m_pMTKView->device = m_pMTLDevice;
                m_pMTKView->colorPixelFormat = MTLPixelFormatBGRA8Unorm;
                m_pMTKView->depthPixelFormat = MTLPixelFormatDepth32Float;
                m_pMTKView->sampleCount = m_DeviceParams.swapChainSampleCount;
                m_pMTKView->enableSetNeedsDisplay = true;
                m_pMTKView->layoutMode = MTKViewLayoutModeAutomaticallyResized;

                [pView addSubview:m_pMTKView];
            }
        }
    }
    #endif

    return createSwapChain();
}

void DeviceManager_MTL::DestroyDeviceAndSwapChain()
{
    destroySwapChain();

    m_NvrhiDevice = nullptr;
    m_ValidationLayer = nullptr;
    m_RendererString.clear();

    if (m_pMTLCommandQueue)
    {
        m_pMTLCommandQueue->release();
        m_pMTLCommandQueue = nullptr;
    }

    if (m_pMTLDevice)
    {
        m_pMTLDevice->release();
        m_pMTLDevice = nullptr;
    }
}

bool DeviceManager_MTL::BeginFrame()
{
    if (!m_pMTKView)
        return true;

    @autoreleasepool
    {
        m_pCurrentDrawable = [m_pMTKView nextDrawable];
        if (m_pCurrentDrawable)
        {
            id drawable = [m_pCurrentDrawable retain];
            MTL::Texture* pTex = [drawable drawableTexture];

            if (pTex)
            {
                pTex->retain();
                m_SwapChainImages[0].pTexture = pTex;
                m_SwapChainIndex = 0;
                [drawable release];
                return true;
            }
            [drawable release];
        }
    }

    return false;
}

bool DeviceManager_MTL::Present()
{
    if (!m_pCurrentDrawable || !m_pMTKView)
        return true;

    MTL::CommandBuffer* pCommandBuffer = m_pMTLCommandQueue->commandBuffer();
    if (!pCommandBuffer)
        return false;

    // Wait for previous frame to complete
    while (m_CommittedCommandBuffers.size() >= m_DeviceParams.maxFramesInFlight)
    {
        MTL::CommandBuffer* pOldCB = m_CommittedCommandBuffers.front();
        m_CommittedCommandBuffers.erase(m_CommittedCommandBuffers.begin());

        pOldCB->waitUntilCompleted();
        pOldCB->release();
    }

    pCommandBuffer->presentDrawable(m_pCurrentDrawable);

    pCommandBuffer->addCompletedHandler([](MTL::CommandBuffer* pCB) {
        pCB->release();
    });

    pCommandBuffer->retain();
    m_CommittedCommandBuffers.push_back(pCommandBuffer);

    pCommandBuffer->commit();

    // Update frame index for next frame
    m_SwapChainIndex = (m_SwapChainIndex + 1) % m_SwapChainImages.size();

    return true;
}

DeviceManager *DeviceManager::CreateMTL()
{
    return new DeviceManager_MTL();
}
