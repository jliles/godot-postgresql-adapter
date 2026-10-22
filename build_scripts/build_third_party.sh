#!/usr/bin/env bash
# Builds the static, PIC libpq and libpqxx archives the Linux build links into the .so, and
# installs them (with headers and licenses) under third_party/. third_party/ is not tracked in
# git: run this once after cloning, and again after changing the versions below.
#
#   build_scripts/build_third_party.sh            # writes ./third_party
#   THIRD_PARTY_DIR=/some/dir build_scripts/build_third_party.sh
#
# Needs curl, tar (bzip2), git, make, a C/C++20 toolchain and the OpenSSL development headers
# (libssl-dev / openssl-devel / openssl). libpq uses the system's OpenSSL for TLS connections.
set -euo pipefail

PG_VERSION=18.4
PQXX_VERSION=8.0.1

root=$(cd "$(dirname "$0")/.." && pwd)
out=${THIRD_PARTY_DIR:-$root/third_party}
jobs=$(nproc)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Building libpq $PG_VERSION..."
curl -fsSL "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2" \
    | tar -xj -C "$work"
pg_src=$work/postgresql-$PG_VERSION
pg_prefix=$work/pg
# TLS through the system's OpenSSL (linked dynamically by the extension); no GSSAPI/LDAP.
(cd "$pg_src" && ./configure --prefix="$pg_prefix" --with-openssl --without-gssapi \
    --without-ldap --without-readline --without-zlib --without-icu --without-zstd --without-lz4 \
    --without-libxml --without-systemd --without-selinux --without-pam --without-bonjour \
    CFLAGS="-fPIC -O2" >/dev/null)
make -s -C "$pg_src/src/include" install >/dev/null
make -s -C "$pg_src/src/common" -j"$jobs" >/dev/null
make -s -C "$pg_src/src/port" -j"$jobs" >/dev/null
make -s -C "$pg_src/src/interfaces/libpq" -j"$jobs" install >/dev/null

echo "Building libpqxx $PQXX_VERSION..."
git clone -q --depth 1 --branch "$PQXX_VERSION" https://github.com/jtv/libpqxx.git "$work/libpqxx" 2>/dev/null
pqxx_prefix=$work/pqxx
(cd "$work/libpqxx" && ./configure --prefix="$pqxx_prefix" --disable-shared --enable-static \
    --with-pic --disable-documentation \
    --with-postgres-include="$pg_prefix/include" --with-postgres-lib="$pg_prefix/lib" \
    CXXFLAGS="-std=c++20 -fPIC -O2" >/dev/null)
make -s -C "$work/libpqxx" -j"$jobs" install >/dev/null

echo "Installing into $out..."
rm -rf "$out/libpq" "$out/libpqxx"
mkdir -p "$out/libpq/lib" "$out/libpqxx/lib" "$out/libpqxx/include"
# The _shlib pgcommon/pgport variants are PostgreSQL's archives for embedding into a shared
# object: they export the public encoding symbols libpq.a and libpqxx reference.
cp "$pg_src/src/interfaces/libpq/libpq.a" "$pg_src/src/common/libpgcommon_shlib.a" \
    "$pg_src/src/port/libpgport_shlib.a" "$out/libpq/lib/"
cp "$pg_src/COPYRIGHT" "$out/libpq/"
cp "$pqxx_prefix/lib/libpqxx.a" "$out/libpqxx/lib/"
cp -r "$pqxx_prefix/include/pqxx" "$out/libpqxx/include/"
cp "$work/libpqxx/COPYING" "$work/libpqxx/AUTHORS" "$out/libpqxx/"

cat >"$out/libpq/PROVENANCE.txt" <<EOF
libpq (PostgreSQL $PG_VERSION client library), built static + PIC by
build_scripts/build_third_party.sh from
https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2
Archives: libpq.a + libpgcommon_shlib.a + libpgport_shlib.a, linked together in a group.
Built --with-openssl: TLS via the system's libssl/libcrypto (linked dynamically). No GSSAPI/LDAP.
EOF
cat >"$out/libpqxx/PROVENANCE.txt" <<EOF
libpqxx $PQXX_VERSION, built static + PIC (-std=c++20) by build_scripts/build_third_party.sh
from https://github.com/jtv/libpqxx (tag $PQXX_VERSION).
EOF
echo "Done."
