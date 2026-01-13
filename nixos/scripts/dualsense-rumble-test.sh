#!/bin/sh

# DualSense Rumble Test and Troubleshooting Script
# This script helps diagnose and test DualSense controller rumble functionality

set -e

echo "=== DualSense Rumble Test & Troubleshooting ==="
echo

# Check if dualsensectl is available
if ! command -v dualsensectl &> /dev/null; then
    echo "❌ dualsensectl not found. Please install it first."
    exit 1
fi

# Find connected DualSense controllers
echo "🔍 Scanning for DualSense controllers..."
controllers=$(dualsensectl -l 2>/dev/null || echo "")

if [ -z "$controllers" ]; then
    echo "❌ No DualSense controllers found."
    echo "   Make sure your controller is connected and paired."
    echo "   Try: sudo bluetoothctl connect <controller_mac>"
    exit 1
fi

echo "✅ Found DualSense controller(s):"
echo "$controllers"
echo

# Test basic rumble functionality
echo "🎮 Testing rumble functionality..."
echo "   This will test left and right rumble motors..."

# Test left motor (low frequency)
echo "   Testing left motor (low frequency)..."
dualsensectl rumble --left-motor 255 --right-motor 0 --duration 1000 2>/dev/null || echo "   ⚠️  Left motor test failed"
sleep 1.5

# Test right motor (high frequency)
echo "   Testing right motor (high frequency)..."
dualsensectl rumble --left-motor 0 --right-motor 255 --duration 1000 2>/dev/null || echo "   ⚠️  Right motor test failed"
sleep 1.5

# Test both motors
echo "   Testing both motors together..."
dualsensectl rumble --left-motor 255 --right-motor 255 --duration 1500 2>/dev/null || echo "   ⚠️  Both motors test failed"
sleep 2

echo "✅ Rumble tests completed"
echo

# Check rumble attenuation settings
echo "📊 Checking rumble attenuation settings..."
dualsensectl get-rumble-attenuation 2>/dev/null || echo "   ⚠️  Could not read rumble attenuation"

# Show controller info
echo "ℹ️  Controller information:"
dualsensectl info 2>/dev/null || echo "   ⚠️  Could not read controller info"

echo
echo "🔧 Troubleshooting Tips:"
echo "   • Make sure your user is in the 'input' group"
echo "   • Check udev rules: ls -la /dev/hidraw* | grep 054c"
echo "   • Test with different games or applications"
echo "   • For Wine/Proton games, make sure the Wine DualSense fix is applied"
echo "   • Try adjusting rumble attenuation: dualsensectl set-rumble-attenuation <value>"
echo "   • Check system logs: journalctl -f | grep -i dualsense"
echo

# Provide quick commands for common fixes
echo "🛠️  Quick fixes to try:"
echo "   1. Reset controller: dualsensectl reset"
echo "   2. Test with different attenuation: dualsensectl set-rumble-attenuation 0.5"
echo "   3. Check permissions: ls -la /dev/hidraw*"
echo "   4. Restart udev rules: sudo udevadm control --reload-rules && sudo udevadm trigger"
echo

echo "=== Test completed ==="
