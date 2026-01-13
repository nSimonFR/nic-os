{
  config,
  pkgs,
  ...
}:
{
  # Star Citizen environment variable overrides for DXVK/Wine/Proton
  # These fix common freezing and presentation issues on NVIDIA with Wayland

  environment.sessionVariables = {
    # DXVK fixes for Star Citizen
    "DXVK_ASYNC" = "1";
    "DXVK_FRAME_RATE" = "0"; # Unlimited FPS
    "DXVK_HUD" = "0"; # Disable HUD (set to "fps" for debugging)
    "DXVK_LOG_LEVEL" = "none"; # Reduce logging to prevent launcher issues

    # Fix DXVK swapchain presentation issues (critical for your freezing issue)
    "DXVK_PRESENT_MODE" = "fifo"; # Force FIFO present mode
    "DXVK_STATE_CACHE_PATH" = "/tmp/dxvk-cache"; # Better cache location

    # NVIDIA-specific DXVK optimizations
    "DXVK_NVAPI_ALLOW_OTHER_DRIVERS" = "0";
    "DXVK_NVAPI_DRIVER_VERSION" = "55610"; # Latest NVIDIA driver version
    "DXVK_NVAPIHACK" = "0";

    # VKD3D (DirectX 12) fixes for Star Citizen
    "VKD3D_CONFIG" = "dxr11,dxr";
    "VKD3D_FEATURE_LEVEL" = "12_0";
    "VKD3D_SHADER_DEBUG" = "none";

    # Wine/Proton optimizations for Star Citizen
    "WINE_CPU_TOPOLOGY" = "8:2"; # 8 cores, 2 threads per core (16 total threads)
    "WINE_LARGE_ADDRESS_AWARE" = "1";

    # Proton-specific (if using Proton)
    "PROTON_ENABLE_NVAPI" = "1";
    "PROTON_HIDE_NVIDIA_GPU" = "0";
    "PROTON_FORCE_LARGE_ADDRESS_AWARE" = "1";

    # Mesa/Vulkan tweaks
    "MESA_LOADER_DRIVER_OVERRIDE" = "nvidia";
    "VK_DRIVER_FILES" = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json";

    # Vulkan shader cache size (increase from default ~1GB to 10GB)
    "MESA_SHADER_CACHE_MAX_SIZE" = "10G";
    "MESA_DISK_CACHE_MAX_SIZE" = "10G";

    # NVIDIA shader cache size (10GB = 10737418240 bytes)
    "__GL_SHADER_DISK_CACHE_SIZE" = "10737418240";
    "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP" = "1";

    # Fix multi-monitor DPI issues that can cause swapchain problems
    "WINE_VK_FILTER_DUPLICATE_MODES" = "1";
    "WINE_VK_STRICT_DRAW_ORDERING" = "1";

    # Star Citizen specific
    # Prevents the launcher from hijacking focus and causing presentation issues
    "SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS" = "0";
  };

  # Create DXVK cache directory
  systemd.tmpfiles.rules = [
    "d /tmp/dxvk-cache 0755 ${config.users.users.nsimon.name} users -"
  ];
}
