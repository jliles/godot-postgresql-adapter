# PostgreSQL DLL Dependency Bundling Solution

This document describes the implemented solution for bundling PostgreSQL DLL dependencies with your Godot 4 PostgreSQL GDExtension.

## Problem Summary

The extension depends on these PostgreSQL-related DLLs that must be distributed alongside the extension:
- `pqxx.dll` - libpqxx library for C++ PostgreSQL connectivity
- `libpq.dll` - PostgreSQL client library
- `libcrypto-3-x64.dll` - OpenSSL cryptography library
- `libssl-3-x64.dll` - OpenSSL SSL/TLS library

## Solution Overview

The implemented solution automatically handles DLL bundling through multiple mechanisms:

### 1. Build System Integration (SConstruct)

**File:** [`SConstruct`](SConstruct)

The build system now automatically copies PostgreSQL DLLs during Windows builds:

- **Automatic DLL Detection**: Searches for required DLLs in vcpkg and PostgreSQL installation directories
- **Post-Build Copy Action**: Uses SCons `AddPostAction` to copy DLLs after successful compilation
- **Search Paths**: 
  - `%VCPKG_ROOT%/installed/x64-windows/bin` (if vcpkg is used)
  - `%POSTGRESQL_PATH%/bin`
  - `%POSTGRESQL_PATH%/lib`

### 2. GDExtension Configuration

**File:** [`addons/godot-postgresql/godot-postgresql.gdextension`](addons/godot-postgresql/godot-postgresql.gdextension)

Updated the dependencies section to inform Godot about required DLLs:

```ini
[dependencies]
windows.debug.x86_64 = {
    "bin/pqxx.dll" : "",
    "bin/libpq.dll" : "",
    "bin/libcrypto-3-x64.dll" : "",
    "bin/libssl-3-x64.dll" : ""
}
windows.release.x86_64 = {
    "bin/pqxx.dll" : "",
    "bin/libpq.dll" : "",
    "bin/libcrypto-3-x64.dll" : "",
    "bin/libssl-3-x64.dll" : ""
}
```

### 3. Manual DLL Management Script

**File:** [`build_scripts/copy_postgres_dlls.bat`](build_scripts/copy_postgres_dlls.bat)

A standalone script for manual DLL copying:

```bat
# Usage
.\build_scripts\copy_postgres_dlls.bat

# Or with custom paths
set POSTGRESQL_PATH=C:\path\to\postgresql
set VCPKG_ROOT=C:\path\to\vcpkg
.\build_scripts\copy_postgres_dlls.bat
```

**Features:**
- Automatically detects PostgreSQL installation
- Supports vcpkg installations
- Creates output directories if needed
- Provides detailed feedback on copy operations
- Copies the DLLs into the output directory (`addons/godot-postgresql/bin`)

## Usage Instructions

### For Local Development

1. **Automatic (Recommended)**: The build system handles DLL copying automatically
   ```bat
   scons platform=windows target=template_release arch=x86_64
   ```

2. **Manual**: Use the helper script if needed
   ```bat
   .\build_scripts\copy_postgres_dlls.bat
   ```

### For CI/CD

The GitHub Actions workflow automatically handles DLL bundling. No additional configuration required.

### For Distribution

When distributing your extension:

1. **Include the entire `bin/` directory** containing:
   - Your extension DLL (`lib_postgresql_adapter.windows.*.dll`)
   - All PostgreSQL dependency DLLs
   
2. **Ensure the `.gdextension` file** is properly configured (already done)

3. **Users install by copying** the complete structure to their Godot project

## Directory Structure

After building, your directory structure should look like:

```
Demo/
├── godot-postgresql.gdextension
└── bin/
    └── PostgresqlAdapter/
        ├── lib_postgresql_adapter.windows.template_debug.x86_64.dll
        ├── lib_postgresql_adapter.windows.template_release.x86_64.dll
        ├── pqxx.dll
        ├── libpq.dll
        ├── libcrypto-3-x64.dll
        └── libssl-3-x64.dll
```

## Troubleshooting

### Common Issues

1. **DLLs Not Found During Build**
   - Ensure `POSTGRESQL_PATH` environment variable is set
   - Verify vcpkg installation if using vcpkg
   - Check that PostgreSQL binaries are in PATH

2. **Runtime DLL Errors**
   - Verify all DLLs are in the same directory as your extension DLL
   - Check that DLL architecture matches (x64)
   - Ensure DLL versions are compatible

3. **CI Build Failures**
   - Check GitHub Actions logs for DLL copy step
   - Verify vcpkg installation succeeded
   - Ensure all required DLLs were found

### Environment Variables

- `POSTGRESQL_PATH`: Path to PostgreSQL installation (e.g., `C:\Program Files\PostgreSQL\16`)
- `VCPKG_ROOT`: Path to vcpkg installation (optional)

## Static Linking Alternative

If you prefer static linking instead of DLL bundling, you would need to:

1. Build libpqxx and libpq as static libraries
2. Modify SConstruct to link statically
3. Handle OpenSSL static linking (more complex)

**Note**: Static linking is more complex due to OpenSSL dependencies and license considerations. The current DLL bundling approach is recommended for most use cases.

## Verification

To verify the solution works:

1. Build the project
2. Check that all DLLs are present in `addons/godot-postgresql/bin/`
3. Test the extension in Godot
4. Verify no missing DLL errors occur

## Files Modified

- [`SConstruct`](SConstruct) - Added DLL copying functionality
- [`addons/godot-postgresql/godot-postgresql.gdextension`](addons/godot-postgresql/godot-postgresql.gdextension) - Added dependency declarations
- [`.github/workflows/build.yml`](.github/workflows/build.yml) - Enhanced CI/CD pipeline
- [`build_scripts/copy_postgres_dlls.bat`](build_scripts/copy_postgres_dlls.bat) - New helper script

This solution ensures that your PostgreSQL GDExtension can be easily distributed with all necessary dependencies bundled together.