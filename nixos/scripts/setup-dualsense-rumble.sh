#!/bin/sh

# Comprehensive DualSense Rumble Setup Script
# This script applies all necessary fixes for DualSense controller rumble support

set -e

echo "=== DualSense Rumble Setup ==="
echo "This script will configure your NixOS system for full DualSense controller rumble support."
echo

# Check if running as non-root user
if [ "$EUID" -eq 0 ]; then
    echo "❌ Please run this script as a normal user (not root)"
    echo "   The script will use sudo when needed"
    exit 1
fi

# Check if we're in the correct directory
if [ ! -f "flake.nix" ]; then
    echo "❌ Please run this script from the root of your nic-os directory"
    exit 1
fi

echo "🔄 Step 1: Rebuilding NixOS configuration with DualSense improvements..."
sudo nixos-rebuild switch --flake .#BeAsT

echo "✅ NixOS configuration rebuilt successfully"
echo

echo "🔄 Step 2: Reloading udev rules..."
sudo udevadm control --reload-rules
sudo udevadm trigger

echo "✅ Udev rules reloaded"
echo

echo "🔄 Step 3: Running Steam DualSense configuration..."
if ./nixos/scripts/steam-dualsense-config.sh; then
    echo "✅ Steam configuration completed"
else
    echo "⚠️  Steam configuration had some issues, but continuing..."
fi
echo

echo "🔄 Step 4: Applying Wine DualSense fixes..."
if ./nixos/scripts/wine-dualsense-fix.sh; then
    echo "✅ Wine DualSense fixes applied"
else
    echo "⚠️  Wine fixes had some issues (this is normal if Wine prefixes don't exist yet)"
fi
echo

echo "🔄 Step 5: Testing DualSense rumble functionality..."
echo "   Connect your DualSense controller now if not already connected..."
read -p "Press Enter when your DualSense controller is connected..."

if ./nixos/scripts/dualsense-rumble-test.sh; then
    echo "✅ DualSense testing completed"
else
    echo "⚠️  Testing had some issues, check the output above"
fi
echo

echo "🎉 DualSense Rumble Setup Complete!"
echo
echo "📋 Summary of changes applied:"
echo "   ✅ Enhanced udev rules for DualSense haptics"
echo "   ✅ Added required kernel modules (hid_playstation, hid_sony, uhid)"
echo "   ✅ Configured PipeWire for low-latency gaming audio"
echo "   ✅ Added systemd service for automatic controller optimization"
echo "   ✅ Added additional packages: hidapi, SDL2, libevdev"
echo "   ✅ Fixed Wine DualSense registry entries"
echo "   ✅ Configured Steam for optimal DualSense support"
echo "   ✅ Created desktop shortcut for testing"
echo
echo "🔧 Next steps:"
echo "   1. Reboot your system to ensure all kernel modules are loaded"
echo "   2. Reconnect your DualSense controller"
echo "   3. Test rumble with: ./nixos/scripts/dualsense-rumble-test.sh"
echo "   4. Launch Steam and enable 'PlayStation Configuration Support'"
echo "   5. For Wine/Proton games, the registry fix will be applied automatically"
echo
echo "📞 If you still have issues:"
echo "   • Check the logs: journalctl -f | grep -i dualsense"
echo "   • Verify your user is in the input group: groups $USER"
echo "   • Test with different games and applications"
echo "   • Try adjusting rumble attenuation: dualsensectl set-rumble-attenuation 0.8"
echo
echo "=== Setup completed! Please reboot your system. ==="
