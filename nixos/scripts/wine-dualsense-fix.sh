#!/bin/sh
set -e

user_home="/home/nsimon"
apps_pfxs=(
  /mnt/games/SteamLibrary/steamapps/compatdata/2322010/pfx # God of War Ragnarökr Ragnarök
)

echo "Checking for Wine controller registry fix..."

for app_pfx in ${apps_pfxs[@]}; do
  if [ -d "$app_pfx" ]; then
    WINEPREFIX="$app_pfx" wine reg query "HKLM\\SYSTEM\\CurrentControlSet\\Enum\\HID\\VID_054C&PID_0CE6\\256&00:00:00:00:00:00&0&0&0" /v ContainerId > /dev/null 2>&1

    if [ $? -ne 0 ]; then
      echo "Applying DualSense registry fix to $app_pfx"
      regfile=$(mktemp)
      cat > "$regfile" << EOF
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\HID\VID_054C&PID_0CE6\256&00:00:00:00:00:00&0&0&0]
"ContainerId"="{e27ebefb-ddd4-11ef-abea-40b076a40d44}"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\HidClass\DualSense]
"DisableGamepadSupport"=dword:00000000
"EnableRumble"=dword:00000001
EOF

      WINEPREFIX="$app_pfx" wine regedit "$regfile"
      rm -f "$regfile"
      echo "Registry fix applied successfully"
    else
      echo "Registry fix already applied for $app_pfx"
    fi
  else
    echo "Wine prefix not found: $app_pfx"
  fi
done 

echo "Wine DualSense fix completed" 
