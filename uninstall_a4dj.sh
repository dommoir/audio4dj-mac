#!/bin/bash
# a4dj-uninstaller-version: 2
# Removes the Audio 4 DJ driver, its helper service and the self-test from this Mac.
# It asks for your Mac password once. Your audio may cut out for a second while macOS restarts its audio service.

echo "Removing the Audio 4 DJ driver (your Mac password may be asked for)..."

# stop the helper service and stop it starting at boot
sudo launchctl bootout system/com.saintdesign.audio4dj.helper 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.saintdesign.audio4dj.helper.plist

# the programs and the log
sudo rm -f /usr/local/libexec/a4dj-helper /usr/local/bin/a4dj-selftest
sudo rm -f /var/log/a4dj-helper.log
rm -f /tmp/a4dj_selftest.dat

# the driver itself, then restart the audio service so macOS forgets the device
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Audio4DJ.driver
sudo killall coreaudiod 2>/dev/null || true

sleep 2
left=""
[ -e /Library/Audio/Plug-Ins/HAL/Audio4DJ.driver ] && left="$left driver"
[ -e /Library/LaunchDaemons/com.saintdesign.audio4dj.helper.plist ] && left="$left service"
[ -e /usr/local/libexec/a4dj-helper ] && left="$left helper"
if [ -z "$left" ]; then
    echo "Done. The Audio 4 DJ driver and everything that came with it has been removed."
else
    echo "Something could not be removed:$left"
fi
