# Building PostgreSQL GDExtension

The extension is built for Linux only. It runs on the game server; game clients never connect
to the database and are exported without this addon.

## Prerequisites

- GCC or Clang (C++20), make, curl, git
- OpenSSL development headers (`libssl-dev`, `openssl-devel` or `openssl`)
- SCons (`pip install scons`)
- No PostgreSQL packages: libpq and libpqxx are built from source as static archives into
  `third_party/` by `build_scripts/build_third_party.sh` and linked into the `.so`. The `.so`
  links the system's OpenSSL 3 (`libssl.so.3`, `libcrypto.so.3`) for TLS connections.

## Quick Start

```bash
godot --headless --dump-extension-api   # ./extension_api.json for your engine build
./build_scripts/build_linux.sh          # builds third_party/ first if it's missing
```

**Output:**
- `addons/godot-postgresql/bin/lib_postgresql_adapter.linux.template_debug.double.x86_64.so`
- `addons/godot-postgresql/bin/lib_postgresql_adapter.linux.template_release.double.x86_64.so`

## Manual Building

### Step 1: Initialize Submodules
```bash
git submodule update --init --recursive
```

### Step 2: Generate dependencies
```bash
godot --headless --dump-extension-api   # extension_api.json for the engine you run
./build_scripts/build_third_party.sh    # static libpq/libpqxx in third_party/
```

The root SConstruct builds godot-cpp against `extension_api.json`; don't build inside
`godot-cpp/` directly (that would use godot-cpp's bundled API instead).

### Step 3: Build Extension
```bash
# Debug build
scons platform=linux target=template_debug arch=<arch>

# Release build
scons platform=linux target=template_release arch=<arch>
```

**Architecture Options:** `x86_64`, `arm64`

## Cross-Compilation

### Linux ARM64 (from x86_64)
```bash
# Install cross-compilation tools
sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

# Build with cross-compiler
scons platform=linux target=template_release arch=arm64 CXX=aarch64-linux-gnu-g++
```

The `third_party/` archives must be built for the same architecture.

## Troubleshooting

### PostgreSQL Not Found
- Run `build_scripts/build_third_party.sh`

### SCons Errors
- Ensure Python 3.x is installed
- Install SCons: `pip install scons`
- Check PATH includes Python scripts directory

### Linking Errors
- Rebuild `third_party/` with `build_scripts/build_third_party.sh`
- Ensure compatible architecture (x86_64 vs ARM64)

### Build Performance
- Use parallel building: `-j$(nproc)`
- Consider using ccache for faster rebuilds
- Clean build directory if experiencing issues: `scons -c`

## Binary Compatibility

- **Godot:** the engine build whose `extension_api.json` the extension was built against
  (4.7+, double precision by default; rebuild after engine updates).
- **PostgreSQL server:** tested against PostgreSQL 18.
- **libpqxx:** 8.x (C++20).
- Use release builds for distribution.
