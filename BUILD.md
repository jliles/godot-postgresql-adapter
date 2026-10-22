# Building PostgreSQL GDExtension

This document provides comprehensive instructions for building the PostgreSQL GDExtension for all supported platforms.

## Quick Start

### Automated Building
```bash
# Build for current platform automatically
./build_scripts/build_all.sh

# Or use platform-specific scripts
./build_scripts/build_macos.sh     # macOS
./build_scripts/build_linux.sh    # Linux  
./build_scripts/build_windows.bat # Windows
```

## Platform-Specific Instructions

### macOS

**Prerequisites:**
- Xcode Command Line Tools
- Homebrew
- PostgreSQL libraries

**Setup:**
```bash
# Install Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install dependencies
brew install libpqxx postgresql
pip install scons
```

**Build:**
```bash
./build_scripts/build_macos.sh
```

**Output:**
- `addons/godot-postgresql/bin/lib_postgresql_adapter.macos.template_debug.framework/`
- `addons/godot-postgresql/bin/lib_postgresql_adapter.macos.template_release.framework/`

### Linux

**Prerequisites:**
- GCC or Clang (C++20), make, curl, git
- OpenSSL development headers (`libssl-dev`, `openssl-devel` or `openssl`)
- SCons (`pip install scons`)
- No PostgreSQL packages: libpq and libpqxx are built from source as static archives into
  `third_party/` by `build_scripts/build_third_party.sh` and linked into the `.so`. The `.so`
  links the system's OpenSSL 3 (`libssl.so.3`, `libcrypto.so.3`) for TLS connections.

**Build:**
```bash
godot --headless --dump-extension-api   # ./extension_api.json for your engine build
./build_scripts/build_linux.sh          # builds third_party/ first if it's missing
```

**Output:**
- `addons/godot-postgresql/bin/lib_postgresql_adapter.linux.template_debug.double.x86_64.so`
- `addons/godot-postgresql/bin/lib_postgresql_adapter.linux.template_release.double.x86_64.so`

### Windows

**Prerequisites:**
- Visual Studio 2019/2022 or Build Tools
- PostgreSQL for Windows
- Python 3.x

**Setup:**
1. Install Visual Studio with C++ development tools
2. Download and install PostgreSQL from https://www.postgresql.org/download/windows/
3. Install Python and SCons:
   ```cmd
   pip install scons
   ```

**Build:**
```cmd
# Run from Visual Studio Developer Command Prompt
build_scripts\build_windows.bat
```

**Output:**
- `addons/godot-postgresql/bin/lib_postgresql_adapter.windows.template_debug.x86_64.dll`
- `addons/godot-postgresql/bin/lib_postgresql_adapter.windows.template_release.x86_64.dll`

## Manual Building

### Step 1: Initialize Submodules
```bash
git submodule update --init --recursive
```

### Step 2: Generate dependencies
```bash
godot --headless --dump-extension-api   # extension_api.json for the engine you run
./build_scripts/build_third_party.sh    # Linux only: static libpq/libpqxx in third_party/
```

The root SConstruct builds godot-cpp against `extension_api.json`; don't build inside
`godot-cpp/` directly (that would use godot-cpp's bundled API instead).

### Step 3: Build Extension
```bash
# Debug build
scons platform=<platform> target=template_debug arch=<arch>

# Release build
scons platform=<platform> target=template_release arch=<arch>
```

**Platform/Architecture Options:**
- `platform`: `macos`, `linux`, `windows`
- `arch`: `x86_64`, `arm64`, `universal` (macOS only)

## Cross-Compilation

### Linux ARM64 (from x86_64)
```bash
# Install cross-compilation tools
sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

# Build with cross-compiler
scons platform=linux target=template_release arch=arm64 CXX=aarch64-linux-gnu-g++
```

### macOS Universal Binaries
```bash
# Builds both Intel and Apple Silicon binaries
scons platform=macos target=template_release arch=universal
```

## Troubleshooting

### PostgreSQL Not Found
- **macOS:** `brew install libpqxx`
- **Linux:** Run `build_scripts/build_third_party.sh`
- **Windows:** Set `POSTGRESQL_PATH` environment variable

### SCons Errors
- Ensure Python 3.x is installed
- Install SCons: `pip install scons`
- Check PATH includes Python scripts directory

### Linking Errors
- Verify PostgreSQL libraries are installed
- Check library paths in SConstruct
- Ensure compatible architecture (x86_64 vs ARM64)

### Build Performance
- Use parallel building: `-j$(nproc)` (Linux), `-j$(sysctl -n hw.ncpu)` (macOS)
- Consider using ccache for faster rebuilds
- Clean build directory if experiencing issues: `scons -c`

## Build Configuration

The build system automatically detects platform-specific library paths:

- **macOS:** Homebrew paths (`/opt/homebrew` or `/usr/local`)
- **Linux:** static archives under `third_party/`
- **Windows:** Environment variable or standard installation paths

For custom PostgreSQL installations, modify the SConstruct file or set environment variables:
- `POSTGRESQL_PATH` (Windows)

## Binary Compatibility

- **Godot:** the engine build whose `extension_api.json` the extension was built against
  (4.7+, double precision by default; rebuild after engine updates).
- **PostgreSQL server:** tested against PostgreSQL 18.
- **libpqxx:** 8.x (C++20).
- Use release builds for distribution.
