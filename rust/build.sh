#!/bin/bash

# Build script for the Spotifly Rust library
# This script builds the Rust library for macOS, iOS, and iOS Simulator (arm64 only)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$SCRIPT_DIR/../build/rust"

# Add cargo to PATH - check rustup first, then Homebrew
if [ -f "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
elif [ -f "/opt/homebrew/bin/cargo" ]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

# Determine what platforms to build for based on PLATFORM_NAME environment variable (set by Xcode)
# If not set, build for current platform (macOS)
PLATFORM_NAME="${PLATFORM_NAME:-macosx}"
SDK_NAME="${SDK_NAME:-$PLATFORM_NAME}"

# Determine build configuration from Xcode's CONFIGURATION variable
# Default to Release if not set (e.g., when running build.sh manually)
CONFIGURATION="${CONFIGURATION:-Release}"

if [ "$CONFIGURATION" = "Debug" ]; then
    CARGO_FLAGS=""
    BUILD_TYPE="debug"
    echo "Building Spotifly Rust library (DEBUG) for platform: $PLATFORM_NAME"
else
    CARGO_FLAGS="--release"
    BUILD_TYPE="release"
    echo "Building Spotifly Rust library (RELEASE) for platform: $PLATFORM_NAME"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR/lib"
mkdir -p "$OUTPUT_DIR/include"

cd "$RUST_DIR"

# Build for the appropriate target based on platform
case "$PLATFORM_NAME" in
    macosx*)
        echo "Building for macOS (aarch64)..."
        cargo build $CARGO_FLAGS --target aarch64-apple-darwin
        cp "$RUST_DIR/target/aarch64-apple-darwin/$BUILD_TYPE/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
    iphoneos*)
        echo "Building for iOS device (aarch64)..."
        cargo build $CARGO_FLAGS --target aarch64-apple-ios
        cp "$RUST_DIR/target/aarch64-apple-ios/$BUILD_TYPE/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
    iphonesimulator*)
        echo "Building for iOS Simulator (aarch64)..."
        cargo build $CARGO_FLAGS --target aarch64-apple-ios-sim
        cp "$RUST_DIR/target/aarch64-apple-ios-sim/$BUILD_TYPE/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
    *)
        echo "Unknown platform: $PLATFORM_NAME, defaulting to macOS"
        cargo build $CARGO_FLAGS --target aarch64-apple-darwin
        cp "$RUST_DIR/target/aarch64-apple-darwin/$BUILD_TYPE/libspotifly_rust.a" "$OUTPUT_DIR/lib/"
        ;;
esac

# Copy the header file and modulemap
cp "$RUST_DIR/include/spotifly_rust.h" "$OUTPUT_DIR/include/"
cp "$RUST_DIR/include/module.modulemap" "$OUTPUT_DIR/include/"

echo "Build complete!"
echo "Static library: $OUTPUT_DIR/lib/libspotifly_rust.a"
echo "Header: $OUTPUT_DIR/include/spotifly_rust.h"
