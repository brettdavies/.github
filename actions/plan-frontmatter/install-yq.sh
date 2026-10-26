#!/usr/bin/env bash
# Prints the path of a mikefarah yq v4 binary: the yq on PATH when it is one,
# otherwise a pinned release downloaded into DIR and checked against its
# sha256. Diagnostics go to stderr, so stdout carries only the path.
#
# GitHub-hosted Ubuntu and macOS images ship mikefarah yq v4; the download
# covers a self-hosted runner without it, or one whose yq is the Python
# wrapper of the same name, which reads different flags.
#
# Usage: install-yq.sh DIR
set -euo pipefail

dest=${1:?usage: install-yq.sh DIR}

if command -v yq >/dev/null 2>&1 \
  && yq --version 2>&1 | grep -Eq 'mikefarah/yq.* version v?4\.'; then
  command -v yq
  exit 0
fi

version=v4.54.1
platform="$(uname -s)-$(uname -m)"
case "$platform" in
  Linux-x86_64)
    asset=yq_linux_amd64
    sha256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
    ;;
  Linux-aarch64 | Linux-arm64)
    asset=yq_linux_arm64
    sha256=189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b
    ;;
  Darwin-x86_64)
    asset=yq_darwin_amd64
    sha256=3a812fce205a4d67014fb71b7fa297092210e580df3d8f52dddc2cf3a599c22b
    ;;
  Darwin-arm64)
    asset=yq_darwin_arm64
    sha256=fee511a181bd8b3e6b7da98842b41973bfac8cd3bcd341ed29a584620b5b2844
    ;;
  *)
    echo "::error title=plan frontmatter::no pinned yq build for ${platform}; install mikefarah yq v4 on the runner" >&2
    exit 1
    ;;
esac

echo "yq on PATH is missing or is not mikefarah v4; downloading yq ${version} (${asset})" >&2
mkdir -p "$dest"
curl -fsSL --retry 3 -o "$dest/yq.download" \
  "https://github.com/mikefarah/yq/releases/download/${version}/${asset}"

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$dest/yq.download" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$dest/yq.download" | cut -d' ' -f1)
fi
if [ "$actual" != "$sha256" ]; then
  echo "::error title=plan frontmatter::${asset} ${version} has sha256 ${actual}, expected ${sha256}; the download is not the pinned release" >&2
  exit 1
fi

chmod +x "$dest/yq.download"
mv "$dest/yq.download" "$dest/yq"
echo "$dest/yq"
