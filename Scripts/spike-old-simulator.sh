#!/bin/bash
# Spike, not for merging: can Xcode 27.2 run the tests on an iOS 18.5
# simulator runtime that Xcode 26.1.1 exported on another runner?
set -x
export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
ls -la runtime

echo "::group::Add the runtime"
find runtime -maxdepth 2 -print
sudo xcodebuild -runFirstLaunch
SECONDS=0
for image in runtime/*; do
	sudo xcodebuild -importPlatform "$image"
	echo "xcodebuild -importPlatform $image exit $? after ${SECONDS}s"
	if ! xcrun simctl list runtimes | grep -q 'iOS 18\.'; then
		SECONDS=0
		sudo xcrun simctl runtime add "$image"
		echo "simctl runtime add $image exit $? after ${SECONDS}s"
	fi
done
xcrun simctl runtime list
xcrun simctl list runtimes
echo "::endgroup::"

echo "::group::Prebuild the dyld shared cache"
SECONDS=0
sudo xcrun simctl runtime dyld_shared_cache update --all
echo "dyld_shared_cache update exit $? after ${SECONDS}s"
echo "::endgroup::"

RUNTIME=$(xcrun simctl list runtimes | grep 'iOS 18\.' | tail -1 | grep -o 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-18-[0-9-]*')
if [ -z "$RUNTIME" ]; then
	echo "::error::Xcode 27.2 does not list an iOS 18 runtime after adding the image."
	exit 1
fi
UDID=$(xcrun simctl create "iPad iOS 18" "com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation" "$RUNTIME")
echo "Created $UDID on $RUNTIME"

echo "::group::Test with Xcode 27.2 on the iOS 18 simulator"
SECONDS=0
xcodebuild -scheme swift-async-queue -sdk iphonesimulator \
	-derivedDataPath .build/derivedData/iOS18 -PBXBuildsContinueAfterErrors=0 \
	OTHER_SWIFT_FLAGS=-warnings-as-errors -destination "id=$UDID" build test
STATUS=$?
echo "Test exit $STATUS after ${SECONDS}s"
echo "::endgroup::"
exit $STATUS
