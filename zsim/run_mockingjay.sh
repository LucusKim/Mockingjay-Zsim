#!/bin/bash
# Run one or more benchmarks with the Mockingjay LLC replacement policy.
#
# Usage: ./run_mockingjay.sh <benchmark ...|spec|parsec|all>
#   ./run_mockingjay.sh mcf
#   ./run_mockingjay.sh canneal streamcluster
#   ./run_mockingjay.sh spec
#
# Expects to live in casim-csce614/zsim/, with setup_env one level up.
# Results go to outputs/Mockingjay/<benchmark>[_8c_simlarge]/.

SPEC_BENCHMARKS="bzip2 gcc mcf hmmer sjeng libquantum xalancbmk milc cactusADM leslie3d namd soplex calculix lbm"
PARSEC_BENCHMARKS="blackscholes bodytrack canneal dedup fluidanimate freqmine streamcluster swaptions x264"
POLICY="Mockingjay"

if [ "$#" -lt 1 ]; then
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

ZSIM_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ZSIM_DIR/.."
[ -f venv/bin/activate ] && source venv/bin/activate
source setup_env
cd "$ZSIM_DIR"

if [ ! -x build/opt/zsim ]; then
    echo "build/opt/zsim not found; run 'scons -j4' first." >&2
    exit 1
fi

# Pin needs ptrace access to the simulated process
if [ "$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null)" != "0" ]; then
    echo 0 | sudo tee /proc/sys/kernel/yama/ptrace_scope > /dev/null
fi

case "$1" in
    spec)   BENCHES="$SPEC_BENCHMARKS" ;;
    parsec) BENCHES="$PARSEC_BENCHMARKS" ;;
    all)    BENCHES="$SPEC_BENCHMARKS $PARSEC_BENCHMARKS" ;;
    *)      BENCHES="$*" ;;
esac

total=$(echo $BENCHES | wc -w)
completed=0
echo "Policy: $POLICY | runs: $total | started: $(date)"

for bench in $BENCHES; do
    completed=$((completed+1))
    if echo " $PARSEC_BENCHMARKS " | grep -q " $bench "; then
        name="${bench}_8c_simlarge"
    elif echo " $SPEC_BENCHMARKS " | grep -q " $bench "; then
        name="$bench"
    else
        echo "[$completed/$total] Unknown benchmark '$bench', skipping" >&2
        continue
    fi

    start=$SECONDS
    echo "[$completed/$total] $name @ $(date +%H:%M:%S)"
    mkdir -p "outputs/$POLICY/$name"
    ./build/opt/zsim "configs/hw4/$POLICY/$name.cfg" > "outputs/$POLICY/$name/$bench.log" 2>&1
    status=$?
    elapsed=$(( SECONDS - start ))
    echo "  -> exit $status in $((elapsed / 60))m$((elapsed % 60))s"
done

echo "All done at: $(date)"
