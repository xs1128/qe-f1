# Quantum ESPRESSO on 創進一號

One command to build Quantum ESPRESSO 7.6 from source on NCHC Forerunner 1.
No container, no Spack.

## Install

On a login node (`f1-ilgn01` or `f1-ilgn02`), from any directory:

```bash
git clone https://github.com/YOUR-USERNAME/qe-f1.git
./qe-f1/install.sh
```

Takes about 4 minutes and installs into `~/opt/qe-7.6`. Then:

```bash
source ~/opt/qe-7.6/env.sh
pw.x --version
```

Options are environment variables: `QE_PREFIX` to install elsewhere, `QE_JOBS`
to change the number of compile jobs (default 32), `QE_FORCE=1` to rebuild over
an existing install.

## Running jobs

`env.sh` loads the compiler module and puts `pw.x` on your `PATH`. There is an
example job script in `~/opt/qe-7.6/share/example-scf.sbatch`:

```bash
sbatch --account=YOUR_PROJECT example-scf.sbatch my.scf.in
```

Use the `development` partition for tests and `ct112`/`ct448`/`ct1k`/`ct2k`/`ct4k`
for real work. Nodes have 112 cores.

## How it stays reproducible

The QE version, its SHA-256, and the compiler module are all pinned at the top
of `install.sh`, and the checksum is verified before anything is built. The
module is pinned to `intel/2024_01_46` rather than the site default, because
defaults move and that would silently change the compiler.

The script runs `module purge` first. This matters more than it looks: F1 login
shells automatically load miniconda3 and downgrade gcc, so without the purge the
build picks up whatever happens to be on `PATH` and you get a different result
on someone else's account.

MKL provides BLAS, LAPACK, ScaLAPACK and the FFTs, so there is nothing else to
compile. QE's `configure` doesn't fail when it can't find MKL though — it falls
back to its own bundled LAPACK, which builds fine and runs about ten times
slower. So the script greps `make.inc` afterwards and stops if MKL and ScaLAPACK
aren't actually there.

Finally it runs a small silicon SCF calculation and checks the total energy
against `-15.83812818 Ry`. If that doesn't match, the install fails instead of
handing you binaries that don't work. The output is kept in
`~/opt/qe-7.6/share/test/pw.out`.

## Notes and limitations

- x86_64 only. The ARM (Grace) nodes have no Intel compiler or MKL.
- Compute nodes have no internet access, so the download has to happen on a
  login node. Running the script once caches the tarball in `~/.cache/qe-f1`.
- HDF5, libxc and ELPA are left off. They aren't needed for a normal `pw.x`
  workflow and each one is another thing that can break.
- Needs about 3 GB of space while building; the finished install is 1.2 GB.
- If `ifx` ever fails on some source file, `ifort` is in the same module — swap
  the `FC`/`MPIF90` values in `install.sh`.
- `CondaError: Run 'conda init' before 'conda deactivate'` during the install is
  harmless noise from the site's login profile. You get it from `bash -lc true`
  on a clean account too.

## License

MIT
