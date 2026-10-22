#!/usr/bin/env python
import os

# Build against the engine we actually run (a double-precision custom build), not the API
# bundled with godot-cpp. Regenerate extension_api.json after every engine update with:
#   godot --headless --dump-extension-api
# Any of these can still be overridden on the command line.
api_file = os.path.join(os.getcwd(), "extension_api.json")
if "custom_api_file" not in ARGUMENTS:
    if not os.path.exists(api_file):
        print("Missing {}. Generate it from your engine with:".format(api_file))
        print("   godot --headless --dump-extension-api")
        Exit(1)
    ARGUMENTS["custom_api_file"] = api_file
ARGUMENTS.setdefault("precision", "double")
ARGUMENTS.setdefault("disable_exceptions", "no")

env = SConscript("godot-cpp/SConstruct")

# Platform-specific PostgreSQL library configuration
def configure_postgresql_libs(env):
    platform = env["platform"]
    
    # PostgreSQL DLLs that need to be bundled with Windows builds
    postgresql_dlls = [
        "pqxx.dll",
        "libpq.dll",
        "libcrypto-3-x64.dll",
        "libssl-3-x64.dll"
    ]
    
    if platform == "macos":
        # macOS with Homebrew
        homebrew_prefix = "/opt/homebrew"
        if not os.path.exists(homebrew_prefix):
            # Intel Mac or custom Homebrew installation
            homebrew_prefix = "/usr/local"
        
        env.Append(CPPPATH=[
            os.path.join(homebrew_prefix, "opt", "libpqxx", "include"),
            os.path.join(homebrew_prefix, "opt", "libpq", "include")
        ])
        env.Append(LIBPATH=[
            os.path.join(homebrew_prefix, "opt", "libpqxx", "lib"),
            os.path.join(homebrew_prefix, "opt", "libpq", "lib")
        ])
        
    elif platform == "linux":
        # libpqxx, libpq and the C++ runtime are linked STATICALLY into this .so, so the built
        # plugin needs no libpqxx / libpq / libstdc++ at runtime, only glibc and the system's
        # OpenSSL (for TLS). The archives live under third_party/ (build_third_party.sh):
        #   libpqxx.a                       C++ client, throws the exceptions we catch
        #   libpq.a + libpgcommon_shlib.a + libpgport_shlib.a   libpq with OpenSSL, no gssapi/ldap
        # The _shlib pgcommon/pgport variants are PostgreSQL's archives for embedding into a
        # shared object: they export the public encoding symbols (pg_char_to_encoding, etc.)
        # that libpq.a and libpqxx both reference; the frontend-static variants expose only
        # *_private names and leave those references unresolved at load.
        # The four are wrapped in a linker group because libpq / pgcommon / pgport reference
        # each other. libstdc++/libgcc are linked statically below; with libpqxx also static,
        # its throw site and the catch site here resolve against ONE C++ runtime inside this
        # single object, so SQL errors surface as catchable exceptions instead of aborting.
        pqxx = os.path.join(os.getcwd(), "third_party", "libpqxx")
        pq = os.path.join(os.getcwd(), "third_party", "libpq")
        env.Append(CPPPATH=[os.path.join(pqxx, "include")])
        # libpqxx is wrapped in --whole-archive so every member is pulled in: its exception
        # and polymorphic-transaction typeinfo/vtables have vague linkage and the default
        # "pull only referenced members" rule drops the TUs that define them, leaving the .so
        # with undefined RTTI symbols at load. The libpq trio sits in a group for its mutual
        # references; it has no such RTTI need (C), so it is not whole-archived.
        env.Append(LINKFLAGS=[
            "-Wl,--whole-archive",
            os.path.join(pqxx, "lib", "libpqxx.a"),
            "-Wl,--no-whole-archive",
            "-Wl,--start-group",
            os.path.join(pq, "lib", "libpq.a"),
            os.path.join(pq, "lib", "libpgcommon_shlib.a"),
            os.path.join(pq, "lib", "libpgport_shlib.a"),
            "-Wl,--end-group",
        ])
        # Linked dynamically: OpenSSL for TLS connections (system libssl/libcrypto, so security
        # updates come with the OS), and glibc's support libraries.
        env.Append(LIBS=["ssl", "crypto", "pthread", "m"])
        return   # no dynamic libpqxx/libpq; skip the generic Unix LIBS append below

    elif platform == "windows":
        # Windows - use vcpkg installed libraries
        pg_path = os.environ.get("POSTGRESQL_PATH", "C:\\Program Files\\PostgreSQL\\16")
        vcpkg_root = os.environ.get("VCPKG_ROOT", "")
        
        print("PostgreSQL path: {}".format(pg_path))
        print("vcpkg root: {}".format(vcpkg_root))
        
        env.Append(CPPPATH=[
            os.path.join(pg_path, "include")
        ])
        env.Append(LIBPATH=[os.path.join(pg_path, "lib")])
        
        # Use vcpkg toolchain if available
        if vcpkg_root:
            env.Append(CPPPATH=[os.path.join(vcpkg_root, "installed", "x64-windows", "include")])
            env.Append(LIBPATH=[os.path.join(vcpkg_root, "installed", "x64-windows", "lib")])
        
        # Windows library names for libpqxx and libpq
        env.Append(LIBS=["pqxx", "libpq", "ws2_32", "advapi32"])
        
        # Copy PostgreSQL DLLs to output directory
        def copy_postgresql_dlls(target, source, env):
            import shutil
            
            target_dir = os.path.dirname(str(target[0]))
            print("Copying PostgreSQL DLLs to: {}".format(target_dir))
            
            # Search paths for DLLs
            dll_search_paths = []
            if vcpkg_root:
                dll_search_paths.append(os.path.join(vcpkg_root, "installed", "x64-windows", "bin"))
            dll_search_paths.extend([
                os.path.join(pg_path, "bin"),
                os.path.join(pg_path, "lib"),
            ])
            
            for dll_name in postgresql_dlls:
                dll_found = False
                for search_path in dll_search_paths:
                    dll_path = os.path.join(search_path, dll_name)
                    if os.path.exists(dll_path):
                        dst_path = os.path.join(target_dir, dll_name)
                        try:
                            shutil.copy2(dll_path, dst_path)
                            print("Copied {} to {}".format(dll_path, dst_path))
                            dll_found = True
                            break
                        except Exception as e:
                            print("Failed to copy {}: {}".format(dll_path, e))
                
                if not dll_found:
                    print("Warning: Could not find DLL: {} in search paths: {}".format(dll_name, dll_search_paths))
        
        # Register the DLL copy action
        env.AddPostAction("$TARGET", copy_postgresql_dlls)
        
        return  # Skip the common libs addition below
    
    # Common library names for Unix-like systems
    env.Append(LIBS=["pqxx", "pq"])

# Configure PostgreSQL libraries based on platform
configure_postgresql_libs(env)

env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")

# Enable C++ exceptions
# libpqxx 8.x requires C++20 (std::chrono::year_month_day, std::source_location).
# godot-cpp forces -std=c++17; append C++20 so the later flag wins.
if env["platform"] == "windows":
    # MSVC uses /EHsc for exception handling
    env.Append(CXXFLAGS=['/EHsc', '/std:c++20'])
else:
    # GCC/Clang use -fexceptions
    env.Append(CXXFLAGS=['-fexceptions', '-std=c++20'])

# Statically link the C++ runtime (godot-cpp adds these by default). libpqxx is linked
# statically too (linux branch above), so its exception throw site and the catch site in this
# plugin share the one static libstdc++ inside this single .so, and a query error surfaces as
# a catchable exception. Both must be static together: a static libstdc++ here paired with a
# dynamic libpqxx gives two unwinders and std::terminate on any SQL error.
if env["platform"] == "linux":
    present = [str(f) for f in env["LINKFLAGS"]]
    for flag in ("-static-libstdc++", "-static-libgcc"):
        if flag not in present:
            env.Append(LINKFLAGS=[flag])

if env["platform"] == "macos":
    # Create framework structure for macOS
    library = env.SharedLibrary(
        "addons/godot-postgresql/bin/lib_postgresql_adapter.{}.{}.framework/lib_postgresql_adapter.{}.{}".format(
            env["platform"], env["target"], env["platform"], env["target"]
        ),
        source=sources,
    )
elif env["platform"] == "ios":
    if env["ios_simulator"]:
        library = env.StaticLibrary(
            "addons/godot-postgresql/bin/lib_postgresql_adapter.{}.{}.simulator.a".format(env["platform"], env["target"]),
            source=sources,
        )
    else:
        library = env.StaticLibrary(
            "addons/godot-postgresql/bin/lib_postgresql_adapter.{}.{}.a".format(env["platform"], env["target"]),
            source=sources,
        )
else:
    library = env.SharedLibrary(
        "addons/godot-postgresql/bin/lib_postgresql_adapter{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
        source=sources,
    )

Default(library)
