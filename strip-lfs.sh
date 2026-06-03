#!/usr/bin/env bash
# Book §8.85 stripping — run from the host in a fresh chroot, not inside the chroot session.
# Stripping live in-session binaries (bash, strip, libc) risks bricking the build tree.
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "$0: run as root (sudo $0)" >&2
    exit 1
  fi
}

require_root

if [[ ! -d "$LFS/usr" ]]; then
  echo "LFS system tree not found at $LFS" >&2
  exit 1
fi

if ! mountpoint -q "$LFS/proc" 2>/dev/null; then
  echo "Virtual kernel filesystems must be mounted on $LFS (run build or mount-kernfs.sh)" >&2
  exit 1
fi

echo "=== Stripping debug symbols under $LFS (book §8.85) ==="

chroot "$LFS" /usr/bin/env -i \
  HOME=/root \
  PATH=/usr/bin:/usr/sbin \
  /bin/bash --noprofile --norc <<'EOF'
set -e
save_usrlib="$(cd /usr/lib; ls ld-linux*[^g])
             libc.so.6
             libthread_db.so.1
             libquadmath.so.0.0.0
             libstdc++.so.6.0.34
             libitm.so.1.0.0
             libatomic.so.1.2.0"

cd /usr/lib

for LIB in $save_usrlib; do
    objcopy --only-keep-debug --compress-debug-sections=zstd $LIB $LIB.dbg
    cp $LIB /tmp/$LIB
    strip --strip-debug /tmp/$LIB
    objcopy --add-gnu-debuglink=$LIB.dbg /tmp/$LIB
    install -vm755 /tmp/$LIB /usr/lib
    rm /tmp/$LIB
done

online_usrbin="bash find strip"
online_usrlib="libbfd-2.46.0.20260210.so
               libsframe.so.3.0.0
               libhistory.so.8.3
               libncursesw.so.6.6
               libm.so.6
               libreadline.so.8.3
               libz.so.1.3.2
               libzstd.so.1.5.7
               $(cd /usr/lib; find libnss*.so* -type f)"

for BIN in $online_usrbin; do
    cp /usr/bin/$BIN /tmp/$BIN
    strip --strip-debug /tmp/$BIN
    install -vm755 /tmp/$BIN /usr/bin
    rm /tmp/$BIN
done

for LIB in $online_usrlib; do
    cp /usr/lib/$LIB /tmp/$LIB
    strip --strip-debug /tmp/$LIB
    install -vm755 /tmp/$LIB /usr/lib
    rm /tmp/$LIB
done

for i in $(find /usr/lib -type f -name \*.so* ! -name \*dbg) \
         $(find /usr/lib -type f -name \*.a)                 \
         $(find /usr/{bin,sbin,libexec} -type f); do
    case "$online_usrbin $online_usrlib $save_usrlib" in
        *$(basename $i)* )
            ;;
        * ) strip --strip-debug $i
            ;;
    esac
done

unset BIN LIB save_usrlib online_usrbin online_usrlib
EOF

echo "Stripping complete."
