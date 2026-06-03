#!/usr/bin/env bash
# LFS book §4.4 — environment for the lfs build user (sourced by run-lfs-session.sh)
set +h
umask 022
LFS="${LFS:-/mnt/lfs}"
LC_ALL=POSIX
LFS_TGT="$(uname -m)-lfs-linux-gnu"
PATH=/usr/bin:/bin
if [[ ! -L /bin ]]; then PATH=/bin:$PATH; fi
PATH="$LFS/tools/bin:$PATH"
CONFIG_SITE="$LFS/usr/share/config.site"
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc 2>/dev/null || echo 1)}"
export TESTSUITEFLAGS="${TESTSUITEFLAGS:-$MAKEFLAGS}"
export LFS_SOURCES="${LFS_SOURCES:-$LFS/sources}"
