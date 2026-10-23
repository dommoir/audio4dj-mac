# audio4dj-mac
An AI assisted driver to resurrect the Audio 4 audio interface for Mac Silicon

# Audio 4 DJ driver for Apple Silicon Macs

A free, open-source driver that gets the Native Instruments Audio 4 DJ working on M1, M2, M3 and later Macs.

NI stopped supporting the Audio 4 DJ before Apple Silicon arrived, so the box has no driver on modern Macs. This one makes it show up as a normal 4 in / 4 out sound card that Traktor, Ableton, Logic and anything else on the Mac can use.

## Provided as is

This is a hobby project, shared with the DJ community in case it helps. It comes with no warranty and no promise of support. Use it at your own risk.

It has been tested on one Mac: an M3 MacBook Pro running macOS Sonoma 14.6, playing through Traktor. It may work on other Apple Silicon Macs and macOS versions, or it may not. macOS 15 (Sequoia) and later may refuse to load it, because they are stricter about how audio drivers are signed.

This project is not made, endorsed or supported by Native Instruments. "Native Instruments", "Audio 4 DJ" and "Traktor" are their trademarks, used here only to say which hardware this works with.

## What works

- Audio 4 DJ appears in Audio MIDI Setup and in your apps as "Audio 4 DJ"
- 4 outputs and 4 inputs at 44.1 kHz, 24-bit
- Clean playback, tested in Traktor
- Plug and unplug: the driver picks the box up again when you reconnect it

Not done yet: 48 kHz and other sample rates, the box's MIDI and controls, and a lower-latency setting. 

Timecode vinyl has not been tested... anyone that does have access to it can you let me know if it works?

## What you need

- An Apple Silicon Mac (M1 or later)
- Apple's Command Line Tools. In Terminal, run `xcode-select --install` and follow the prompts.
- Homebrew from [brew.sh](https://brew.sh), then run `brew install libusb`

## Install

1. Plug in the Audio 4 DJ.
2. Download `install_a4dj.sh`.
3. Open Terminal and run it, for example: `bash ~/Downloads/install_a4dj.sh`
4. Enter your Mac password when asked. Your Mac's sound cuts out for a second while macOS restarts its audio service.

The installer builds the driver on your Mac, installs it, then runs a 10-second self-test. You should see "found the Audio 4 DJ device" and audio frames counted. If you have a cable looping an output back into an input, it also checks that audio for glitches. Without a cable, "the inputs are live but quiet" is normal.

Then choose "Audio 4 DJ" as the audio device in your DJ software.

## Uninstall

Run `bash ~/Downloads/uninstall_a4dj.sh`. It removes the driver, its background service and everything else the installer added.

## If something goes wrong

- **The device does not appear:** restart the Mac with the Audio 4 DJ plugged in, then check Audio MIDI Setup.
- **No sound:** check the helper's log with `tail -n 30 /var/log/a4dj-helper.log`. You should see "Audio 4 DJ found" and "clock settled". If nothing has been logged, unplug the box and plug it in again.
- **Re-run the self-test at any time:** `/usr/local/bin/a4dj-selftest 10`

If you report a problem, include your Mac model, your macOS version, and those two files: `/var/log/a4dj-helper.log` and `/tmp/a4dj_selftest.dat`. No promises, but it helps.

## How it works

There are three parts:

- **A background service** (`a4dj-helper`) owns the USB connection to the box. It streams audio both ways and keeps the box's clock.
- **A Core Audio driver** (`Audio4DJ.driver`) presents the box to macOS. It swaps audio with the service through shared memory.
- **A self-test** (`a4dj-selftest`) plays a tone and records the inputs to check the whole chain.

The source for all three is in `src/`. The installer contains the same files and builds them on your Mac.

## Credits and licence

The Audio 4 DJ's USB protocol was worked out from the Linux driver snd-usb-caiaq by Daniel Mack and contributors. Without it this would not exist.

Because of that, this project is released under the GNU General Public License, version 2 or later. You are free to use, share and change it. If you share a changed version, it must stay under the same licence with its source available.

