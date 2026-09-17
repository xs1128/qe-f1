#!/bin/bash
#SBATCH --job-name=qe
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --time=00:30:00
#SBATCH --partition=development
#SBATCH --output=%x-%j.out

# sbatch --account=YOUR_PROJECT example-scf.sbatch my.scf.in
# run `wallet` to find your project code
set -e

input=${1:-si.scf.in}
source "${QE_ENV:-$HOME/opt/qe-7.6/env.sh}"
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK:-1}
cd "$SLURM_SUBMIT_DIR"

# let srun start the ranks, wrapping mpirun in srun -n 8 launches 8 mpiruns and hangs
srun pw.x -nk 2 -i "$input" >"${input%.*}.out"
