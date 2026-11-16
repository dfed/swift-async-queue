#!/bin/bash
# Spike, not for merging: can an iOS 18 simulator runtime be installed on the
# xcode-27 runner, and can Xcode 27.2 run the tests on it?
set -x
XCODE27=/Applications/Xcode_27.2.app/Contents/Developer
IOS18_BUILD=22F77 # iOS 18.5, as main's CI downloads.

echo "::group::Installed Xcodes and runtimes"
ls -d /Applications/Xcode*.app
sw_vers
DEVELOPER_DIR=$XCODE27 xcrun simctl list runtimes
echo "::endgroup::"

have_ios18() { DEVELOPER_DIR=$XCODE27 xcrun simctl list runtimes | grep -q 'iOS 18\.'; }

echo "::group::Attempt 1: download with Xcode 27.2"
SECONDS=0
sudo DEVELOPER_DIR=$XCODE27 xcodebuild -runFirstLaunch
sudo DEVELOPER_DIR=$XCODE27 xcodebuild -downloadPlatform iOS -buildVersion $IOS18_BUILD
echo "Attempt 1 exit $? after ${SECONDS}s"
echo "::endgroup::"

if ! have_ios18; then
	for OLD in $(ls -d /Applications/Xcode_26*.app /Applications/Xcode_16*.app 2>/dev/null | sort -rV); do
		echo "::group::Attempt 2: download with $OLD"
		SECONDS=0
		sudo DEVELOPER_DIR=$OLD/Contents/Developer xcodebuild -runFirstLaunch
		sudo DEVELOPER_DIR=$OLD/Contents/Developer xcodebuild -downloadPlatform iOS -buildVersion $IOS18_BUILD
		echo "Attempt 2 with $OLD exit $? after ${SECONDS}s"
		echo "::endgroup::"
		if have_ios18; then break; fi
	done
fi

echo "::group::Runtimes Xcode 27.2 sees now"
DEVELOPER_DIR=$XCODE27 xcrun simctl list runtimes
DEVELOPER_DIR=$XCODE27 xcrun simctl list devicetypes | grep -i ipad
echo "::endgroup::"

have_ios18 || { echo "::error::No iOS 18 runtime could be installed."; exit 1; }

RUNTIME=$(DEVELOPER_DIR=$XCODE27 xcrun simctl list runtimes | grep 'iOS 18\.' | tail -1 | grep -o 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-18-[0-9-]*')
UDID=$(DEVELOPER_DIR=$XCODE27 xcrun simctl create "iPad iOS 18" "com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation" "$RUNTIME")
echo "Created $UDID on $RUNTIME"

echo "::group::Test with Xcode 27.2 on the iOS 18 simulator"
SECONDS=0
DEVELOPER_DIR=$XCODE27 xcodebuild -scheme swift-async-queue -sdk iphonesimulator \
	-derivedDataPath .build/derivedData/iOS18 -PBXBuildsContinueAfterErrors=0 \
	OTHER_SWIFT_FLAGS=-warnings-as-errors -destination "id=$UDID" build test
STATUS=$?
echo "Test exit $STATUS after ${SECONDS}s"
echo "::endgroup::"
exit $STATUS
