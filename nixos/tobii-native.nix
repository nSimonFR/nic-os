# Tobii Eye Tracker 5 — Native Linux support
# Experimental: head pose (pitch/yaw) doesn't work yet, only gaze position.
# Repackaged from Arch packages at https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer
# VM passthrough config is kept alongside in configuration.nix.
{ pkgs, lib, ... }:

let
  # ── tobii-stream-engine ──────────────────────────────────────────────
  # Shared library + headers for the Tobii Stream Engine API
  tobii-stream-engine = pkgs.stdenv.mkDerivation {
    pname = "tobii-stream-engine";
    version = "4.24.0";

    src = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/megagtrwrath/tobii_eye_tracker_linux_installer/master/tobii-stream-engine-4.24.0-linux-x86_64.tar.gz";
      hash = "sha256-dItQCNLAkau14zL/dvpifynWrNc8HIVRM0O4+oFY6zA=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.avahi # libavahi-client, libavahi-common
    ];

    sourceRoot = "tobii-stream-engine-4.24.0";

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/include/tobii
      cp lib/libtobii_stream_engine.so $out/lib/
      # The .so has SONAME=libtobii_research.so; create the alias so the
      # dynamic linker and autoPatchelfHook can find it by its SONAME.
      ln -s $out/lib/libtobii_stream_engine.so $out/lib/libtobii_research.so
      cp include/tobii/*.h $out/include/tobii/
      runHook postInstall
    '';
  };

  # ── tobii-engine ─────────────────────────────────────────────────────
  # Main Tobii Engine daemon (face tracking, calibration, firmware)
  tobii-engine = pkgs.stdenv.mkDerivation {
    pname = "tobii-engine";
    version = "0.1.6.193rc";

    src = pkgs.fetchurl {
      url = "https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer/releases/download/v1/tobii_engine_linux-0.1.6.193rc-1-x86_64.pkg.tar.zst";
      hash = "sha256-duCqFXZk7grNIsRK/4vu4EAkCZAmkYtcUrk8pKh9QcE=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.zstd ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib # libstdc++
      pkgs.zlib             # libz
      pkgs.sqlcipher        # libsqlcipher
      pkgs.libgcc           # libgomp (via libseeta)
    ];

    unpackPhase = ''
      tar xf $src
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share
      cp -r usr/share/tobii_engine $out/share/tobii_engine

      # Add bundled libs to rpath so self-referential deps resolve
      addAutoPatchelfSearchPath $out/share/tobii_engine/lib
      addAutoPatchelfSearchPath $out/share/tobii_engine/platform_modules
      runHook postInstall
    '';
  };

  # ── tobii-usb-service ────────────────────────────────────────────────
  # USB communication daemon for Tobii hardware
  tobii-usb-service = pkgs.stdenv.mkDerivation {
    pname = "tobii-usb-service";
    version = "2.1.5";

    src = pkgs.fetchurl {
      url = "https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer/releases/download/v1/tobiiusbservice-2.1.5-1-x86_64.pkg.tar.zst";
      hash = "sha256-+QLdjfJ7oLCAU66R49KHHU/drhXRUlBYRmjLpCYlmnk=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.zstd ];
    buildInputs = [
      pkgs.systemd # libudev
    ];

    unpackPhase = ''
      tar xf $src
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/lib
      cp usr/bin/tobiiusbserviced $out/bin/
      cp usr/local/lib/tobiiusb/*.so $out/lib/

      # Bundled libs reference each other
      addAutoPatchelfSearchPath $out/lib
      runHook postInstall
    '';
  };

  # ── tobii-pro-eye-tracker-manager ────────────────────────────────────
  # Electron calibration/configuration app
  tobii-pro-eye-tracker-manager = pkgs.stdenv.mkDerivation {
    pname = "tobii-pro-eye-tracker-manager";
    version = "2.6.1";

    src = pkgs.fetchurl {
      url = "https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer/releases/download/v1/tobiiproeyetrackermanager-2.6.1-1-x86_64.pkg.tar.zst";
      hash = "sha256-IiDsq1GFKEQQCmwev9I0sJgRvqgJm5M1oNvG1dIU7ys=";
    };

    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      pkgs.makeWrapper
      pkgs.zstd
    ];

    buildInputs = with pkgs; [
      alsa-lib
      at-spi2-atk
      cairo
      cups
      dbus
      expat
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libxkbcommon
      mesa
      nspr
      nss
      pango
      systemd        # libudev
      xorg.libX11
      xorg.libXcomposite
      xorg.libXdamage
      xorg.libXext
      xorg.libXfixes
      xorg.libXrandr
      xorg.libxcb
    ];

    runtimeDependencies = [
      pkgs.systemd   # libudev at runtime
    ];

    unpackPhase = ''
      tar xf $src
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/opt $out/bin $out/share

      cp -r opt/TobiiProEyeTrackerManager $out/opt/TobiiProEyeTrackerManager

      # Desktop file and icon
      if [ -d usr/share/applications ]; then
        cp -r usr/share/applications $out/share/
      fi
      if [ -d usr/share/icons ]; then
        cp -r usr/share/icons $out/share/
      fi

      # Wrapper with --no-sandbox (required for Electron without suid chrome-sandbox)
      makeWrapper $out/opt/TobiiProEyeTrackerManager/tobiiproeyetrackermanager $out/bin/tobii-pro-eye-tracker-manager \
        --add-flags "--no-sandbox"

      runHook postInstall
    '';
  };

  # ── opentrack-tobii ──────────────────────────────────────────────────
  # OpenTrack AppImage with Tobii input plugin (for Tobii → UDP relay)
  opentrack-tobii = pkgs.appimageTools.wrapType2 {
    pname = "opentrack-tobii";
    version = "2026.1.0";

    src = pkgs.fetchurl {
      url = "https://github.com/megagtrwrath/opentrack-appimage-ci/releases/download/opentrack-2026.1.0-20260312-072213Z/OpenTrack-TOBII-2026.1.0-x86_64.AppImage";
      hash = "sha256-1h/W3NMMrNiBHD3dlebIdjfFf3tALsCexIAlB6E7mK8=";
    };
  };

  # ── npclient-shm-dll ─────────────────────────────────────────────────
  # Custom NPClient64.dll compiled with MinGW that reads from proto-wine's
  # FT_SharedMem Windows named memory object via the shared wineserver.
  # proto-wine creates FT_SharedMem via its wine wrapper subprocess; both
  # opentrack's wine subprocess and SC connect to the same wineserver (via
  # /tmp Unix domain socket for the shared WINEPREFIX), so the named object
  # is accessible from SC regardless of Flatpak isolation.
  npclient-shm-dll = pkgs.pkgsCross.mingwW64.stdenv.mkDerivation {
    pname = "npclient-shm-dll";
    version = "1.1";

    src = pkgs.writeText "npclient-wine-shm.c" ''
      /* Custom NPClient64.dll for opentrack + GE-Proton.
       * Reads from proto-wine's FT_SharedMem Windows named memory object.
       * Both opentrack's wine wrapper and SC share the same wineserver via
       * the WINEPREFIX Unix domain socket in /tmp (shared across Flatpak).
       *
       * WineSHM layout (from proto-wine/wine-shm.h):
       *   data[0]=TX*10  data[1]=TY*10  data[2]=TZ*10
       *   data[3]=Yaw(rad) data[4]=Pitch(rad) data[5]=Roll(rad)
       * Negate yaw/pitch to match the original wineg++ wrapper behaviour. */
      #include <windows.h>
      #include <math.h>
      #include <string.h>

      #ifndef M_PI
      # define M_PI 3.14159265358979323846
      #endif
      #define NP_AXIS_MAX 16383

      typedef struct { double data[6]; int gameid, gameid2; unsigned char table[8]; unsigned char stop; } WineSHM;
      typedef struct { short status; short frame; unsigned cksum; float roll, pitch, yaw; float tx, ty, tz; float padding[9]; } tir_data_t;
      typedef struct { char DllSignature[200]; char AppSignature[200]; } tir_signature_t;

      #define NP_EXPORT(t) t __declspec(dllexport) __stdcall
      typedef enum { NPCLIENT_OK = 0, NPCLIENT_DISABLED } npclient_status;

      static HANDLE hMap  = NULL;
      static volatile WineSHM *shm = NULL;

      static BOOL open_shm(void) {
          if (shm) return TRUE;
          hMap = OpenFileMappingA(FILE_MAP_READ, FALSE, "FT_SharedMem");
          if (!hMap) return FALSE;
          shm = (volatile WineSHM *)MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, sizeof(WineSHM));
          if (!shm) { CloseHandle(hMap); hMap = NULL; return FALSE; }
          return TRUE;
      }

      static void close_shm(void) {
          if (shm)  { UnmapViewOfFile((LPCVOID)shm); shm = NULL; }
          if (hMap) { CloseHandle(hMap); hMap = NULL; }
      }

      BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
          (void)h; (void)r;
          if (reason == DLL_PROCESS_DETACH) close_shm();
          return TRUE;
      }

      static unsigned do_cksum(unsigned char *buf, unsigned size) {
          int rounds = size >> 2, rem = size % 4, c = size, a0 = 0, a2 = 0;
          if (!size || !buf) return 0;
          while (rounds--) { a0=*(short*)buf; a2=*(short*)(buf+2); buf+=4; c+=a0; a2^=(c<<5); a2<<=11; c^=a2; c+=(c>>11); }
          switch(rem) {
              case 3: a0=*(short*)buf; a2=*(signed char*)(buf+2); c+=a0; a2=(a2<<2)^c; c^=(a2<<16); a2=(c>>11); break;
              case 2: a2=*(short*)buf; c+=a2; c^=(c<<11); a2=(c>>17); break;
              case 1: a2=*(signed char*)buf; c+=a2; c^=(c<<10); a2=(c>>1); break;
              default: break;
          }
          if (rem) c+=a2;
          c^=(c<<3); c+=(c>>5); c^=(c<<4); c+=(c>>17); c^=(c<<25); c+=(c>>6);
          return (unsigned)c;
      }

      static double dclamp(double x) { return x > NP_AXIS_MAX ? NP_AXIS_MAX : x < -NP_AXIS_MAX ? -NP_AXIS_MAX : x; }

      NP_EXPORT(int) NP_GetData(tir_data_t *d) {
          static int frame = 0;
          double yaw=0,pitch=0,roll=0,tx=0,ty=0,tz=0;
          int i;
          if (open_shm() && shm && !shm->stop) {
              yaw   = -shm->data[3] * NP_AXIS_MAX / M_PI;
              pitch = -shm->data[4] * NP_AXIS_MAX / M_PI;
              roll  =  shm->data[5] * NP_AXIS_MAX / M_PI;
              tx    =  shm->data[0] * NP_AXIS_MAX / 500.0;
              ty    =  shm->data[1] * NP_AXIS_MAX / 500.0;
              tz    =  shm->data[2] * NP_AXIS_MAX / 500.0;
          }
          d->frame  = (short)++frame;
          d->status = (yaw||pitch||roll||tx||ty||tz) ? NPCLIENT_OK : NPCLIENT_DISABLED;
          d->cksum  = 0;
          d->yaw    = (float)dclamp(yaw);
          d->pitch  = (float)dclamp(pitch);
          d->roll   = (float)dclamp(roll);
          d->tx     = (float)dclamp(tx);
          d->ty     = (float)dclamp(ty);
          d->tz     = (float)dclamp(tz);
          for (i=0; i<9; i++) d->padding[i] = 0.0f;
          d->cksum  = do_cksum((unsigned char*)d, sizeof(tir_data_t));
          return d->status;
      }

      /* NaturalPoint signature bytes — XOR-encoded pairs from contrib/npclient/npclient.c */
      static const unsigned char _s1a[200]={0x1d,0x79,0xce,0x35,0x1d,0x95,0x79,0xdf,0x4c,0x8d,0x55,0xeb,0x20,0x17,0x9f,0x26,0x3e,0xf0,0x88,0x8e,0x7a,0x08,0x11,0x52,0xfc,0xd8,0x3f,0xb9,0xd2,0x5c,0x61,0x03,0x56,0xfd,0xbc,0xb4,0x0a,0xf1,0x13,0x5d,0x90,0x0a,0x0e,0xee,0x09,0x19,0x45,0x5a,0xeb,0xe3,0xf0,0x58,0x5f,0xac,0x23,0x84,0x1f,0xc5,0xe3,0xa6,0x18,0x5d,0xb8,0x47,0xdc,0xe6,0xf2,0x0b,0x03,0x55,0x61,0xab,0xe3,0x57,0xe3,0x67,0xcc,0x16,0x38,0x3c,0x11,0x25,0x88,0x8a,0x24,0x7f,0xf7,0xeb,0xf2,0x5d,0x82,0x89,0x05,0x53,0x32,0x6b,0x28,0x54,0x13,0xf6,0xe7,0x21,0x1a,0xc6,0xe3,0xe1,0xff};
      static const unsigned char _s1b[200]={0x6d,0x0b,0xab,0x56,0x74,0xe6,0x1c,0xff,0x24,0xe8,0x34,0x8f,0x00,0x63,0xed,0x47,0x5d,0x9b,0xe1,0xe0,0x1d,0x02,0x31,0x22,0x89,0xac,0x1f,0xc0,0xbd,0x29,0x13,0x23,0x3e,0x98,0xdd,0xd0,0x2a,0x98,0x7d,0x29,0xff,0x2a,0x7a,0x86,0x6c,0x39,0x22,0x3b,0x86,0x86,0xfa,0x78,0x31,0xc3,0x54,0xa4,0x78,0xaa,0xc3,0xca,0x77,0x32,0xd3,0x67,0xbd,0x94,0x9d,0x7e,0x6d,0x31,0x6b,0xa1,0xc3,0x14,0x8c,0x17,0xb5,0x64,0x51,0x5b,0x79,0x51,0xa8,0xcf,0x5d,0x1a,0xb4,0x84,0x9c,0x29,0xf0,0xe6,0x69,0x73,0x66,0x0e,0x4b,0x3c,0x7d,0x99,0x8b,0x4e,0x7d,0xaf,0x86,0x92,0xff};
      static const unsigned char _s2a[200]={0x8b,0x84,0xfc,0x8c,0x71,0xb5,0xd9,0xaa,0xda,0x32,0xc7,0xe9,0x0c,0x20,0x40,0xd4,0x4b,0x02,0x89,0xca,0xde,0x61,0x9d,0xfb,0xb3,0x8c,0x97,0x8a,0x13,0x6a,0x0f,0xf8,0xf8,0x0d,0x65,0x1b,0xe3,0x05,0x1e,0xb6,0xf6,0xd9,0x13,0xad,0xeb,0x38,0xdd,0x86,0xfc,0x59,0x2e,0xf6,0x2e,0xf4,0xb0,0xb0,0xfd,0xb0,0x70,0x23,0xfb,0xc9,0x1a,0x50,0x89,0x92,0xf0,0x01,0x09,0xa1,0xfd,0x5b,0x19,0x29,0x73,0x59,0x2b,0x81,0x83,0x9e,0x11,0xf3,0xa2,0x1f,0xc8,0x24,0x53,0x60,0x0a,0x42,0x78,0x7a,0x39,0xea,0xc1,0x59,0xad,0xc5,0x00};
      static const unsigned char _s2b[200]={0xe3,0xe5,0x8e,0xe8,0x06,0xd4,0xab,0xcf,0xfa,0x51,0xa6,0x84,0x69,0x52,0x21,0xde,0x6b,0x71,0xe6,0xac,0xaa,0x16,0xfc,0x89,0xd6,0xac,0xe7,0xf8,0x7c,0x09,0x6a,0x8b,0x8b,0x64,0x0b,0x7c,0xc3,0x61,0x7f,0xc2,0x97,0xd3,0x33,0xd9,0x99,0x59,0xbe,0xed,0xdc,0x2c,0x5d,0x93,0x5c,0xd4,0xdd,0xdf,0x8b,0xd5,0x1d,0x46,0x95,0xbd,0x10,0x5a,0xa9,0xd1,0x9f,0x71,0x70,0xd3,0x94,0x3c,0x71,0x5d,0x53,0x1c,0x52,0xe4,0xc0,0xf1,0x7f,0x87,0xd0,0x70,0xa4,0x04,0x07,0x05,0x69,0x2a,0x16,0x15,0x55,0x85,0xa6,0x30,0xc8,0xb6,0x00};

      NP_EXPORT(int) NP_GetSignature(tir_signature_t *s) {
          int i;
          for (i=0;i<200;i++) s->DllSignature[i] = _s1b[i]^_s1a[i];
          for (i=0;i<200;i++) s->AppSignature[i] = _s2a[i]^_s2b[i];
          return 0;
      }

      NP_EXPORT(int) NP_QueryVersion(unsigned short *v)            { *v=0x0500; return 0; }
      NP_EXPORT(int) NP_ReCenter(void)                             { return 0; }
      NP_EXPORT(int) NP_RegisterProgramProfileID(unsigned short i) { (void)i; return 0; }
      NP_EXPORT(int) NP_RegisterWindowHandle(HWND h)               { (void)h; return 0; }
      NP_EXPORT(int) NP_RequestData(unsigned short r)              { (void)r; return 0; }
      NP_EXPORT(int) NP_SetParameter(int a, int b)                 { (void)a;(void)b; return 0; }
      NP_EXPORT(int) NP_StartCursor(void)                          { return 0; }
      NP_EXPORT(int) NP_StartDataTransmission(void)                { return 0; }
      NP_EXPORT(int) NP_StopCursor(void)                           { return 0; }
      NP_EXPORT(int) NP_StopDataTransmission(void)                 { return 0; }
      NP_EXPORT(int) NP_UnregisterWindowHandle(void)               { return 0; }
      NP_EXPORT(int) NP_GetParameter(int a, int b)                 { (void)a;(void)b; return 0; }
      NP_EXPORT(int) NPPriv_ClientNotify(void)                     { return 0; }
      NP_EXPORT(int) NPPriv_GetLastError(void)                     { return 0; }
      NP_EXPORT(int) NPPriv_SetData(void)                          { return 0; }
      NP_EXPORT(int) NPPriv_SetLastError(void)                     { return 0; }
      NP_EXPORT(int) NPPriv_SetParameter(void)                     { return 0; }
      NP_EXPORT(int) NPPriv_SetSignature(void)                     { return 0; }
      NP_EXPORT(int) NPPriv_SetVersion(void)                       { return 0; }
    '';

    dontUnpack = true;
    dontConfigure = true;

    buildPhase = ''
      $CC -shared -O2 -o NPClient64.dll $src \
        -Wl,--high-entropy-va -Wl,--no-insert-timestamp \
        -lm
    '';

    installPhase = ''
      mkdir -p $out/lib
      cp NPClient64.dll $out/lib/
    '';
  };

  # ── opentrack-sc ─────────────────────────────────────────────────────
  # Star Citizen fork of opentrack with UMU/Proton Wine prefix fixes
  # https://github.com/Priton-CE/opentrack-StarCitizen (wine-extended-proton branch)
  opentrack-sc = let
    aruco = pkgs.callPackage
      "${pkgs.path}/pkgs/by-name/op/opentrack/aruco.nix" {};
    xplaneSdk = pkgs.fetchzip {
      url = "https://developer.x-plane.com/wp-content/plugins/code-sample-generation/sdk_zip_files/XPSDK411.zip";
      hash = "sha256-zay5QrHJctllVFl+JhlyTDzH68h5UoxncEt+TpW3UgI=";
    };
  in pkgs.stdenv.mkDerivation {
    pname = "opentrack-sc";
    version = "2024.1.1-sc";

    src = pkgs.fetchFromGitHub {
      owner = "Priton-CE";
      repo = "opentrack-StarCitizen";
      rev = "4dd97af0f139f3ddc8f34a24ee961a1046015d3f";
      hash = "sha256-xN4Z1Cpmj8ktqWCQYPZTfqznHrYe28qlKkPoQxHRPJ8=";
    };

    strictDeps = true;

    # Patch tracker-tobii to build on Linux (upstream only enables it on WIN32).
    # The source already uses the cross-platform Stream Engine API; we just need
    # find_library/find_path guards instead of the Windows-only path logic.
    postPatch = ''
      cat > tracker-tobii/CMakeLists.txt <<'EOF'
if(WIN32)
    set(SDK_TOBII "" CACHE PATH "Tobii Stream Engine path")
    if(SDK_TOBII)
        otr_module(tracker-tobii)
        if("''${CMAKE_SIZEOF_VOID_P}" STREQUAL "4")
            set(arch "x86")
        else()
            set(arch "x64")
        endif()
        target_include_directories(''${self} SYSTEM PRIVATE "''${SDK_TOBII}/include")
        target_link_directories(''${self} PRIVATE "''${SDK_TOBII}/lib/''${arch}")
        set(dll "''${SDK_TOBII}/lib/''${arch}/tobii_stream_engine.dll")
        target_link_libraries(''${self} tobii_stream_engine.lib)
        install(FILES ''${dll} DESTINATION ''${opentrack-libexec})
    endif()
else()
    find_library(TOBII_SE_LIB tobii_stream_engine)
    find_path(TOBII_SE_INCLUDE tobii/tobii.h)
    if(TOBII_SE_LIB AND TOBII_SE_INCLUDE)
        otr_module(tracker-tobii)
        target_include_directories(''${self} SYSTEM PRIVATE "''${TOBII_SE_INCLUDE}")
        target_link_libraries(''${self} "''${TOBII_SE_LIB}")
    endif()
endif()
EOF
    '';

    nativeBuildInputs = [
      pkgs.cmake
      pkgs.ninja
      pkgs.pkg-config
      pkgs.libsForQt5.wrapQtAppsHook
      # No wine needed: SDK_WINE is unset (no-wrapper mode), wineg++ not invoked
    ];

    buildInputs = [
      aruco
      tobii-stream-engine
      pkgs.eigen
      pkgs.xorg.libXdmcp
      pkgs.libevdev
      pkgs.onnxruntime
      pkgs.opencv4
      pkgs.procps
      pkgs.libsForQt5.qtbase
      pkgs.libsForQt5.qttools
    ];

    cmakeFlags = [
      # SDK_WINE intentionally not set — this source build is only used for
      # NPClient64.dll (overwritten by npclient-shm-dll in postInstall).
      # The actual opentrack binary used at runtime is the AppImage (opentrack-tobii).
      (lib.cmakeFeature "SDK_ARUCO_LIBPATH" "${aruco}/lib/libaruco.a")
      (lib.cmakeFeature "SDK_XPLANE" xplaneSdk.outPath)
    ];

    postInstall = ''
      install -Dt $out/share/icons/hicolor/256x256 $src/gui/images/opentrack.png
      # Replace stock NPClient64.dll (reads Windows named memory FT_SharedMem,
      # requires the wineg++ wrapper) with our POSIX-shm-native version.
      cp ${npclient-shm-dll}/lib/NPClient64.dll $out/libexec/opentrack/NPClient64.dll
    '';

    dontWrapQtApps = true;
    preFixup = ''
      wrapQtApp $out/bin/opentrack
    '';
  };

in
{
  # Expose /libexec in the system profile so opentrack-sc's NPClient DLLs are reachable
  # at the stable path Z:/run/current-system/sw/libexec/opentrack/ from within the Flatpak.
  environment.pathsToLink = [ "/libexec" ];

  # Make packages available
  environment.systemPackages = [
    tobii-stream-engine
    tobii-pro-eye-tracker-manager
    opentrack-tobii  # AppImage with Tobii tracker — runs opentrack (tracker side)
    opentrack-sc     # Source build — provides NPClient64.dll in /libexec/opentrack/
  ];

  # ── Systemd services ────────────────────────────────────────────────
  systemd.services.tobii-engine = {
    description = "Tobii Engine Service";
    after = [ "network.target" ];
    wantedBy = lib.mkForce [];

    serviceConfig = {
      Type = "simple";
      StateDirectory = "tobii_engine";
      ExecStartPre = pkgs.writeShellScript "tobii-engine-setup" ''
        # Copy engine files to writable state dir so config.db can be written
        src="${tobii-engine}/share/tobii_engine"
        dst="/var/lib/tobii_engine"
        # Only copy if not already populated (preserve calibration data)
        if [ ! -f "$dst/tobii_engine" ]; then
          ${pkgs.coreutils}/bin/cp -r "$src"/* "$dst"/
          ${pkgs.coreutils}/bin/chmod -R u+w "$dst"
        else
          # Always update binary + libs from store (new derivation version)
          ${pkgs.coreutils}/bin/cp -f "$src/tobii_engine" "$dst/"
          ${pkgs.coreutils}/bin/cp -rf "$src/lib" "$dst/"
          ${pkgs.coreutils}/bin/cp -rf "$src/platform_modules" "$dst/"
          ${pkgs.coreutils}/bin/chmod -R u+w "$dst"
        fi
      '';
      ExecStart = "/var/lib/tobii_engine/tobii_engine --daemonize";
      WorkingDirectory = "/var/lib/tobii_engine";
      Restart = "on-abort";
    };
  };

  # ── opentrack-sc user service ────────────────────────────────────────
  # Runs opentrack-sc *inside* the RSILauncher Flatpak sandbox so it inherits
  # WINEPREFIX=/var/data/prefix and PROTONPATH=GE-Proton, sharing SC's wineserver.
  # Not started automatically — manage manually:
  #   systemctl --user start opentrack-sc
  #   systemctl --user stop  opentrack-sc
  systemd.user.services.opentrack-sc = {
    description = "OpenTrack SC — TrackIR head tracking for Star Citizen";
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      # proto-wine needs wine in PATH and the SC WINEPREFIX so its wine wrapper
      # connects to the same wineserver as SC (shared via /tmp socket across Flatpak).
      # FT_SharedMem created by the wrapper is readable by NPClient64.dll via
      # OpenFileMappingA from any wine process on the same wineserver.
      ExecStart = let
        # GE-Proton's `wine` is 32-bit ELF needing /lib/ld-linux.so.2 which is
        # absent in the AppImage bwrap sandbox. Create a `wine` shim that calls
        # `wine64` (64-bit, works on NixOS) so proto-wine finds it in PATH.
        wine-shim = pkgs.writeShellScriptBin "wine" ''
          exec "$HOME/.var/app/io.github.mactan_sc.RSILauncher/.local/share/Steam/compatibilitytools.d/GE-Proton10-30/files/bin/wine64" "$@"
        '';
        wrapper = pkgs.writeShellScript "opentrack-sc-wrapper" ''
          export WINEPREFIX="$HOME/.var/app/io.github.mactan_sc.RSILauncher/data/prefix"
          export PATH="${wine-shim}/bin:$HOME/.var/app/io.github.mactan_sc.RSILauncher/.local/share/Steam/compatibilitytools.d/GE-Proton10-30/files/bin:$PATH"
          exec ${opentrack-tobii}/bin/opentrack-tobii "$@"
        '';
      in "${wrapper}";
      Restart = "on-failure";
      RestartSec = "3s";
    };
  };

  systemd.services.tobii-usb = {
    description = "Tobii USB Service";
    requires = [ "tobii-engine.service" ];
    after = [ "tobii-engine.service" ];
    wantedBy = lib.mkForce [];

    serviceConfig = {
      Type = "forking";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/run/tobiiusb";
      ExecStart = "${tobii-usb-service}/bin/tobiiusbserviced";
      Restart = "on-failure";
    };
  };
}
