#!/bin/zsh
# Installs the iOS 18.5 simulator runtime from the disk image that
# Scripts/copy-ios-18-simulator.sh copied, and creates the iPad that
# Scripts/build.swift's iOS18 platform tests on. Run it on the `xcode-27`
# runner with Xcode 27.2 selected.
#
# Usage: install-ios-18-simulator.sh image

set -euo pipefail

image=$1
if [[ ! -f $image ]]; then
	echo "::error::The iOS 18.5 simulator image $image doesn't exist."
	exit 1
fi
uuid_pattern='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'

echo "::group::Free disk space"
# The runner's simulator runtimes take up so much of its disk that
# adding the 9 GB iOS 18.5 image fails with "Cannot copy the image
# because the disk is almost full". Delete every runtime except the 27.2
# runtime of each platform, and also the second iOS 27.2 runtime, build
# 24B91016s, which is for iPhone only. A runtime that can't be deleted
# only frees less space; adding the image below fails if it isn't
# enough.
df -h /
runtimes=$(xcrun simctl runtime list)
print -r -- "$runtimes"
unused_runtimes=(${(f)"$(
	{
		grep -v ' 27\.2 (' <<<"$runtimes"
		grep '24B91016s' <<<"$runtimes"
	} | grep -oE $uuid_pattern || true
)"})
for runtime in $unused_runtimes; do
	sudo xcrun simctl runtime delete $runtime || true
done
# `simctl runtime delete` returns while the runtime is still being
# deleted, and its space is free only once it is gone.
for attempt in {1..60}; do
	if [[ $(xcrun simctl runtime list) != *Deleting* ]]; then
		break
	fi
	sleep 5
done
if [[ $(xcrun simctl runtime list) == *Deleting* ]]; then
	echo "::warning::Some simulator runtimes are still being deleted after 5 minutes, so adding the iOS 18.5 image may run out of disk space."
fi
xcrun simctl runtime list
df -h /
echo "::endgroup::"

echo "::group::Add the iOS 18.5 runtime"
sudo xcodebuild -runFirstLaunch
# If `xcodebuild -importPlatform` doesn't add the runtime, add it with
# simctl instead.
sudo xcodebuild -importPlatform $image || true
if [[ $(xcrun simctl list runtimes) != *'iOS 18.'* ]]; then
	if ! sudo xcrun simctl runtime add $image; then
		echo "::endgroup::"
		echo "::error::Neither xcodebuild -importPlatform nor simctl runtime add could add $image."
		exit 1
	fi
fi
# Build the runtime's dyld shared cache now rather than during the
# simulator's first boot.
sudo xcrun simctl runtime dyld_shared_cache update --all || true
xcrun simctl list runtimes
echo "::endgroup::"

runtime=$(xcrun simctl list runtimes | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-18-[0-9-]+' | tail -1 || true)
if [[ -z $runtime ]]; then
	echo "::error::Xcode does not list an iOS 18 simulator runtime after adding $image."
	exit 1
fi
# Scripts/build.swift finds the iPad by its name and iOS version.
if [[ $(xcrun simctl list devices 'iOS 18.5') != *'iPad (10th generation) ('* ]]; then
	xcrun simctl create 'iPad (10th generation)' com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation $runtime
fi
xcrun simctl list devices 'iOS 18.5'
