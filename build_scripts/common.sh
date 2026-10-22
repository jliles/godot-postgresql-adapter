# Shared SCons flags for every build script.
#   precision=double      — match the double-precision engine ABI (godot.double).
#   disable_exceptions=no — keep C++ exceptions on so libpqxx query errors are catchable
#                           instead of aborting the process.
BUILD_FLAGS="precision=double disable_exceptions=no"
