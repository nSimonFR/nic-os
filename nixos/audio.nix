{ pkgs, ... }:
{
  # PipeWire filter-chain nodes for DeepFilter
  xdg.configFile."pipewire/pipewire.conf.d/deepfilter-mono-source.conf" = {
    text = builtins.toJSON {
      "context.modules" = [
        {
          name = "libpipewire-module-filter-chain";
          args = {
            "node.description" = "DeepFilter Noise Canceling Source";
            "media.name" = "DeepFilter Noise Canceling Source";
            "filter.graph" = {
              nodes = [
                {
                  type = "ladspa";
                  name = "DeepFilter Mono";
                  plugin = "${pkgs.deepfilternet}/lib/ladspa/libdeep_filter_ladspa.so";
                  label = "deep_filter_mono";
                  control = {
                    "Attenuation Limit (dB)" = 100;
                  };
                }
              ];
            };
            "audio.rate" = 48000;
            "audio.position" = "[MONO]";
            "capture.props" = {
              "node.passive" = true;
            };
            "playback.props" = {
              "media.class" = "Audio/Source";
            };
          };
        }
      ];
    };
  };

  # DeepFilter Stereo Sink - processes Discord output audio
  # This creates a virtual sink that Discord can output to, which then gets filtered
  # Use PipeWire's native config format (not JSON) for better control
  xdg.configFile."pipewire/pipewire.conf.d/deepfilter-stereo-sink.conf" = {
    text = ''
      context.modules = [
        {
          name = libpipewire-module-filter-chain
          args = {
            node.description = "DeepFilter Noise Canceling Sink"
            media.name = "DeepFilter Noise Canceling Sink"
            filter.graph = {
              nodes = [
                {
                  type = ladspa
                  name = "DeepFilter Stereo"
                  plugin = "${pkgs.deepfilternet}/lib/ladspa/libdeep_filter_ladspa.so"
                  label = deep_filter_stereo
                  control = { "Attenuation Limit (dB)" = 100 }
                }
              ]
            }
            audio.rate = 48000
            audio.channels = 2
            audio.position = [ FL FR ]
            capture.props = {
              node.name = "deep_filter_stereo_input"
              media.class = "Audio/Sink"
              audio.position = [ FL FR ]
            }
            playback.props = {
              node.name = "deep_filter_stereo_output"
              stream.dont-remix = true
              audio.position = [ FL FR ]
            }
          }
        }
      ]
    '';
  };

  # Fix audio crackling by adjusting quantum settings
  # Lower values = lower latency but higher CPU usage
  # Higher values = higher latency but more stable
  # These values provide ~10-21ms latency which is imperceptible
  xdg.configFile."pipewire/pipewire.conf.d/99-audio-fix.conf" = {
    text = ''
      context.properties = {
        default.clock.rate          = 48000
        default.clock.allowed-rates = [ 48000 ]
        default.clock.quantum       = 800
        default.clock.min-quantum   = 512
        default.clock.max-quantum   = 1024
      }
    '';
  };

  # Fix Wine/Proton audio crackling
  # Adjust pulse compatibility layer quantum values
  xdg.configFile."pipewire/pipewire-pulse.conf.d/99-pulse-fix.conf" = {
    text = ''
      pulse.properties = {
        pulse.min.req          = 512/48000
        pulse.min.frag         = 512/48000
        pulse.min.quantum      = 512/48000
        pulse.default.req      = 800/48000
      }
    '';
  };

  xdg.configFile."wireplumber/wireplumber.conf.d/51-disable.conf" = {
    text = ''
      "monitor.alsa.rules": [
        {
          "matches": [
            { "node.name": "alsa_output.usb-Generic_USB_Audio-00.HiFi_5_1__SPDIF__sink" },
            { "node.name": "alsa_output.usb-Generic_USB_Audio-00.HiFi_5_1__Headphones__sink" },
            { "node.name": "alsa_input.usb-Generic_USB_Audio-00.HiFi_5_1__Mic1__source" },
            { "node.name": "alsa_input.usb-Generic_USB_Audio-00.HiFi_5_1__Line1__source" }
          ],
          "actions": { "update-props": { "node.disabled": true } }
        }
      ]
    '';
  };
}
