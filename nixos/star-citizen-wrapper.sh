#!/usr/bin/env bash
# Star Citizen Launcher Wrapper
# Fixes DXVK presentation issues and freezing on NVIDIA + Wayland

# DXVK Configuration
export DXVK_ASYNC=1
export DXVK_FRAME_RATE=0
export DXVK_HUD=0 # Change to "fps" for debugging

# Critical fix for your swapchain/presentation freezing issue
export DXVK_PRESENT_MODE=fifo
export DXVK_STATE_CACHE_PATH="${XDG_CACHE_HOME:-$HOME/.cache}/dxvk-cache"

# NVIDIA-specific DXVK settings
export DXVK_NVAPI_ALLOW_OTHER_DRIVERS=0
export DXVK_FILTER_DEVICE_NAME=""

# VKD3D (DirectX 12) Configuration
export VKD3D_CONFIG=dxr11,dxr
export VKD3D_FEATURE_LEVEL=12_0
export VKD3D_SHADER_DEBUG=none

# Wine optimizations
export WINE_CPU_TOPOLOGY="8:2" # 8 cores, 2 threads per core (16 total)
export WINE_LARGE_ADDRESS_AWARE=1
export WINE_VK_FILTER_DUPLICATE_MODES=1
export WINE_VK_STRICT_DRAW_ORDERING=1

# Proton/Wine NVAPI
export PROTON_ENABLE_NVAPI=1
export PROTON_HIDE_NVIDIA_GPU=0
export PROTON_FORCE_LARGE_ADDRESS_AWARE=1

# Vulkan
export VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json

# Multi-monitor fixes
export SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0

# Fix for window association warnings (your specific error)
export WINEDLLOVERRIDES="dxgi=n,b"

# Enable logging for debugging (comment out after issue is fixed)
# export DXVK_LOG_LEVEL=info
# export PROTON_LOG=1
# export WINEDEBUG=+timestamp,+tid,+seh,+pid

# Create cache directory
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/dxvk-cache"

echo "Starting Star Citizen with optimized settings..."
echo "DXVK_PRESENT_MODE: $DXVK_PRESENT_MODE"
echo "VK_DRIVER_FILES: $VK_DRIVER_FILES"

# Launch Star Citizen (adjust path if needed)
exec star-citizen "$@"

