# Source acquisition: a checksummed tarball with a mirror, then a commit-pinned
# git clone. Two independent paths so one upstream change cannot block installs.
# shellcheck shell=bash

download() {
  local url=$1 out=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$out" -- "$url" >>"$LOG_FILE" 2>&1
  else
    wget -q -t 3 -T 20 -O "$out" -- "$url" >>"$LOG_FILE" 2>&1
  fi
}

# Populate $1 with a verified tarball. Returns non-zero if every mirror failed.
fetch_tarball() {
  local dest=$1 url
  if [[ -f $dest ]] && verify_sha256 "$dest" "$QE_TARBALL_SHA256"; then
    ok "using cached $QE_TARBALL (checksum verified)"
    return 0
  fi
  for url in "${QE_TARBALL_URLS[@]}"; do
    info "fetching ${url#https://}"
    if ! download "$url" "$dest.part"; then
      warn "download failed from $url"
      rm -f -- "$dest.part"
      continue
    fi
    if verify_sha256 "$dest.part" "$QE_TARBALL_SHA256"; then
      mv -f -- "$dest.part" "$dest"
      ok "checksum verified: $QE_TARBALL_SHA256"
      return 0
    fi
    warn "checksum mismatch from $url (got $(sha256_of "$dest.part"))"
    rm -f -- "$dest.part"
  done
  return 1
}

# Clone the pinned commit into $1. Refuses to proceed if the tag has moved.
clone_pinned() {
  local dest=$1 head
  require_cmd git
  rm -rf -- "$dest"
  git clone --quiet --depth 1 --branch "$QE_GIT_TAG" -- "$QE_GIT_REPO" "$dest" >>"$LOG_FILE" 2>&1 ||
    die "git clone of $QE_GIT_TAG from $QE_GIT_REPO failed"
  head=$(git -C "$dest" rev-parse HEAD)
  [[ $head == "$QE_COMMIT" ]] ||
    die "tag $QE_GIT_TAG now resolves to $head but this repo pins $QE_COMMIT; upstream moved the tag, refusing to build an unverified tree"
  ok "cloned pinned commit $QE_COMMIT"
}

# Extract $1 into directory $2 and echo the resulting source tree path.
extract_tarball() {
  local tarball=$1 into=$2 top
  top=$(tar tzf "$tarball" | head -1 | cut -d/ -f1)
  [[ -n $top ]] || die "cannot determine top-level directory of $tarball"
  rm -rf -- "$into/$top"
  tar xzf "$tarball" -C "$into" >>"$LOG_FILE" 2>&1 || die "failed to extract $tarball"
  printf '%s\n' "$into/$top"
}
