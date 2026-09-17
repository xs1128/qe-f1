# Lmod interaction, kept separate because this is the most environment-sensitive
# part of the install.
# shellcheck shell=bash

# Lmod exports `module` as a shell function, which children normally inherit,
# but a script run under `env -i`, cron or a Slurm prolog will not have it.
ensure_module_cmd() {
  declare -F module >/dev/null 2>&1 && return 0
  local init=${MODULESHOME:-/usr/share/lmod/lmod}/init/bash
  [[ -r $init ]] || die "no 'module' command and no Lmod init at $init; this installer targets Forerunner 1 (f1-ilgn01 / f1-ilgn02)"
  set +u; source "$init"; set -u
  declare -F module >/dev/null 2>&1 || die "sourced $init but 'module' is still undefined"
}

# Lmod's init script and modulefiles are not written against `set -u`.
module_do() {
  local rc=0
  set +u
  module "$@" >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$?
  set -u
  return "$rc"
}

load_toolchain() {
  ensure_module_cmd
  # Forerunner 1 logins auto-load miniconda3 and silently downgrade gcc, so
  # purging is not optional: without it the build inherits whichever compiler
  # and Python happen to be on PATH.
  module_do purge || warn "module purge reported an error, continuing"
  module_do load "$TOOLCHAIN_MODULE" ||
    die "cannot load $TOOLCHAIN_MODULE -- run 'module avail intel' and update TOOLCHAIN_MODULE in manifest/versions.env"
}

verify_toolchain() {
  require_cmd "$QE_MPIFC" "$QE_MPICC"
  [[ -n ${MKLROOT:-} ]] ||
    die "MKLROOT is unset after loading $TOOLCHAIN_MODULE; MKL provides BLAS, LAPACK, ScaLAPACK and FFT and is required"
  info "Fortran: $(command -v "$QE_MPIFC")"
  info "MKL:     $MKLROOT"
}
