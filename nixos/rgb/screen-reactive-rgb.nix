{ config, lib, pkgs, ... }:

let
  # Create a Python script for screen-reactive RGB
  screenReactiveRGB = pkgs.python312.pkgs.buildPythonApplication {
    pname = "screen-reactive-rgb";
    version = "1.0.0";
    
    propagatedBuildInputs = with pkgs.python312.pkgs; [
      openrgb-python
      mss
      pillow
      numpy
    ];
    
    src = pkgs.writeTextDir "screen_reactive_rgb.py" ''
      #!/usr/bin/env python3
      """
      Screen-Reactive RGB for OpenRGB
      Captures screen colors and sends them to OpenRGB devices
      """
      import time
      import argparse
      from openrgb import OpenRGBClient
      from openrgb.utils import RGBColor, DeviceType
      from mss import mss
      from PIL import Image
      import numpy as np
      
      def get_average_color(screenshot, x, y, w, h):
          """Get average color from a region of the screen"""
          region = screenshot.crop((x, y, x + w, y + h))
          np_img = np.array(region)
          avg_color = np_img.mean(axis=(0, 1)).astype(int)
          return tuple(avg_color[:3])  # Return RGB only
      
      def main():
          parser = argparse.ArgumentParser(description='Screen-Reactive RGB for OpenRGB')
          parser.add_argument('--host', default='127.0.0.1', help='OpenRGB SDK server host')
          parser.add_argument('--port', default=6742, type=int, help='OpenRGB SDK server port')
          parser.add_argument('--fps', default=10, type=int, help='Update frequency (FPS)')
          parser.add_argument('--brightness', default=100, type=int, help='Brightness (0-100)')
          parser.add_argument('--zones', default=1, type=int, help='Number of screen zones (1, 4, or 9)')
          args = parser.parse_args()
          
          print(f"Connecting to OpenRGB at {args.host}:{args.port}...")
          try:
              client = OpenRGBClient(args.host, args.port)
          except Exception as e:
              print(f"Error connecting to OpenRGB: {e}")
              print("Make sure OpenRGB is running with SDK server enabled!")
              return 1
          
          print(f"Connected! Found {client.ee_device_count} devices")
          
          # Get all controllable devices
          devices = []
          for i in range(client.ee_device_count):
              device = client.ee_devices[i]
              print(f"  - {device.name} ({device.type})")
              devices.append(device)
          
          if not devices:
              print("No devices found!")
              return 1
          
          sct = mss()
          monitor = sct.monitors[1]  # Primary monitor
          
          print(f"\nStarting screen capture at {args.fps} FPS")
          print(f"Screen size: {monitor['width']}x{monitor['height']}")
          print(f"Zones: {args.zones}")
          print("Press Ctrl+C to stop\n")
          
          frame_time = 1.0 / args.fps
          brightness_factor = args.brightness / 100.0
          
          try:
              while True:
                  start_time = time.time()
                  
                  # Capture screen
                  sct_img = sct.grab(monitor)
                  img = Image.frombytes('RGB', sct_img.size, sct_img.bgra, 'raw', 'BGRX')
                  
                  # Calculate average color (simple mode: whole screen)
                  if args.zones == 1:
                      avg_color = get_average_color(img, 0, 0, monitor['width'], monitor['height'])
                  else:
                      # For now, just use whole screen average
                      avg_color = get_average_color(img, 0, 0, monitor['width'], monitor['height'])
                  
                  # Apply brightness
                  r = int(avg_color[0] * brightness_factor)
                  g = int(avg_color[1] * brightness_factor)
                  b = int(avg_color[2] * brightness_factor)
                  
                  # Set color on all devices
                  for device in devices:
                      try:
                          device.set_color(RGBColor(r, g, b))
                      except Exception as e:
                          pass  # Ignore device errors
                  
                  # Maintain frame rate
                  elapsed = time.time() - start_time
                  if elapsed < frame_time:
                      time.sleep(frame_time - elapsed)
          
          except KeyboardInterrupt:
              print("\nStopping...")
              # Reset devices to their default
              for device in devices:
                  try:
                      device.set_mode('static')
                  except:
                      pass
              return 0
      
      if __name__ == '__main__':
          exit(main())
    '';
    
    format = "other";
    
    installPhase = ''
      mkdir -p $out/bin
      cp screen_reactive_rgb.py $out/bin/screen-reactive-rgb
      chmod +x $out/bin/screen-reactive-rgb
    '';
  };

in {
  environment.systemPackages = [ screenReactiveRGB ];
  
  # Systemd user service for automatic startup
  systemd.user.services.screen-reactive-rgb = {
    description = "Screen-Reactive RGB";
    after = [ "graphical-session.target" ];
    wants = [ "openrgb.service" ];
    
    serviceConfig = {
      Type = "simple";
      ExecStart = "${screenReactiveRGB}/bin/screen-reactive-rgb --fps 15 --brightness 80";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    
    # Don't start automatically - user can enable if desired
    wantedBy = [ ];
  };
}

