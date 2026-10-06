# Mockingjay for zsim

A port of the **Mockingjay** last-level cache replacement policy from ChampSim to the
[zsim](https://github.com/s5z/zsim) microarchitecture simulator. The port includes the
zsim changes Mockingjay needs: instruction PCs visible to replacement policies, and
cache bypass on LLC misses.

> I. Shah, A. Jain, and C. Lin, "Effective Mimicry of Belady's MIN Policy," *HPCA 2022*.
> Original ChampSim code: <https://github.com/ishanashah/Mockingjay>

This was built as a course project (CSCE 614, Texas A&M) on top of the course's
`casim-csce614` zsim distribution. It was evaluated against LRU, LFU and SRRIP on
SPEC CPU2006 (single-core) and PARSEC 2.1 (8-core).

## How Mockingjay works

Mockingjay tries to approximate Belady's MIN policy using three structures:

- **Sampled cache**: tracks a small subset of LLC sets and measures actual reuse distances.
- **Reuse Distance Predictor (RDP)**: a table indexed by a hash of the PC. Sampled reuse distances train it through temporal-difference updates.
- **Estimated Time Remaining (ETR)**: a counter for each line. It starts at the RDP prediction and counts down as the set is accessed. On a miss, the line with the largest |ETR| is evicted.

When the RDP predicts that an incoming line won't be reused before everything already in
the set, the line **bypasses** the LLC and is never installed.

## Repository layout

```
mockingjay-zsim/
├── patches/                        # git-format patches against s5z/zsim @ f524c05
│   ├── 0001-casim-course-baseline.patch   # course scaffolding (see below), not Mockingjay
│   ├── 0002-pc-plumbing.patch             # MemReq::pc, set from the core's BBL address
│   ├── 0003-llc-bypass.patch              # ReplPolicy::shouldBypass + MESI bypass path
│   └── 0004-mockingjay-policy.patch       # mockingjay_repl.h + registration in init.cpp
├── zsim/                           # same changes as finished files, laid out like zsim/
│   ├── SConstruct, src/            # the 17 new or modified files
│   ├── configs/hw4/{Mockingjay,LRU,LFU,SRRIP}/*.cfg
│   ├── run_mockingjay.sh           # run one, several, or all benchmarks with Mockingjay
│   └── hw4runscript                # run any <suite> <benchmark> <policy> combination
├── scripts/apply_patches.sh        # apply patches + copy configs into a zsim tree
├── setup_env                       # environment variables (PINPATH, benchmark paths, ...)
├── docs/
│   ├── zsim_add_pc.md              # walkthrough of the PC plumbing change
│   ├── zsim_add_bypass.md          # walkthrough of the bypass change
│   └── bypass-parsec.md            # debugging notes: bypass vs. MESI on multi-core
└── reference/champsim/
    ├── mockingjay.llc_repl         # original ChampSim implementation
    └── LICENSE                     # Apache 2.0 license of the original
```

The `patches/` and `zsim/src/` folders hold the same changes in two forms. Use whichever
is easier for you.

## zsim modifications

### 1. PC plumbing (`0002-pc-plumbing.patch`)

zsim's `MemReq` has no program counter, and Mockingjay's predictor is keyed by PC.

| File | Change |
|------|--------|
| `src/memory_hierarchy.h` | Adds `uint64_t pc` as the last `MemReq` field, so existing aggregate initializers set it to 0 |
| `src/filter_cache.h` | Adds `setPc()`, and passes `curPc` into the `MemReq` built in `replace()` |
| `src/simple_core.cpp`, `src/timing_core.cpp` | Call `l1d->setPc(bblAddr)` at the start of each basic block |
| `src/ooo_core.h`, `src/ooo_core.cpp` | Track `prevBblAddr`, because the OOO core simulates the previous BBL's memory ops one callback late. Also set the PC on the L1I before fetch |

The PC is the **basic-block start address**, not the exact address of each instruction.
Internal requests (writebacks, prefetches) carry `pc == 0`.

### 2. LLC bypass (`0003-llc-bypass.patch`)

| File | Change |
|------|--------|
| `src/repl_policies.h` | Adds `virtual bool shouldBypass(const MemReq*)` to `ReplPolicy`. It returns `false` by default, so other policies behave as before |
| `src/cache.cpp` | `Cache::access()` skips `preinsert`/`processEviction`/`postinsert` when `rp->shouldBypass(&req)` is true |
| `src/coherence_ctrls.h/.cpp` | `MESICC::processAccess` sends GETs with `lineId == -1` to the new `MESIBottomCC::processAccessBypass()`, which fetches from the parent without installing the line. The `PUTS` sharer assert is now a `panic` with diagnostics |
| `src/timing_event.h` | Raises `startCycle` to `minStartCycle` instead of asserting. Bypass removes eviction events, and without them the weave and bound phases can drift apart |

See [docs/zsim_add_bypass.md](docs/zsim_add_bypass.md) for the full explanation.

### 3. Mockingjay policy (`0004-mockingjay-policy.patch`)

- `src/mockingjay_repl.h`: the `MockingjayReplPolicy` class, which implements `update()`, `replaced()`, `rank()` and `shouldBypass()`
- `src/init.cpp`: selects the policy with `repl.type = "Mockingjay"`

### Course baseline (`0001-casim-course-baseline.patch`)

These changes came with the `casim-csce614` distribution or with earlier homework. They are
not part of Mockingjay. They are included so that the patches apply to upstream zsim:
SRRIP policy (`rrip_repl.h`), A3 branch-predictor hook and `condBranches` stat, per-run
`outputDir` for stats and heartbeat, a non-static harness link, and `-lz` for HDF5.
**If you already have `casim-csce614`, skip this patch.**

## Translating ChampSim to zsim

| ChampSim | zsim |
|----------|------|
| `llc_initialize_replacement()` | constructor |
| `llc_find_victim()` | `rank(req, cands)` for victim selection, and `shouldBypass(req)` for bypass |
| `llc_update_replacement_state(..., hit)` | `update(id, req)`. zsim doesn't pass `hit`, so `replaced(id)` sets `justInserted[id]` and the next `update()` uses it to tell hits from fills |
| `WRITEBACK` | `req->type == PUTS \|\| PUTX` |
| `LLC_SET`, `LLC_WAY`, `NUM_CPUS` | computed at runtime from `numLines`, `ways` and `zinfo->numCores` (lazily, because `numCores` is 0 when caches are built) |
| set index `addr & (sets-1)` | zsim hashes set indices with H3. `shouldBypass` uses `hf->hash(0, lineAddr)` to find the real set, while the sampler uses raw address bits |

## Build and run

### Prerequisites

zsim build dependencies: gcc ≥ 4.6, Intel Pin 2.14, SCons, libconfig ≥ 1.4, libhdf5 and
libelf. Everything is set up in `casim-csce614/tools/` if you use the course distribution.
SPEC CPU2006 and PARSEC binaries are **not** included, because of licensing.

### Option A: course `casim-csce614` tree

```bash
scripts/apply_patches.sh casim /path/to/casim-csce614/zsim
# or copy the finished files directly:
# cp -r zsim/* /path/to/casim-csce614/zsim/

cd /path/to/casim-csce614
python3 -m venv venv && source venv/bin/activate && pip install scons
source setup_env
cd zsim && scons -j4
```

### Option B: upstream zsim

```bash
git clone https://github.com/s5z/zsim.git && cd zsim
git checkout f524c05
git am /path/to/mockingjay-zsim/patches/*.patch
cp -r /path/to/mockingjay-zsim/zsim/configs/hw4 configs/
cp /path/to/mockingjay-zsim/zsim/run_mockingjay.sh .
scons -j4
```

The configs expect `$CPU2006BIN`, `$CPU2006DATA`, `$PARSECBIN` and `$PARSECINPUTS` to be set.
Copy `setup_env` and edit its paths to match your machine.

### Running

```bash
cd casim-csce614/zsim
./run_mockingjay.sh mcf               # one benchmark
./run_mockingjay.sh spec              # all 14 SPEC CPU2006 benchmarks
./run_mockingjay.sh parsec            # all 9 PARSEC benchmarks (8 cores)
./hw4runscript SPEC mcf LRU           # baseline policies
```

Stats are written to `outputs/Mockingjay/<benchmark>/zsim.out`. PARSEC folders end in
`_8c_simlarge`.

To use Mockingjay in your own config, set the LLC's replacement policy:

```
l3 = {
    ...
    array = { type = "SetAssoc"; hash = "H3"; ways = 16; };
    repl  = { type = "Mockingjay"; };
    nonInclusiveHack = true;   # single-core: lets the LLC accept PUTs for bypassed lines
};
```

## Known limitations

- **BBL-granularity PC.** Every load and store in a basic block shares one signature, so the predictor can't tell them apart as well as it could with exact per-instruction PCs.
- **Bypass on multi-core.** Bypassed lines reach L2 without the LLC directory recording L2 as a sharer. A later `PUTS` from that L2 can break the MESI sharer invariant. Single-core runs with `nonInclusiveHack = true` handle this correctly. See [docs/bypass-parsec.md](docs/bypass-parsec.md).
- **Sampled sets.** ChampSim samples sets by address index. Here the sampler uses raw address bits while the real LLC sets are H3-hashed, so the sampled lines differ from ChampSim's, though the sampled fraction is the same.
- **Multiple LLC banks.** Each bank gets its own policy instance, with separate RDP and sampler state.

## License

zsim is GPLv2, and the patches and `zsim/src` files are derived from it. The original
Mockingjay code in `reference/champsim/` is Apache 2.0 (see its `LICENSE`).
