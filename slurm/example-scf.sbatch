#!/bin/bash
#
# Example Quantum ESPRESSO job on NCHC Forerunner 1.
#
#   sbatch --account=YOUR_PROJECT example-scf.sbatch si.scf.in
#
# Partitions: development (8 h, for testing), ct112 / ct448 / ct1k / ct2k / ct4k
# for production. Nodes have 112 cores; see `wallet` for your project codes.
#
#SBATCH --job-name=qe-scf
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --cpus-per-task=1
#SBATCH --time=00:30:00
#SBATCH --partition=development
#SBATCH --output=%x-%j.out

set -euo pipefail

INPUT=${1:-si.scf.in}
QE_ENV=${QE_ENV:-$HOME/opt/qe-7.6/env.sh}

# env.sh purges modules, loads the pinned Intel toolchain, puts pw.x on PATH,
# and sets I_MPI_PMI_LIBRARY because we are inside a Slurm allocation.
source "$QE_ENV"

export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK:-1}

cd "$SLURM_SUBMIT_DIR"

echo "host:   $SLURM_NODELIST"
echo "ranks:  $SLURM_NTASKS x $OMP_NUM_THREADS threads"
echo "pw.x:   $(command -v pw.x)"

# Let srun launch the ranks directly. Do not wrap mpirun in an srun with
# --ntasks>1: that starts one mpirun per task and the job deadlocks.
srun pw.x -nk 2 -i "$INPUT" > "${INPUT%.*}.out"

echo "done: ${INPUT%.*}.out"
