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

#pragma once

#include <string>

#include <donut/app/DeviceManager.h>
#include <donut/core/log.h>

#include <Metal/Metal.hpp>
// #include <MetalKit/MetalKit.hpp>

#include <nvrhi/metal.h>
#include <nvrhi/validation.h>

class DeviceManager_MTL : public donut::app::DeviceManager
{
public:
    [[nodiscard]] nvrhi::IDevice* GetDevice() const override
    {
        if (m_ValidationLayer)
            return m_ValidationLayer;

        return m_NvrhiDevice;
    }

    [[nodiscard]] nvrhi::GraphicsAPI GetGraphicsAPI() const override
    {
        return nvrhi::GraphicsAPI::METAL;
    }

    bool EnumerateAdapters(std::vector<donut::app::AdapterInfo>& outAdapters) override;
    const donut::app::DeviceCreationParameters& GetDeviceParams() const { return m_DeviceParams; };

protected:
    bool CreateInstanceInternal() override;
    bool CreateDevice() override;
    bool CreateSwapChain() override;
    void DestroyDeviceAndSwapChain() override;

    void ResizeSwapChain() override
    {
        if (m_pMetalLayer)
        {
            destroySwapChain();
            createSwapChain();
        }
    }

    nvrhi::ITexture* GetCurrentBackBuffer() override
    {
        return m_SwapChainImages[m_SwapChainIndex].rhiHandle;
    }
    nvrhi::ITexture* GetBackBuffer(uint32_t index) override
    {
        if (index < m_SwapChainImages.size())
            return m_SwapChainImages[index].rhiHandle;
        return nullptr;
    }
    uint32_t GetCurrentBackBufferIndex() override
    {
        return m_SwapChainIndex;
    }
    uint32_t GetBackBufferCount() override
    {
        return uint32_t(m_SwapChainImages.size());
    }

    bool BeginFrame() override;
    bool Present() override;

    const char *GetRendererString() const override
    {
        return m_RendererString.c_str();
    }

private:
    bool createDevice();
    bool createSwapChain();
    void destroySwapChain();

    std::string m_RendererString;

    MTL::Device* m_pMTLDevice = nullptr;

    // ObjC objects held opaquely (this header is also included from pure C++ TUs):
    // m_pMetalLayer is a CAMetalLayer*, m_pCurrentDrawable is an id<CAMetalDrawable>.
    void* m_pMetalLayer = nullptr;
    void* m_pCurrentDrawable = nullptr;

    struct SwapChainImage
    {
        MTL::Texture* pTexture = nullptr;
        nvrhi::TextureHandle rhiHandle;
    };

    std::vector<SwapChainImage> m_SwapChainImages;
    // Keeps every created drawable handle alive for the lifetime of the
    // swapchain: swapchain framebuffers hold RAW texture pointers, so a
    // handle must never be released while a framebuffer references it.
    // CAMetalLayer rotates its texture pool, so more than m_BackBufferCount
    // distinct drawables can appear over time.
    std::vector<nvrhi::TextureHandle> m_AllDrawableHandles;
    uint32_t m_SwapChainIndex = 0;
    uint32_t m_NextSwapChainSlot = 0;
    uint32_t m_SwapChainWidth = 0;
    uint32_t m_SwapChainHeight = 0;

    uint32_t m_BackBufferCount = 3;

    nvrhi::metal::DeviceHandle m_NvrhiDevice;
    nvrhi::DeviceHandle m_ValidationLayer;

    std::vector<nvrhi::EventQueryHandle> m_QueryPool;
    uint32_t m_CurrentQueryIndex = 0;
};
