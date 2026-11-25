#!/bin/bash
set -euo pipefail
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
clang -dynamiclib \
  -fobjc-arc \
  -target arm64-apple-ios15.0 \
  -miphoneos-version-min=15.0 \
  -isysroot "$SDK" \
  -O2 \
  -fPIC \
  -framework Foundation \
  -framework UIKit \
  -framework WebKit \
  -Wl,-install_name,@executable_path/Frameworks/HOControl.dylib \
  -o HOControl.dylib \
  HOControl.m
