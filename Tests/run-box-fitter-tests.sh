#!/bin/bash
# Compile ObjectBoxFitter with its tests for macOS and run them.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
mkdir -p build
xcrun swiftc -O ObjectScan/ObjectBoxFitter.swift Tests/main.swift -o build/box-fitter-tests
./build/box-fitter-tests
