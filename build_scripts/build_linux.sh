#!/bin/bash

# Build script for Linux platforms
set -e
source "$(dirname "$0")/common.sh"

echo "Building PostgreSQL GDExtension for Linux..."

# Check for required dependencies
echo "Checking dependencies..."

# libpqxx and libpq are linked statically into the .so from third_party/ (not tracked in git),
# so no system libpqxx/libpq-dev is needed. Build them once with build_third_party.sh.
if [ ! -f third_party/libpqxx/lib/libpqxx.a ] || [ ! -f third_party/libpq/lib/libpq.a ]; then
    echo "Building the static libpq/libpqxx archives under third_party/..."
    ./build_scripts/build_third_party.sh
fi

if [ ! -f extension_api.json ]; then
    echo "extension_api.json missing. Generate it from the engine you run (in this directory):"
    echo "   godot --headless --dump-extension-api"
    exit 1
fi

# Check for SCons
if ! command -v scons &> /dev/null; then
    echo "SCons not found. Install with:"
    echo "   pip install scons"
    echo "   or your distribution's package manager"
    exit 1
fi

echo "Dependencies found"

# Build the extension. The root SConstruct builds godot-cpp itself against ./extension_api.json;
# building inside godot-cpp/ directly would generate bindings from godot-cpp's bundled API instead.
echo "Building PostgreSQL extension for Linux..."
scons platform=linux target=template_debug arch=x86_64 $BUILD_FLAGS -j$(nproc)
scons platform=linux target=template_release arch=x86_64 $BUILD_FLAGS -j$(nproc)

echo "Linux build completed!"
echo "Debug library: addons/godot-postgresql/bin/lib_postgresql_adapter.linux.template_debug.double.x86_64.so"
echo "Release library: addons/godot-postgresql/bin/lib_postgresql_adapter.linux.template_release.double.x86_64.so"