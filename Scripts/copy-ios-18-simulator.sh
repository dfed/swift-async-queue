#!/bin/zsh
# Copies the disk image of the iOS 18.5 simulator runtime from the
# `macos-15` runner, which has it installed, into the given directory, so
# that a job on the `xcode-27` runner can install it with
# Scripts/install-ios-18-simulator.sh.
#
# Xcode 27 can't download the runtime itself:
# `xcodebuild -downloadPlatform iOS -buildVersion 22F77` fails with
# "iOS 22F77 is not available for download". Xcode 26 on `macos-15` can
# export the installed runtime with
# `xcodebuild -downloadPlatform iOS -buildVersion 22F77 -exportPath`, but
# that fails at random with "Unable to connect to simulator.", so this
# script copies the disk image that is already on the runner instead.
#
# Usage: copy-ios-18-simulator.sh directory

set -euo pipefail

# The build of iOS 18.5. Scripts/build.swift tests on iOS 18.5.
build=22F77
directory=$1

runtimes=$(xcrun simctl runtime list -j)
# simctl lists each runtime's disk image under "path".
image=$(print -r -- "$runtimes" | python3 -c '
import json, sys
build = sys.argv[1]
runtimes = json.load(sys.stdin).values()
print(next((runtime["path"] for runtime in runtimes if runtime.get("build") == build and runtime.get("path")), ""))
' $build)

if [[ -z $image ]]; then
	print -r -- "$runtimes"
	echo "::error::The runner has no disk image of the iOS $build simulator runtime."
	exit 1
fi

mkdir -p $directory
cp $image $directory/iphonesimulator_18.5_$build.dmg
ls -la $directory
