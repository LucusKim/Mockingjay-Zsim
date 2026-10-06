# Mockingjay Bypass Bug: Why PARSEC Crashed but SPEC Did Not

## Background: What Is Cache Bypass?

Mockingjay predicts how soon each cache line will be reused using **Estimated Time Remaining (ETR)** counters. When a line is predicted to have a very long reuse distance — longer than any line currently in that cache set — inserting it would just kick out a more useful line. These are called **scan** accesses: think of a loop that sweeps through a giant array once and never touches it again.

For these scan lines, Mockingjay uses **bypass**: instead of inserting the line into the LLC at all, it fetches the data directly from memory, hands it to the requesting L2 cache, and skips the LLC entirely. The idea is that a line you'll never reuse has no business taking up a valuable LLC slot.

This bypass is implemented in `shouldBypass()` in `mockingjay_repl.h`. When it returns `true`, ZSim's `cache.cpp` skips the `preinsert/postinsert` step and the LLC slot is never allocated for that line.

---

## Background: MESI Coherence and Sharer Tracking

Modern multi-level caches use a coherence protocol — MESI (Modified, Exclusive, Shared, Invalid) — to keep all cache levels consistent. The LLC (L3) acts as a **directory**: it tracks which L2 caches currently hold a copy of each line. This tracking is done through a **sharer list** (`sharers[childId]`), where each bit represents one L2 cache.

The rules are:
- When an L2 fetches a line from L3, L3 sets `sharers[L2_id] = true`.
- When an L2 evicts a clean line, it sends a **PUTS** notification to L3. L3 checks `assert(sharers[L2_id])` — "I should know about you holding this line" — then clears the bit.
- If L3 wants to evict a line that L2 is holding, it first sends an **INV** (invalidate) down to L2. L2 transitions to Invalid state and stops holding the line.

This contract is strict: **if L2 holds a line, L3 must know about it.** Violating this causes a crash.

---

## The Bug: Bypass Breaks the Coherence Contract

When `shouldBypass()` returns `true` for a GETS request, ZSim skips the LLC insertion. But here is the critical problem: **ZSim still serves the data to L2.** The line reaches L2 via a special `processAccessBypass()` path in the coherence controller that fetches directly from memory — without going through the LLC's normal `MESITopCC::processAccess()` step that would register L2 as a sharer.

The result:
- **L2 has the line** (in Exclusive or Shared state).
- **L3 has no record of L2 holding it** (`sharers[L2_id] = false`).

This is a ticking time bomb. Eventually, L2 will evict the line and send a PUTS to L3. L3 looks up the line, finds an entry (because another core may have inserted it normally in the meantime), and then hits:

```
assert(e->sharers[childId])   ← coherence_ctrls.cpp:288
```

with `sharers[childId] = 0`. **Crash.** Signal 11 (segfault via Pin).

---

## Why SPEC (Single-Core) Worked Fine

For the SPEC CPU2006 benchmarks, each simulation uses **1 core** and therefore **1 L2 cache**. When L2 bypasses a line and later evicts it:

1. L2 sends PUTS to L3.
2. L3 looks up the line. Since bypass never inserted it, the lookup returns `lineId = -1` (not found).
3. The config has `nonInclusiveHack = true`, which tells ZSim: *"it's OK to receive a PUTS for a line I don't have — just silently discard it."*

```cpp
// coherence_ctrls.h
if (lineId == -1 || (IsPut(req.type) && !bcc->isValid(lineId))) {
    assert(nonInclusiveHack);   // passes because nonInclusiveHack = true
    bcc->processNonInclusiveWriteback(...);  // silently handled
}
```

**The crash assertion is never reached** because `lineId = -1` takes the `nonInclusiveHack` exit before getting to the sharer check.

With a single L2, there is no other core that could independently insert the same bypassed line into L3. The bypassed line simply does not exist in L3 when L2 evicts it, so the lookup always returns `-1` and the safe path is taken every time.

---

## Why PARSEC (8-Core) Crashed

PARSEC benchmarks run with **8 cores** and **8 L2 caches**, all sharing the same L3. This introduces a scenario that cannot happen with a single core:

**The timeline that causes the crash:**

```
1. Core 0's L2 (L2-0) requests line X from L3.
   → shouldBypass() returns true.
   → processAccessBypass() serves X to L2-0 directly from memory.
   → L3 does NOT record L2-0 as a sharer of X.
   → L2-0 now holds X. L3 has no idea.

2. Core 1's L2 (L2-1) also requests line X from L3.
   → shouldBypass() returns false this time (ETR values differ).
   → Normal path: L3 installs X, sets sharers[1] = true.
   → L3 now has X with sharers = { 0:false, 1:true }.

3. L2-0 evicts X (needs the slot for something else).
   → L2-0 sends PUTS to L3 for line X.
   → L3 looks up X → finds it (lineId ≠ -1, installed in step 2).
   → L3 calls MESITopCC::processAccess(PUTS, lineId, childId=0)
   → assert(e->sharers[0])   ← sharers[0] = false → CRASH
```

With multiple cores accessing overlapping data, the same line can be bypassed by one core and normally fetched by another. Once any core installs the line in L3, the `lineId = -1` safety net no longer applies — the line IS in L3, but the bypassing core was never registered as a sharer. When that core's L2 evicts it, the sharer assertion fires.

---

## The Other Half of the Bug: `numCPUS` Was Always 0

The code attempted to guard against this with:

```cpp
bool shouldBypass(const MemReq* req) {
    if (numCPUS > 1) return false;  // intended to disable bypass for multi-core
    ...
}
```

where `numCPUS` is set in the constructor:

```cpp
MockingjayReplPolicy(..., uint32_t _numCPUS) {
    numCPUS = _numCPUS;  // passed as zinfo->numCores
}
```

**This guard never worked.** In ZSim's initialization sequence, caches are built at line 498 of `init.cpp` — but `zinfo->numCores` is not computed and stored until line 914:

```
Line 498:  BuildCacheGroup() → BuildCacheBank()
                → new MockingjayReplPolicy(..., zinfo->numCores)
                                               ↑ = 0 here (not set yet)
...
Line 914:  zinfo->numCores = numCores;  ← too late, constructor already ran
```

`zinfo` is zero-initialized, so `zinfo->numCores = 0` at the time every `MockingjayReplPolicy` is constructed — for both single-core SPEC and 8-core PARSEC. The stored `numCPUS` is always `0`.

- `0 > 1` is `false` → the bypass guard **never** fires.
- `0 == 1` is `false` → the single-core ETR path (`etr = 0`) **never** fires either.

The guard was silently broken from the start.

---

## The Fix

Since `zinfo->numCores` is `0` at construction time but correctly set to the actual core count by the time any simulation instruction runs, the solution is to read it **at call time** instead of storing it at construction time:

```cpp
bool shouldBypass(const MemReq* req) {
    if (zinfo->numCores > 1) return false;  // disable bypass for multi-core
    if (!IsPut(req->type)) {
        // ... existing bypass logic unchanged ...
    }
    return false;
}
```

`shouldBypass` is called during simulation (inside `Cache::access`), long after `zinfo->numCores` has been correctly populated. Reading it directly at that point gives the real core count.

**Result:**
- **Single-core SPEC**: `zinfo->numCores = 1`, guard does not fire, bypass remains active → SPEC results unchanged.
- **8-core PARSEC**: `zinfo->numCores = 8 > 1`, guard fires, bypass disabled → PARSEC simulations run correctly.

For multi-core PARSEC, scan lines are still handled efficiently: `update()` assigns them `etr = INF_ETR`, making them the highest-priority eviction candidate in `rank()`. They get evicted on the very next replacement in their set, achieving most of the pollution-avoidance benefit of bypass without violating the MESI coherence contract.









---

## Why the `zinfo->numCores` Fix May Have Failed

The `zinfo->numCores > 1` guard was applied and appeared to be compiled into the binary (source modified at 19:21, `init.os` compiled at 19:22, `libzsim.so` linked at 19:33), yet PARSEC blackscholes still crashed with the identical assertion. Below are all plausible reasons this fix did not work, along with how each could be confirmed and fixed.

---

### Reason 1: Build artifact not actually recompiled (most likely)

**What could happen:** scons uses an internal `.sconsign` database of file signatures (MD5 checksums, not just timestamps). If the database believed `init.cpp` was already up-to-date relative to `mockingjay_repl.h`, it would skip recompilation even if the file timestamp changed — for example, if the header was `touch`ed or had a non-content change that left the MD5 unchanged.

**How to confirm:** Run `scons -j4` again and watch whether `init.cpp` is listed as being compiled. If scons says "up to date" and skips it, the old `.os` is stale.

**Fix:** Force a clean rebuild:
```bash
scons -c && scons -j4
```
Or delete the specific object file and relink:
```bash
rm build/opt/init.os && scons -j4
```

---

### Reason 2: Fix was applied after the build, not before

**What could happen:** The file modification timestamp (19:21) and the `init.os` compilation timestamp (19:22) are 1 minute apart. If the build ran first and the fix was applied within the same minute window, the timestamps would appear to show the fix came first even if it came second. Sub-minute ordering is ambiguous from `ls -la` alone.

**How to confirm:** Check if the currently running binary's `shouldBypass` actually contains the guard. One way is to `strings` the binary and grep for a string literal near the guard, or add a temporary `info(...)` print and see if it appears in the log.

**Fix:** Apply the fix, then do a clean rebuild to be certain.

---

### Reason 3: `zinfo` pointer not correctly initialized in the Pin target process

**What could happen:** ZSim uses Pin to inject `libzsim.so` into the target process (the PARSEC benchmark). Inside that process, `zinfo` is set via:
```cpp
// zsim.cpp:1467
zinfo = static_cast<GlobSimInfo*>(gm_get_glob_ptr());
```
This runs after `gm_isready()` confirms shared memory is set up. However, if there is any code path where `shouldBypass` is called before `zinfo` is fully initialized in the target process — for example, during a warmup or instrumentation setup phase — `zinfo` could be null or point to zero-initialized memory, making `zinfo->numCores` read as 0.

**How to confirm:** Add a null check and log:
```cpp
if (!zinfo || zinfo->numCores > 1) return false;
```
If a segfault appears on a null `zinfo` dereference, this is the cause.

**Fix:** Add the null guard, or ensure `shouldBypass` cannot be called before `zinfo` is initialized by checking `gm_isready()` first.

---

### Reason 4: Multiple `MockingjayReplPolicy` instances, one without the fix

**What could happen:** The PARSEC config uses 8 L3 banks (`banks = 8`). Each bank is a separate `Cache` object with its own `MockingjayReplPolicy` instance. All 8 are constructed from the same `BuildCacheGroup` call and all receive the same `hf` and `zinfo->numCores` arguments. However, if there is a second construction site (e.g., a different config or cache level using Mockingjay that was missed), that instance would use the unfixed code.

**How to confirm:** Search for all `MockingjayReplPolicy` constructor calls:
```bash
grep -rn "MockingjayReplPolicy" src/
```
There should be exactly one call site in `init.cpp`.

**Fix:** Ensure there is only one construction site and it passes the correct arguments.

---

### Reason 5: The `!IsPut` condition accidentally allows bypass for some request type

**What could happen:** `IsPut(t)` returns true only for `PUTS` and `PUTX`. All other access types (`GETS`, `GETX`) fall into the `!IsPut` branch where the multi-core guard runs. This is correct. However, if ZSim internally generates a custom access type or prefetch request that is neither a GET nor a PUT, `IsPut` would return false, the guard would need to fire, and if `zinfo->numCores` somehow read incorrectly, bypass could trigger.

**How to confirm:** Add a log line at bypass entry:
```cpp
bool shouldBypass(const MemReq* req) {
    if (!IsPut(req->type)) {
        info("[bypass] numCores=%d type=%s", zinfo->numCores, AccessTypeName(req->type));
        if (zinfo->numCores > 1) return false;
        ...
    }
}
```

**Fix:** If an unexpected type is seen, add it to the `IsPut` guard explicitly.

---

### Reason 6: Race condition — bypass fires before `zinfo->numCores` is set

**What could happen:** ZSim sets `zinfo->numCores` at init.cpp:914, inside the main initialization function `SimInit`. If any simulation thread begins executing cache accesses before `SimInit` completes setting up `numCores`, the guard `zinfo->numCores > 1` would see 0 and bypass would fire. This is a narrow but non-zero window in the multi-threaded startup sequence.

**How to confirm:** Add `assert(zinfo->numCores > 0)` at the top of `shouldBypass` and see if it fires.

**Fix:** Use a stored flag rather than reading `zinfo->numCores` at call time. Set the flag in `update()` on the first call (which also happens during simulation, but is a cleaner point):
```cpp
virtual void update(uint32_t id, const MemReq* req) {
    if (numCPUS == 0) numCPUS = zinfo->numCores; // lazy init
    ...
}
bool shouldBypass(const MemReq* req) {
    if (numCPUS > 1) return false; // uses lazily-initialized value
    ...
}
```
Since `update()` is always called on every cache access before replacement decisions are needed, `numCPUS` will be correctly populated by the time any serious bypass decision is made.

---

### Reason 7: H3 hash fix interacted with the bypass fix unexpectedly

**What could happen:** Both fixes were applied together to `mockingjay_repl.h` before the final build. The H3 hash fix added `hf` as a constructor parameter. If the `init.cpp` change (passing `hf`) was not compiled in — for instance, if `init.cpp`'s object file was stale for a different reason — then the constructor would receive `hf = nullptr` (the default argument). This would not affect the multi-core guard, but it is a latent inconsistency that could cause confusing behavior.

**How to confirm:** Check `init.os` timestamp vs `init.cpp` timestamp. Both should be the same or `init.os` should be newer.

**Fix:** Clean rebuild as in Reason 1.

---

## Recommended Path to Re-Enable Bypass Correctly

If you want to restore bypass for single-core SPEC after PARSEC is working:

1. **Lazy-initialize `numCPUS`** in `update()` (Reason 6 fix) — this is the most robust approach and avoids all timing issues with `zinfo->numCores`.

2. **Use `numCPUS` in `shouldBypass`** instead of `zinfo->numCores` — once lazily initialized, `numCPUS` is reliable.

3. **Fix the H3 hash set computation** — the existing commented-out code already has this: `hf ? hf->hash(0, req->lineAddr) & (numSets - 1) : (req->lineAddr >> 0) & (numSets - 1)`.

4. **Do a clean rebuild** (`scons -c && scons -j4`) after every change to ensure stale objects are not used.

5. **Verify with a short test run** of a single PARSEC benchmark before running all 23.

---

A Different claude session identified this bug:

Root cause identified: H3 hash set mismatch in shouldBypass

The LLC uses H3 hashing, so a line at lineAddr maps to set hf->hash(0, lineAddr) & (numSets-1) — not lineAddr & (numSets-1). But shouldBypass uses the raw low bits to index into the ETR array, reading values from the wrong set entirely. The update and rank functions use the correct hashed set (via id / numWays).

Effect on your results vs the paper:

Benchmark	Your IPC Δ	Paper Δ	Your MPKI drop
soplex	-7.27%	+16%	20.83 → 6.51
lbm	-1.32%	+15%	30.95 → 10.05
mcf	+20%	~1-2%	80.91 → 6.39
GeoMean	+1.97%	~5.6%	—
The paradox (MPKI drops but IPC decreases) is the bypass bug fingerprint — it's incorrectly bypassing useful lines, causing repeated DRAM pressure that doesn't show up in L3 miss counts.

The fix is 5 targeted changes: pass HashFamily* hf to the constructor and use hf->hash(0, req->lineAddr) & (numSets-1) in shouldBypass. Just let me know when to apply it.

I found the bug. The LLC uses H3 hashing (hash = "H3"), meaning the actual cache set for a line is hf->hash(0, lineAddr) & (numSets-1), not lineAddr & (numSets-1). In shouldBypass, you compute the set with raw low bits, so you're reading ETR values from the wrong set — causing completely wrong bypass decisions that hurt soplex (-7.27%) and lbm (-1.32%) despite their MPKI dropping.

The fix: pass the hash family into MockingjayReplPolicy and use it in shouldBypass.