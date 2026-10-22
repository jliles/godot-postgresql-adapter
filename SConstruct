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

# The extension only runs on the (Linux) game server; clients never connect to the database
# and are exported without this addon.
if env["platform"] != "linux":
    print("Only platform=linux is supported (got platform={}).".format(env["platform"]))
    Exit(1)

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

env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")

# Enable C++ exceptions
# libpqxx 8.x requires C++20 (std::chrono::year_month_day, std::source_location).
# godot-cpp forces -std=c++17; append C++20 so the later flag wins.
env.Append(CXXFLAGS=['-fexceptions', '-std=c++20'])

# Statically link the C++ runtime (godot-cpp adds these by default). libpqxx is linked
# statically too (above), so its exception throw site and the catch site in this plugin
# share the one static libstdc++ inside this single .so, and a query error surfaces as
# a catchable exception. Both must be static together: a static libstdc++ here paired with a
# dynamic libpqxx gives two unwinders and std::terminate on any SQL error.
present = [str(f) for f in env["LINKFLAGS"]]
for flag in ("-static-libstdc++", "-static-libgcc"):
    if flag not in present:
        env.Append(LINKFLAGS=[flag])

library = env.SharedLibrary(
    "addons/godot-postgresql/bin/lib_postgresql_adapter{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

Default(library)
