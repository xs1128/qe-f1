#!/usr/bin/env bash
#
# Reproducible Quantum ESPRESSO installer for NCHC Forerunner 1 (創進一號).
# No container, no Spack: builds from a pinned upstream source tree against the
# site Intel oneAPI module.
#
#   ./install.sh                 install to ~/opt/qe-<version>
#   ./install.sh --prefix DIR    install elsewhere
#   ./install.sh --help          all options
#
set -euo pipefail

# Resolve the repo root from the script's own location so the working directory
# never matters, and nothing is ever written inside the repo.
self=${BASH_SOURCE[0]}
if readlink -f -- "$self" >/dev/null 2>&1; then self=$(readlink -f -- "$self"); fi
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$self")" && pwd -P)
readonly REPO_ROOT

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/manifest/versions.env"
source "$REPO_ROOT/tests/si-scf/reference.env"
source "$REPO_ROOT/lib/toolchain.sh"
source "$REPO_ROOT/lib/fetch.sh"

readonly DISK_REQUIRED_MIB=5120
readonly PROVENANCE_REL=share/qe-f1/install-manifest.txt

PREFIX=${QE_PREFIX:-$HOME/opt/qe-$QE_VERSION}
CACHE_DIR=${QE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/qe-f1}
WORK_DIR=''
JOBS=''
FORTRAN=ifx
VERBOSE=0
FORCE=0
KEEP_BUILD=0
RUN_TEST=1

usage() {
  cat <<EOF
Install Quantum ESPRESSO $QE_VERSION on NCHC Forerunner 1.

Usage: install.sh [options]

  -p, --prefix DIR    install prefix (default: \$HOME/opt/qe-$QE_VERSION)
  -j, --jobs N        parallel compile jobs (default: min(nproc, 32))
  -w, --work-dir DIR  scratch build directory (default: <prefix>/.build)
      --fortran NAME  Fortran driver: ifx (default) or ifort
      --skip-test     do not run the post-install verification calculation
      --keep-build    keep the build tree after a successful install
  -f, --force         reinstall even if this exact build is already present
  -v, --verbose       stream build output instead of logging it quietly
  -h, --help          show this message

Environment: QE_PREFIX and QE_CACHE_DIR are honoured as defaults.
EOF
}

while (($#)); do
  case $1 in
    -p|--prefix)   PREFIX=${2:?--prefix needs a directory}; shift 2 ;;
    -j|--jobs)     JOBS=${2:?--jobs needs a number}; shift 2 ;;
    -w|--work-dir) WORK_DIR=${2:?--work-dir needs a directory}; shift 2 ;;
    --fortran)     FORTRAN=${2:?--fortran needs ifx or ifort}; shift 2 ;;
    --skip-test)   RUN_TEST=0; shift ;;
    --keep-build)  KEEP_BUILD=1; shift ;;
    -f|--force)    FORCE=1; shift ;;
    -v|--verbose)  VERBOSE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) printf 'error: unknown option %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case $FORTRAN in
  ifx)   QE_MPIFC=mpiifx ;;
  ifort) QE_MPIFC=mpiifort ;;
  *) die "--fortran must be ifx or ifort, got '$FORTRAN'" ;;
esac
QE_MPICC=mpiicx

# Make the prefix absolute before anything depends on it.
mkdir -p -- "$PREFIX" || die "cannot create prefix $PREFIX"
PREFIX=$(CDPATH='' cd -- "$PREFIX" && pwd -P)
: "${WORK_DIR:=$PREFIX/.build}"

log_init "$PREFIX/share/qe-f1/logs/install-$(date +%Y%m%dT%H%M%S).log"

cleanup_on_error() {
  local rc=$?
  ((rc == 0)) && return 0
  printf '\n%serror:%s install failed (exit %d)\n' "$_c_red" "$_c_off" "$rc" >&2
  printf '       log:        %s\n' "$LOG_FILE" >&2
  [[ -d $WORK_DIR ]] && printf '       build tree: %s (kept for inspection)\n' "$WORK_DIR" >&2
  return "$rc"
}
trap cleanup_on_error EXIT

# --- stage 1: preflight ------------------------------------------------------

preflight() {
  step "Checking the environment"

  ((BASH_VERSINFO[0] >= 4)) || die "bash 4 or newer required, found $BASH_VERSION"
  ((EUID != 0)) || die "refusing to run as root; this installs into your own home directory"

  local arch; arch=$(uname -m)
  [[ $arch == x86_64 ]] ||
    die "this recipe targets the x86_64 nodes of Forerunner 1 but the current host is $arch; the Intel toolchain and MKL are not available on the ARM (Grace) nodes"

  require_cmd tar make awk sed df dirname
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 ||
    die "need either curl or wget to fetch the source"

  local avail; avail=$(free_mib "$WORK_DIR")
  ((avail >= DISK_REQUIRED_MIB)) ||
    die "need about ${DISK_REQUIRED_MIB} MiB free for the build (source 1.7G, install 1.2G) but only ${avail} MiB available at $WORK_DIR"
  ok "x86_64, bash $BASH_VERSION, ${avail} MiB free"

  # Compute nodes on Forerunner 1 have no route to the internet, so a cached
  # tarball is the only way an install can succeed inside a Slurm allocation.
  if [[ -n ${SLURM_JOB_ID:-} ]] && [[ ! -f $CACHE_DIR/$QE_TARBALL ]]; then
    die "running inside Slurm job $SLURM_JOB_ID with no cached source, and Forerunner 1 compute nodes have no internet access; run this once on a login node first (it caches to $CACHE_DIR)"
  fi
}

# --- stage 2: skip if already installed --------------------------------------

already_installed() {
  local stamp=$PREFIX/$PROVENANCE_REL
  [[ -x $PREFIX/bin/pw.x && -f $stamp ]] || return 1
  grep -qxF "qe_commit=$QE_COMMIT" "$stamp" &&
    grep -qxF "toolchain_module=$TOOLCHAIN_MODULE" "$stamp" &&
    grep -qxF "fortran_driver=$QE_MPIFC" "$stamp"
}

# --- stage 3: source ---------------------------------------------------------

obtain_source() {
  step "Obtaining Quantum ESPRESSO $QE_VERSION"
  mkdir -p -- "$CACHE_DIR" "$WORK_DIR"
  if fetch_tarball "$CACHE_DIR/$QE_TARBALL"; then
    SRC_DIR=$(extract_tarball "$CACHE_DIR/$QE_TARBALL" "$WORK_DIR")
  else
    warn "no mirror produced the expected checksum; falling back to the pinned git commit"
    SRC_DIR=$WORK_DIR/q-e-$QE_GIT_TAG
    clone_pinned "$SRC_DIR"
  fi
  info "source tree: $SRC_DIR"
}

# --- stage 4: configure ------------------------------------------------------

configure_source() {
  step "Configuring"
  run "configure --prefix=$PREFIX" env -C "$SRC_DIR" ./configure \
    --prefix="$PREFIX" \
    --enable-parallel \
    --enable-openmp \
    --with-scalapack=intel \
    CC="$QE_MPICC" FC="$QE_MPIFC" MPIF90="$QE_MPIFC" ||
    die "configure failed"

  # configure falls back to QE's bundled reference LAPACK without failing when
  # it cannot find MKL, so assert on what it actually produced.
  local makeinc=$SRC_DIR/make.inc flag
  [[ -f $makeinc ]] || die "configure did not produce $makeinc"
  for flag in $QE_EXPECTED_DFLAGS; do
    grep -q -- "$flag" <(grep '^DFLAGS' "$makeinc") ||
      die "make.inc is missing $flag; MKL or MPI was not detected properly (see DFLAGS in $makeinc)"
  done
  grep '^BLAS_LIBS' "$makeinc" | grep -q mkl ||
    die "make.inc did not link MKL for BLAS; the build would silently use the slow reference implementation"
  ok "DFLAGS and MKL linkage verified"
}

# --- stage 5: build ----------------------------------------------------------

build_and_install() {
  step "Building with $JOBS parallel jobs (a few minutes)"
  run "make -j$JOBS all" make -C "$SRC_DIR" -j"$JOBS" all || die "build failed"
  run "make install" make -C "$SRC_DIR" install || die "install failed"
  local n; n=$(find "$PREFIX/bin" -maxdepth 1 -name '*.x' | wc -l | tr -d ' ')
  ((n > 0)) || die "make install produced no executables in $PREFIX/bin"
  ok "installed $n executables into $PREFIX/bin"
}

# --- stage 6: environment + provenance ---------------------------------------

write_env_script() {
  step "Writing the runtime environment"
  local env_file=$PREFIX/env.sh
  cat >"$env_file" <<EOF
# Runtime environment for Quantum ESPRESSO $QE_VERSION on Forerunner 1.
# Generated by qe-f1 install.sh on $(date -Iseconds) -- do not edit by hand.
# Source this file, do not execute it:  source $env_file

if [[ \${BASH_SOURCE[0]} == "\$0" ]]; then
  echo "error: source this file instead of running it: source \${BASH_SOURCE[0]}" >&2
  exit 1
fi

if ! declare -F module >/dev/null 2>&1; then
  source "\${MODULESHOME:-/usr/share/lmod/lmod}/init/bash"
fi
module purge >/dev/null 2>&1
module load $TOOLCHAIN_MODULE

export QE_ROOT="$PREFIX"
export PATH="\$QE_ROOT/bin:\$PATH"
export ESPRESSO_PSEUDO="\${ESPRESSO_PSEUDO:-\$QE_ROOT/share/qe-f1/pseudo}"
export OMP_NUM_THREADS="\${OMP_NUM_THREADS:-1}"

# Intel MPI only needs Slurm's PMI when it is actually launched by srun;
# exporting it unconditionally breaks plain mpirun on a login node.
if [[ -n \${SLURM_JOB_ID:-} ]]; then
  export I_MPI_PMI_LIBRARY=/usr/lib64/libpmi.so
fi
EOF
  ok "wrote $env_file"

  mkdir -p -- "$PREFIX/share/qe-f1"
  cp -r -- "$REPO_ROOT/tests/si-scf" "$PREFIX/share/qe-f1/"
  cp -- "$REPO_ROOT/slurm/example-scf.sbatch" "$PREFIX/share/qe-f1/"
  ln -sfn -- "$PREFIX/share/qe-f1/si-scf/pseudo" "$PREFIX/share/qe-f1/pseudo"
}

write_provenance() {
  local out=$PREFIX/$PROVENANCE_REL
  mkdir -p -- "$(dirname -- "$out")"
  {
    printf 'installed_at=%s\n' "$(date -Iseconds)"
    printf 'installed_by=%s\n' "$(id -un)"
    printf 'installed_on=%s\n' "$(uname -n)"
    printf 'qe_version=%s\n' "$QE_VERSION"
    printf 'qe_commit=%s\n' "$QE_COMMIT"
    printf 'qe_tarball_sha256=%s\n' "$QE_TARBALL_SHA256"
    printf 'toolchain_module=%s\n' "$TOOLCHAIN_MODULE"
    printf 'fortran_driver=%s\n' "$QE_MPIFC"
    printf 'recipe_commit=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'dflags=%s\n' "$(sed -n 's/^DFLAGS *= *//p' "$SRC_DIR/make.inc" 2>/dev/null | head -1)"
  } >"$out"
  info "provenance: $out"
}

# --- stage 7: verify ---------------------------------------------------------

self_test() {
  step "Verifying the install with a real SCF calculation"
  local rundir=$WORK_DIR/self-test
  rm -rf -- "$rundir"; mkdir -p -- "$rundir"
  cp -- "$REPO_ROOT/tests/si-scf/si.scf.in" "$rundir/"
  cp -r -- "$REPO_ROOT/tests/si-scf/pseudo" "$rundir/"

  verify_sha256 "$rundir/pseudo/$QE_TEST_PSEUDO" "$QE_TEST_PSEUDO_SHA256" ||
    die "pseudopotential $QE_TEST_PSEUDO failed its checksum; the test inputs are corrupt"

  # This runs on a login node, outside Slurm, so PMI must not be forced.
  unset I_MPI_PMI_LIBRARY
  export OMP_NUM_THREADS=1
  run "mpirun -np $QE_TEST_RANKS pw.x" env -C "$rundir" \
    mpirun -np "$QE_TEST_RANKS" "$PREFIX/bin/pw.x" -i si.scf.in ||
    die "the verification calculation did not run; see $rundir/pw.out"

  grep -q 'JOB DONE' "$rundir/pw.out" ||
    die "pw.x did not reach 'JOB DONE'; see $rundir/pw.out"

  local got
  got=$(awk '/^![[:space:]]+total energy/ {v=$5} END {print v}' "$rundir/pw.out")
  [[ -n $got ]] || die "no total energy found in $rundir/pw.out"
  awk -v a="$got" -v b="$QE_TEST_ENERGY_RY" -v t="$QE_TEST_TOLERANCE_RY" \
    'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }' ||
    die "total energy $got Ry differs from the reference $QE_TEST_ENERGY_RY Ry by more than $QE_TEST_TOLERANCE_RY Ry"
  ok "total energy $got Ry matches the reference within $QE_TEST_TOLERANCE_RY Ry"
}

# --- main --------------------------------------------------------------------

main() {
  printf '%sQuantum ESPRESSO %s -> %s%s\n\n' "$_c_bold" "$QE_VERSION" "$PREFIX" "$_c_off"

  preflight

  if ((FORCE == 0)) && already_installed; then
    step "Already installed"
    info "$PREFIX/bin/pw.x matches the pinned build; nothing to do"
    info "re-run with --force to rebuild"
    printf '\nActivate with:  source %s/env.sh\n' "$PREFIX"
    exit 0
  fi

  load_toolchain
  verify_toolchain

  : "${JOBS:=$(n=$(nproc 2>/dev/null || echo 8); ((n > 32)) && n=32; echo "$n")}"
  [[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer, got '$JOBS'"

  obtain_source
  configure_source
  build_and_install
  write_env_script
  write_provenance
  ((RUN_TEST == 1)) && self_test

  if ((KEEP_BUILD == 0)); then
    rm -rf -- "$WORK_DIR"
  else
    info "build tree kept at $WORK_DIR"
  fi

  printf '\n%sDone.%s Quantum ESPRESSO %s is installed in %s\n\n' \
    "$_c_green" "$_c_off" "$QE_VERSION" "$PREFIX"
  cat <<EOF
Activate it in any shell with:

    source $PREFIX/env.sh
    pw.x --version

An example Slurm job script is at:

    $PREFIX/share/qe-f1/example-scf.sbatch
EOF
}

main "$@"
