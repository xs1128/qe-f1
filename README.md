# Quantum ESPRESSO on NCHC Forerunner 1 (創進一號)

A reproducible, one-command source install of [Quantum ESPRESSO](https://www.quantum-espresso.org/)
7.6 for the x86 nodes of NCHC Forerunner 1. No container, no Spack: the build
runs against the site Intel oneAPI module from a cryptographically pinned
upstream source tree, and verifies itself with a real SCF calculation before it
reports success.

## Quick start

Run this from any directory, as any user with an F1 account, on a login node
(`f1-ilgn01` or `f1-ilgn02`):

```bash
git clone https://github.com/YOUR-USERNAME/qe-f1.git
./qe-f1/install.sh
```

That takes about **4 minutes** and installs into `~/opt/qe-7.6`. Then, in any
shell:

```bash
source ~/opt/qe-7.6/env.sh
pw.x --version
```

## What it does

| Stage | Detail |
| --- | --- |
| Preflight | Checks architecture, tools, and free disk; refuses to run as root |
| Source | Downloads a checksummed tarball, with a mirror and a commit-pinned `git clone` as fallbacks |
| Configure | Builds against MKL for BLAS, LAPACK, ScaLAPACK and FFT, then asserts the result |
| Build | `make -j32 all && make install`, producing 87 executables |
| Environment | Generates `env.sh` so the install is usable, not just present |
| Verify | Runs a 2-rank silicon SCF and compares the total energy to a known reference |
| Provenance | Records exactly what was built, from what, and with which toolchain |

## Requirements

You need nothing but an F1 account. There is no dependency to install and no
Slurm allocation required — everything the build needs comes from the
`intel/2024_01_46` module, which supplies `ifx` 2024.0.2, Intel MPI 2021.11 and
MKL 2024.0.

Budget about 3 GB of home quota during the build; the finished install is
1.2 GB and the intermediate build tree is deleted automatically.

## Options

```
-p, --prefix DIR    install prefix (default: $HOME/opt/qe-7.6)
-j, --jobs N        parallel compile jobs (default: min(nproc, 32))
-w, --work-dir DIR  scratch build directory (default: <prefix>/.build)
    --fortran NAME  Fortran driver: ifx (default) or ifort
    --skip-test     skip the post-install verification calculation
    --keep-build    keep the build tree after a successful install
-f, --force         reinstall even if this exact build is already present
-v, --verbose       stream build output instead of logging it quietly
-h, --help          show usage
```

`QE_PREFIX` and `QE_CACHE_DIR` are honoured as defaults. Re-running the
installer is safe: if the pinned build is already present and verified it exits
immediately without rebuilding.

## Running a calculation

`env.sh` loads the pinned toolchain, puts `pw.x` on `PATH`, and sets
`I_MPI_PMI_LIBRARY` only when it detects it is inside a Slurm allocation —
exporting that variable unconditionally breaks plain `mpirun` on a login node.

A working job script is installed at
`~/opt/qe-7.6/share/qe-f1/example-scf.sbatch`:

```bash
sbatch --account=YOUR_PROJECT example-scf.sbatch my.scf.in
```

Run `wallet` to find your project code. Use the `development` partition (8 h
limit) for tests and `ct112` / `ct448` / `ct1k` / `ct2k` / `ct4k` for production
work. Nodes have 112 cores each.

Let `srun` launch the MPI ranks directly, as the example does. Do **not** wrap
`mpirun` inside an `srun` with `--ntasks` greater than 1: that starts one
`mpirun` per task, oversubscribes the allocation and deadlocks.

## Verification

The installer's own self-test runs the silicon SCF in `tests/si-scf/` on 2 ranks
and asserts the total energy is `-15.83812818 Ry` to within `1e-6 Ry`. The
reference was measured on F1 with this toolchain; `conv_thr` is `1e-8 Ry`, so
the tolerance is insensitive to rank count but far tighter than the shift a
broken FFT or LAPACK path would cause. The install aborts if it does not match.

Results are kept for inspection at `~/opt/qe-7.6/share/qe-f1/self-test/pw.out`,
and every install writes a provenance record:

```
$ cat ~/opt/qe-7.6/share/qe-f1/install-manifest.txt
verified=yes
qe_version=7.6
qe_commit=9f93ddec427d2b9a45bb72d828c6d324f62fcabd
qe_tarball_sha256=945c8f16ab330c8f0b30f4de1a9a088b85038476fcd819394e641f4d2d8b7d51
toolchain_module=intel/2024_01_46
fortran_driver=mpiifx
recipe_commit=...
dflags=-D__DFTI -D__MPI -D__MPI_MODULE -D__SCALAPACK
```

## Reproducibility

Everything that can vary between two runs is pinned in
[`manifest/versions.env`](manifest/versions.env) and checked at install time.

**The source is pinned by git commit, not just by tarball hash.** The tag
`qe-7.6` dereferences to commit `9f93ddec427d2b9a45bb72d828c6d324f62fcabd`, and
git object IDs are content-addressed, so that is the authoritative identity of
the source. The tarball SHA-256 is only a faster path to the same bytes. This
distinction matters: both download URLs are `git archive` endpoints that
regenerate their output on demand, so the compressed bytes — and therefore the
checksum — can legitimately change when the host upgrades its tooling, without
the source changing at all. A checksum mismatch is therefore treated as "try the
next mirror, then fall back to a commit-pinned clone", not as a fatal error. A
clone whose `HEAD` does not match the pinned commit *is* fatal, because that
means upstream moved the tag.

Two mirrors are configured (GitLab and GitHub) and served byte-identical
archives when this was pinned, so neither host is a single point of failure.

**The toolchain is pinned to an exact module version.** `intel/2024_01_46` is
currently also the site default, but defaults move, and the difference would
silently change the compiler. The installer fails with an actionable message
rather than falling back to whatever is available.

**The environment is reset before use.** F1 login shells automatically load
miniconda3 and downgrade `gcc/11.2.0` to `gcc/10.4.0`, so the installer runs
`module purge` first. Without that, the build inherits whichever compiler and
Python happen to win, which is exactly the kind of hidden input that makes a
build unreproducible on someone else's account.

**Library detection is asserted, not assumed.** QE's `configure` does not fail
when it cannot find MKL; it quietly falls back to the bundled reference LAPACK,
which builds successfully and runs roughly an order of magnitude slower. The
installer therefore checks that the generated `make.inc` really contains
`-D__DFTI -D__MPI -D__SCALAPACK` and really links MKL, and aborts if not.

### Limitations

Worth stating plainly, because reproducibility has an edge:

- This depends on NCHC continuing to provide the `intel/2024_01_46` module. If
  it is ever withdrawn the install cannot proceed, by design, rather than
  silently building something different.
- It targets **x86_64 only**. The 40 ARM (NVIDIA Grace) nodes on F1 have no
  Intel toolchain or MKL, and the installer refuses to run there rather than
  producing a broken build.
- The download requires internet access, which **only login nodes have** —
  compute nodes on F1 cannot reach the outside world. The installer detects that
  it is inside a Slurm job without a cached tarball and says so explicitly.
  Running it once on a login node populates `~/.cache/qe-f1`, after which an
  offline install would work.
- HDF5, libxc and ELPA are deliberately not enabled. They add failure modes
  without being needed for a standard `pw.x` workflow.

## Troubleshooting

**`CondaError: Run 'conda init' before 'conda deactivate'`** — harmless
pre-existing noise from the site's login profile, emitted whenever a module
purge unloads the auto-loaded miniconda3. You can reproduce it with
`bash -lc true` on a clean account. It does not affect the build.

**`sbatch`/`srun` fail with `ERROR: Oops! Something went wrong! get_api_token`** —
a site-side Slurm submission problem, not something this repo can influence.
Retry later or contact NCHC support. The install itself does not need Slurm.

**A compile error inside `ifx`** — retry with `./install.sh --fortran ifort`.
The classic compiler is still shipped in the same module. `ifx` builds the whole
tree cleanly as pinned, so this is only insurance against a future version.

**Want to see what the build is doing** — pass `-v`, or tail the log path that
the installer prints on failure.

## Repository layout

```
install.sh                  single entry point
manifest/versions.env       every pinned version, URL and checksum
lib/common.sh               logging, error handling, checksums
lib/toolchain.sh            Lmod interaction
lib/fetch.sh                download, verify, commit-pinned clone fallback
tests/si-scf/               verification input, pseudopotential, reference value
slurm/example-scf.sbatch    working job script
```

Nothing is ever written inside this repository, so it works fine from a
read-only or shared clone.

## License

MIT — see [LICENSE](LICENSE).
