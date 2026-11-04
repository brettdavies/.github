#!/usr/bin/env bash
# Installs upstream rhysd/actionlint and the shellcheck it runs into DIR. Each
# archive is checked against a SHA-256 before it is unpacked: pinned below, or
# for an actionlint release this table does not know, one the caller supplies.
# A release with neither fails before any download.
#
# The checksum never comes from the release being downloaded: a checksums file
# published beside an archive changes with it.
#
# The shellcheck release is pinned because actionlint runs whichever one it is
# given and its findings follow that version. Hosted runner images range from
# 0.8.0 to 0.11.0.
#
# Usage: ACTIONLINT_VERSION=X.Y.Z ACTIONLINT_SHA256=HEX install-actionlint.sh DIR
# Both variables may be empty; an empty version selects default_version.
set -euo pipefail

dest=${1:?usage: install-actionlint.sh DIR}
version=${ACTIONLINT_VERSION:-}
supplied_sha256=${ACTIONLINT_SHA256:-}

default_version=1.7.12
shellcheck_version=0.11.0

fail() {
  echo "::error title=actionlint::$1" >&2
  exit 1
}

known_actionlint_sha256() {
  case "$1" in
    1.7.12-linux_amd64) echo 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
    1.7.12-linux_arm64) echo 325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 ;;
  esac
}

fetch_verified() {
  local url=$1 expected=$2 out=$3 actual
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 \
    --connect-timeout 10 --max-time 120 -o "$out" "$url" \
    || fail "could not download ${url}; check that the release exists"
  actual=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    fail "${url} has sha256 ${actual}, expected ${expected}; the download is not the pinned release"
  fi
}

version=${version:-$default_version}
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "actionlint-version '${version}' is not a release number; expected the form 1.7.12, with no leading v"
fi

supplied_sha256=${supplied_sha256,,}
if [ -n "$supplied_sha256" ] && ! [[ "$supplied_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  fail "actionlint-sha256 '${supplied_sha256}' is not 64 hexadecimal characters"
fi

platform="$(uname -s)-$(uname -m)"
case "$platform" in
  Linux-x86_64)
    actionlint_platform=linux_amd64
    shellcheck_platform=linux.x86_64
    shellcheck_sha256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    ;;
  Linux-aarch64 | Linux-arm64)
    actionlint_platform=linux_arm64
    shellcheck_platform=linux.aarch64
    shellcheck_sha256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
    ;;
  *)
    fail "the actionlint job runs on Linux x86_64 and arm64 runners, not ${platform}; pass a Linux label as runs-on"
    ;;
esac

archive="actionlint_${version}_${actionlint_platform}.tar.gz"
known_sha256=$(known_actionlint_sha256 "${version}-${actionlint_platform}")

if [ -n "$known_sha256" ] && [ -n "$supplied_sha256" ] && [ "$known_sha256" != "$supplied_sha256" ]; then
  fail "actionlint-sha256 ${supplied_sha256} disagrees with the ${known_sha256} pinned for ${archive}; remove the input, or correct it"
fi

expected_sha256=${known_sha256:-$supplied_sha256}
if [ -z "$expected_sha256" ]; then
  fail "actionlint ${version} has no known checksum for ${archive}, so it was not downloaded. Pass actionlint-sha256 with the value from: gh release view v${version} -R rhysd/actionlint --json assets --jq '.assets[] | select(.name == \"${archive}\") | .digest'"
fi

work=$(mktemp -d)
fetch_verified "https://github.com/rhysd/actionlint/releases/download/v${version}/${archive}" \
  "$expected_sha256" "$work/actionlint.tar.gz"
fetch_verified "https://github.com/koalaman/shellcheck/releases/download/v${shellcheck_version}/shellcheck-v${shellcheck_version}.${shellcheck_platform}.tar.xz" \
  "$shellcheck_sha256" "$work/shellcheck.tar.xz"

tar -xzf "$work/actionlint.tar.gz" -C "$work" actionlint
tar -xJf "$work/shellcheck.tar.xz" -C "$work" --strip-components=1 "shellcheck-v${shellcheck_version}/shellcheck"

mkdir -p "$dest"
install -m 0755 "$work/actionlint" "$work/shellcheck" "$dest/"

echo "Installed ${archive} (sha256 ${expected_sha256})"
"$dest/actionlint" -version
"$dest/shellcheck" --version
