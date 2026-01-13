#!/bin/sh

# Steam DualSense Configuration Script
# Configures Steam for optimal DualSense controller support including rumble

set -e

echo "=== Steam DualSense Configuration ==="
echo

STEAM_CONFIG_DIR="$HOME/.steam/steam/config"
STEAM_USERDATA_DIR="$HOME/.steam/steam/userdata"

# Create Steam config directory if it doesn't exist
mkdir -p "$STEAM_CONFIG_DIR"

# Create controller configuration
echo "🎮 Configuring Steam controller settings..."

cat > "$STEAM_CONFIG_DIR/controller_ps5.vdf" << 'EOF'
"controller_ps5"
{
    "workshop"
    {
        "enable_dualsense_haptics"        "1"
        "enable_dualsense_adaptive_triggers"    "1"
        "enable_dualsense_enhanced_rumble"    "1"
        "disable_dualsense_touchpad"        "0"
        "dualsense_rumble_attenuation"        "1.0"
        "dualsense_haptic_intensity"        "1.0"
    }
}
EOF

# Configure launch options for better controller support
echo "📝 Adding recommended Steam launch options..."
echo "   Add these launch options to games that support DualSense:"
echo "   • For Proton games: PROTON_ENABLE_NVAPI=1 PROTON_USE_WINED3D=0 %command%"
echo "   • For native games: SDL_JOYSTICK_HIDAPI_PS5_RUMBLE=1 %command%"
echo

# Create a desktop file for quick access to dualsense tools
echo "🖥️  Creating desktop shortcuts..."
mkdir -p "$HOME/.local/share/applications"

cat > "$HOME/.local/share/applications/dualsense-test.desktop" << EOF
[Desktop Entry]
Name=DualSense Rumble Test
Comment=Test DualSense controller rumble functionality
Exec=/home/nsimon/nic-os/nixos/scripts/dualsense-rumble-test.sh
Icon=input-gaming
Terminal=true
Type=Application
Categories=Game;Utility;
EOF

# Make scripts executable
chmod +x /home/nsimon/nic-os/nixos/scripts/dualsense-rumble-test.sh
chmod +x /home/nsimon/nic-os/nixos/scripts/steam-dualsense-config.sh
chmod +x /home/nsimon/nic-os/nixos/scripts/wine-dualsense-fix.sh

echo "✅ Steam DualSense configuration completed"
echo
echo "📋 Next steps:"
echo "   1. Restart Steam to apply controller settings"
echo "   2. In Steam, go to Settings > Controller > General Controller Settings"
echo "   3. Enable 'PlayStation Configuration Support'"
echo "   4. Test with the DualSense test script: ./dualsense-rumble-test.sh"
echo "   5. For specific games, add the recommended launch options"
echo

echo "🔧 Troubleshooting:"
echo "   • If rumble still doesn't work, try: dualsensectl set-rumble-attenuation 1.0"
echo "   • Check game-specific controller settings"
echo "   • Some games may need 'Generic Gamepad Configuration Support' disabled"
echo

echo "=== Configuration completed ===" 
