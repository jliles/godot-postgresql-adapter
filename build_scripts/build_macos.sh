#!/bin/bash

# Build script for macOS platforms
set -e
source "$(dirname "$0")/common.sh"

echo "Building PostgreSQL GDExtension for macOS..."

# Check for required dependencies
echo "Checking dependencies..."

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "Homebrew not found. Install from https://brew.sh"
    exit 1
fi

# Check for libpqxx
if ! brew list | grep -q libpqxx; then
    echo "libpqxx not found. Install with:"
    echo "   brew install libpqxx"
    exit 1
fi

# Check for SCons
if ! command -v scons &> /dev/null; then
    echo "SCons not found. Install with:"
    echo "   pip install scons"
    echo "   or: brew install scons"
    exit 1
fi

echo "Dependencies found"

if [ ! -f extension_api.json ]; then
    echo "extension_api.json missing. Generate it from the engine you run (in this directory):"
    echo "   godot --headless --dump-extension-api"
    exit 1
fi

# Build the extension. The root SConstruct builds godot-cpp itself against ./extension_api.json;
# building inside godot-cpp/ directly would generate bindings from godot-cpp's bundled API instead.
echo "Building PostgreSQL extension for macOS..."
scons platform=macos target=template_debug arch=universal $BUILD_FLAGS -j$(sysctl -n hw.ncpu)
scons platform=macos target=template_release arch=universal $BUILD_FLAGS -j$(sysctl -n hw.ncpu)

echo "macOS build completed!"
echo "Debug framework: addons/godot-postgresql/bin/lib_postgresql_adapter.macos.template_debug.framework/"
echo "Release framework: addons/godot-postgresql/bin/lib_postgresql_adapter.macos.template_release.framework/"