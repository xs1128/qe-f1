#!/bin/bash
# Install Quantum ESPRESSO on 創進一號 (Forerunner 1). Run on a login node.
set -euo pipefail

VER=7.6
SHA=945c8f16ab330c8f0b30f4de1a9a088b85038476fcd819394e641f4d2d8b7d51
URL=https://gitlab.com/QEF/q-e/-/archive/qe-$VER/q-e-qe-$VER.tar.gz
URL2=https://github.com/QEF/q-e/archive/refs/tags/qe-$VER.tar.gz
MODULE=intel/2024_01_46
REF=-15.83812818

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
prefix=${QE_PREFIX:-$HOME/opt/qe-$VER}
jobs=${QE_JOBS:-32}
cache=$HOME/.cache/qe-f1
build=$prefix/.build
tarball=$cache/q-e-qe-$VER.tar.gz

if [ -x "$prefix/bin/pw.x" ] && [ -z "${QE_FORCE:-}" ]; then
	echo "already installed in $prefix, set QE_FORCE=1 to rebuild"
	echo "source $prefix/env.sh to use it"
	exit 0
fi

# login shells here auto-load miniconda and gcc, don't let that reach the build
module purge >/dev/null 2>&1 || true
module load $MODULE
[ -n "${MKLROOT:-}" ] || { echo "MKL missing after loading $MODULE" >&2; exit 1; }

mkdir -p "$cache" "$build"
if ! echo "$SHA  $tarball" | sha256sum -c --status 2>/dev/null; then
	echo "==> downloading QE $VER"
	curl -fL --retry 3 -o "$tarball" "$URL" || curl -fL --retry 3 -o "$tarball" "$URL2"
	echo "$SHA  $tarball" | sha256sum -c --status || { echo "checksum mismatch" >&2; exit 1; }
fi

rm -rf "$build/q-e-qe-$VER"
tar xzf "$tarball" -C "$build"
cd "$build/q-e-qe-$VER"

echo "==> configure"
./configure --prefix="$prefix" --enable-parallel --enable-openmp \
	--with-scalapack=intel CC=mpiicx FC=mpiifx MPIF90=mpiifx >configure.log 2>&1

# configure quietly falls back to QE's own slow LAPACK if it can't find MKL
grep '^BLAS_LIBS' make.inc | grep -q mkl || { echo "MKL not picked up, see $PWD/configure.log" >&2; exit 1; }
grep -q __SCALAPACK make.inc || { echo "ScaLAPACK not enabled" >&2; exit 1; }

echo "==> building with $jobs jobs, this takes a few minutes"
make -j"$jobs" all >make.log 2>&1
make install >>make.log 2>&1

cat >"$prefix/env.sh" <<EOF
module purge >/dev/null 2>&1 || true
module load $MODULE
export PATH="$prefix/bin:\$PATH"
export OMP_NUM_THREADS=\${OMP_NUM_THREADS:-1}
# srun needs this, but setting it always breaks plain mpirun on a login node
if [ -n "\${SLURM_JOB_ID:-}" ]; then
	export I_MPI_PMI_LIBRARY=/usr/lib64/libpmi.so
fi
EOF

echo "==> test run"
test=$prefix/share/test
rm -rf "$test"
mkdir -p "$test"
cp -r "$here/tests/si-scf/." "$test/"
cd "$test"
unset I_MPI_PMI_LIBRARY
OMP_NUM_THREADS=1 mpirun -np 2 "$prefix/bin/pw.x" -i si.scf.in >pw.out 2>&1
energy=$(awk '/^!.*total energy/ {e=$5} END {print e}' pw.out)
awk -v a="$energy" -v b=$REF 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d < 1e-6) }' ||
	{ echo "got $energy Ry, expected $REF Ry, see $test/pw.out" >&2; exit 1; }
echo "    total energy $energy Ry, matches reference"

cp "$here/slurm/example-scf.sbatch" "$prefix/share/"
rm -rf "$build"

echo
echo "done, QE $VER is in $prefix"
echo "source $prefix/env.sh to use it"
