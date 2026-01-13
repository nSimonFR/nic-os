{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Bridge script that receives UDP data from Hyperion and sends to OpenRGB
  hyperion-openrgb-bridge = pkgs.python312.pkgs.buildPythonApplication {
    pname = "hyperion-openrgb-bridge";
    version = "1.0.0";

    propagatedBuildInputs = with pkgs.python312.pkgs; [
      openrgb-python
    ];

    src = pkgs.writeTextDir "hyperion_openrgb_bridge.py" ''
      #!/usr/bin/env python3
      """
      Bridge between Hyperion and OpenRGB
      Receives UDP packets from Hyperion and forwards to OpenRGB
      """
      import socket
      import struct
      import time
      import argparse
      from openrgb import OpenRGBClient
      from openrgb.utils import RGBColor

      class HyperionOpenRGBBridge:
          def __init__(self, hyperion_host='0.0.0.0', hyperion_port=19446, 
                       openrgb_host='127.0.0.1', openrgb_port=6742):
              self.hyperion_host = hyperion_host
              self.hyperion_port = hyperion_port
              self.openrgb_host = openrgb_host
              self.openrgb_port = openrgb_port
              self.sock = None
              self.client = None
              self.devices = []
              
          def connect_openrgb(self):
              """Connect to OpenRGB SDK server"""
              print(f"Connecting to OpenRGB at {self.openrgb_host}:{self.openrgb_port}...")
              try:
                  self.client = OpenRGBClient(self.openrgb_host, self.openrgb_port)
                  self.devices = list(self.client.devices)
                  print(f"Connected! Found {len(self.devices)} devices:")
                  for device in self.devices:
                      print(f"  - {device.name}")
                  return True
              except Exception as e:
                  print(f"Error connecting to OpenRGB: {e}")
                  return False
          
          def setup_udp_listener(self):
              """Setup UDP socket to listen for Hyperion data"""
              print(f"Setting up UDP listener on {self.hyperion_host}:{self.hyperion_port}...")
              self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
              self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
              self.sock.bind((self.hyperion_host, self.hyperion_port))
              print("UDP listener ready!")
          
          def parse_udpraw(self, data):
              """Parse UDP Raw protocol from Hyperion (RGB data)"""
              # UDP Raw is just raw RGB data: R G B R G B R G B...
              num_leds = len(data) // 3
              colors = []
              for i in range(num_leds):
                  r = data[i * 3]
                  g = data[i * 3 + 1]
                  b = data[i * 3 + 2]
                  colors.append((r, g, b))
              return colors
          
          def calculate_average_color(self, colors):
              """Calculate average color from LED data"""
              if not colors:
                  return (0, 0, 0)
              
              r_sum = sum(c[0] for c in colors)
              g_sum = sum(c[1] for c in colors)
              b_sum = sum(c[2] for c in colors)
              count = len(colors)
              
              return (r_sum // count, g_sum // count, b_sum // count)
          
          def send_to_openrgb(self, color):
              """Send color to all OpenRGB devices"""
              r, g, b = color
              for device in self.devices:
                  try:
                      device.set_color(RGBColor(r, g, b))
                  except Exception as e:
                      pass  # Ignore device errors
          
          def run(self):
              """Main loop"""
              if not self.connect_openrgb():
                  print("Failed to connect to OpenRGB. Is it running with SDK enabled?")
                  return 1
              
              self.setup_udp_listener()
              
              print("\nBridge running! Waiting for Hyperion data...")
              print("Press Ctrl+C to stop\n")
              
              try:
                  while True:
                      data, addr = self.sock.recvfrom(65535)
                      
                      # Parse colors from UDP packet
                      colors = self.parse_udpraw(data)
                      
                      # Calculate average color (simple mode)
                      avg_color = self.calculate_average_color(colors)
                      
                      # Send to OpenRGB
                      self.send_to_openrgb(avg_color)
                      
              except KeyboardInterrupt:
                  print("\nStopping bridge...")
                  # Reset devices
                  for device in self.devices:
                      try:
                          device.set_mode('static')
                      except:
                          pass
                  return 0
              finally:
                  if self.sock:
                      self.sock.close()

      def main():
          parser = argparse.ArgumentParser(description='Hyperion to OpenRGB Bridge')
          parser.add_argument('--hyperion-host', default='0.0.0.0', 
                              help='Hyperion UDP host to listen on (default: 0.0.0.0)')
          parser.add_argument('--hyperion-port', type=int, default=19446, 
                              help='Hyperion UDP port (default: 19446)')
          parser.add_argument('--openrgb-host', default='127.0.0.1', 
                              help='OpenRGB SDK host (default: 127.0.0.1)')
          parser.add_argument('--openrgb-port', type=int, default=6742, 
                              help='OpenRGB SDK port (default: 6742)')
          args = parser.parse_args()
          
          bridge = HyperionOpenRGBBridge(
              hyperion_host=args.hyperion_host,
              hyperion_port=args.hyperion_port,
              openrgb_host=args.openrgb_host,
              openrgb_port=args.openrgb_port
          )
          
          return bridge.run()

      if __name__ == '__main__':
          exit(main())
    '';

    format = "other";

    installPhase = ''
      mkdir -p $out/bin
      cp hyperion_openrgb_bridge.py $out/bin/hyperion-openrgb-bridge
      chmod +x $out/bin/hyperion-openrgb-bridge
    '';
  };

in
{
  environment.systemPackages = [ hyperion-openrgb-bridge ];

  # Systemd service for the bridge
  systemd.user.services.hyperion-openrgb-bridge = {
    description = "Hyperion to OpenRGB Bridge";
    after = [ "hyperion.service" ];
    requires = [ "hyperion.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${hyperion-openrgb-bridge}/bin/hyperion-openrgb-bridge";
      Restart = "on-failure";
      RestartSec = "5s";
    };

    # Disabled - using OpenRGB effects instead
    # wantedBy = [ "default.target" ];
  };

  # Open firewall for bridge UDP port
  networking.firewall.allowedUDPPorts = [ 19446 ];
}
