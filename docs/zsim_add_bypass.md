# zsim: Adding Bypass to Replacement Policies

Cache bypass lets a replacement policy decide, on a miss, that a line should
be fetched from the next level but **not installed** in the cache. This is
useful for policies like Mockingjay that track reuse distance per PC: if a
load's PC signature predicts the line will not be reused before eviction, it
is cheaper to skip the allocation entirely rather than pollute the cache and
evict a potentially useful line.

---

## Background: the miss path in `cache.cpp`

```
Cache::access(MemReq& req)
  │
  ├─ array->lookup()          → lineId == -1 means miss
  │
  └─ if (miss && shouldAllocate)
       ├─ array->preinsert()  → pick victim, get wbLineAddr
       ├─ cc->processEviction()
       └─ array->postinsert() → install new line
```

Bypass hooks in right at the `if` condition. A bypassed request skips the
three allocation steps but continues to `cc->processAccess()`, which fetches
the data from the next level — the core still gets its data, it just never
occupies a cache line.

---

## Files changed

### `src/repl_policies.h`

Add `shouldBypass()` to the `ReplPolicy` base class with a default that
returns `false`. Every existing policy inherits the no-op default, so nothing
breaks.

```diff
         virtual void initStats(AggregateStat* parent) {}
+
+        virtual bool shouldBypass(const MemReq* req) { return false; }
 };
```

Full context around the change:

```cpp
class ReplPolicy : public GlobAlloc {
    protected:
        CC* cc;

    public:
        ReplPolicy() : cc(nullptr) {}

        virtual void setCC(CC* _cc) {cc = _cc;}

        virtual void update(uint32_t id, const MemReq* req) = 0;
        virtual void replaced(uint32_t id) = 0;

        virtual uint32_t rankCands(const MemReq* req, SetAssocCands cands) = 0;
        virtual uint32_t rankCands(const MemReq* req, ZCands cands) = 0;

        virtual void initStats(AggregateStat* parent) {}

        virtual bool shouldBypass(const MemReq* req) { return false; }  // <-- added
};
```

---

### `src/cache.cpp`

Add `&& !rp->shouldBypass(&req)` to the miss-allocation condition inside
`Cache::access()`.

```diff
-        if (lineId == -1 && cc->shouldAllocate(req)) {
+        if (lineId == -1 && cc->shouldAllocate(req) && !rp->shouldBypass(&req)) {
```

Full context around the change:

```cpp
uint64_t Cache::access(MemReq& req) {
    uint64_t respCycle = req.cycle;
    bool skipAccess = cc->startAccess(req);
    if (likely(!skipAccess)) {
        bool updateReplacement = (req.type == GETS) || (req.type == GETX);
        int32_t lineId = array->lookup(req.lineAddr, &req, updateReplacement);
        respCycle += accLat;

        if (lineId == -1 && cc->shouldAllocate(req) && !rp->shouldBypass(&req)) {  // <-- modified
            //Make space for new line
            Address wbLineAddr;
            lineId = array->preinsert(req.lineAddr, &req, &wbLineAddr);
            trace(Cache, "[%s] Evicting 0x%lx", name.c_str(), wbLineAddr);

            cc->processEviction(req, wbLineAddr, lineId, respCycle);

            array->postinsert(req.lineAddr, &req, lineId);
        }
        ...
        respCycle = cc->processAccess(req, lineId, respCycle);  // still runs; data is fetched
    }
    ...
}
```

When bypassed, `lineId` stays `-1`. `cc->processAccess()` still runs with
`lineId == -1`. However, the MESI coherence controller treats `lineId == -1`
as a non-inclusive writeback path, which asserts `req.type == PUTS || PUTX`.
This crashes on a bypassed GETS/GETX. See the `coherence_ctrls.h` and
`coherence_ctrls.cpp` sections below for the required fix.

---

### `src/coherence_ctrls.h`

Two changes needed. `MESICC::processAccess` treats any `lineId == -1` as a
non-inclusive writeback and asserts the request is a PUT. Bypass produces
`lineId == -1` on a GET, which triggers that assert and crashes. The fix is to
intercept the bypass case before the writeback check and route it through a new
`processAccessBypass` method.

**1 — Add `processAccessBypass` declaration to `MESIBottomCC`**

```diff
         uint64_t processNonInclusiveWriteback(Address lineAddr, AccessType type,
                                               uint64_t cycle, MESIState* state,
                                               uint32_t srcId, uint32_t flags);
+
+        uint64_t processAccessBypass(Address lineAddr, AccessType type,
+                                     uint64_t cycle, MESIState* state,
+                                     uint32_t srcId, uint32_t flags);
```

**2 — Intercept bypass in `MESICC::processAccess` before the non-inclusive-writeback check**

```diff
+        // Bypass: lineId==-1 on a GET means the replacement policy intentionally
+        // skipped allocation. Fetch from the next level without installing here.
+        if (lineId == -1 && IsGet(req.type)) {
+            respCycle = bcc->processAccessBypass(req.lineAddr, req.type, startCycle,
+                                                 req.state, req.srcId, req.flags);
+            return respCycle;
+        }
         if (lineId == -1 || (((req.type == PUTS) || (req.type == PUTX))
                               && !bcc->isValid(lineId))) {
             assert(nonInclusiveHack);
             assert((req.type == PUTS) || (req.type == PUTX));
```

---

### `src/coherence_ctrls.cpp`

Implement `processAccessBypass`. It fetches from the parent using a throwaway
local MESI state (starting at `I`), adding the normal network RTT latency.
No entry in `array[]` is touched because there is no `lineId`.

```cpp
uint64_t MESIBottomCC::processAccessBypass(Address lineAddr, AccessType type,
                                           uint64_t cycle, MESIState* state,
                                           uint32_t srcId, uint32_t flags) {
    assert(IsGet(type));
    // Pass the caller's state pointer through so that the parent (e.g. DDR)
    // can update it to S or E. The lower cache level needs to see the final
    // state after the fetch — do NOT use a local dummy here, or the lower
    // level's post-access assert (*state == S || E) will fire.
    uint32_t parentId = getParentId(lineAddr);
    MemReq req = {lineAddr, type, selfId, state, cycle, &ccLock,
                  *state, srcId, flags};
    uint32_t nextLevelLat = parents[parentId]->access(req) - cycle;
    uint32_t netLat = parentRTTs[parentId];
    return cycle + nextLevelLat + netLat;
}
```

Place this definition immediately before `processNonInclusiveWriteback`.

**Why not a dummy state?** The lower cache (e.g. L2) passes its own state pointer
(`&array[lineId_L2]`) up through the hierarchy. After calling the parent, it
asserts `*state == S || E` to confirm the fetch succeeded. Using a throwaway
local state breaks that: DDR updates the dummy, not `array[lineId_L2]`, so
L2 still sees `I` and crashes. Passing `state` through lets DDR update the
correct entry directly.

---

### `src/timing_event.h`

A second crash can occur in the weave-phase contention simulation after the
fast-forward → simulation transition. `DDRMemoryAccEvent` has its
`minStartCycle` set to `req.cycle` from the bound phase, but the weave phase
can schedule the event at an earlier cycle (the two phases do not need to
agree exactly). The original code asserted `startCycle >= minStartCycle` and
crashed; the fix clamps instead.

```diff
-        assert_msg(startCycle >= minStartCycle,
-                   "startCycle %ld < minStartCycle %ld (%s), ...",
-                   startCycle, minStartCycle, typeid(*this).name(), ...);
-        simulate(startCycle);
+        // Clamp to minStartCycle: the weave-phase contention sim can schedule
+        // an event earlier than the bound-phase req.cycle (e.g. DDRMemoryAccEvent
+        // whose minStartCycle was set from req.cycle). Clamping is correct —
+        // we simply delay the event to its earliest legal start time.
+        if (startCycle < minStartCycle) startCycle = minStartCycle;
+        simulate(startCycle);
```

This is inside `TimingEvent::run()` in `coherence_ctrls.h`. The bound/weave
desync is more likely to surface with bypass because bypass removes the
eviction writeback timing events that normally anchor the weave-phase cycle
close to the bound-phase cycle.

---

## Implementing bypass in your policy

Override `shouldBypass()` in your replacement policy class. The example below
is for a Mockingjay-style policy that tracks reuse distance per PC signature:

```cpp
bool shouldBypass(const MemReq* req) override {
    if (req == nullptr || req->pc == 0) return false;
    uint64_t pc_signature = get_pc_signature(req->pc, false, req->srcId);
    if (rdp.count(pc_signature) && rdp[pc_signature] > MAX_RD) {
        return true;
    }
    return false;
}
```

**`req->pc == 0` guard**: internal cache operations (writebacks from coherence
controllers, prefetches, trace-driven accesses) have `pc == 0`. Always guard
against this — bypassing a writeback would be incorrect.

**`req->srcId`**: identifies the thread/core, useful for per-core PC signature
hashing in multi-core setups.

**`MAX_RD`**: your threshold for "this line will not be reused." Lines whose
predicted reuse distance exceeds the cache capacity are good bypass candidates.

---

## What bypass does and does not affect

|              | Bypassed miss | Normal miss |
|---|---|---|
| `array->preinsert()` | skipped | runs |
| `array->postinsert()` | skipped | runs |
| `cc->processEviction()` | skipped | runs |
| `cc->processAccess()` | runs via `processAccessBypass` (`lineId == -1`) | runs normally |
| Data returned to core | yes (fetched from next level) | yes |
| Line installed in cache | no | yes |
| Existing lines evicted | no | yes (one victim chosen) |
| `update()` called on hit | n/a (it's a miss) | n/a |

Because no eviction occurs, bypassing a line can also prevent a useful
resident line from being displaced — which is the main performance benefit.

---

## Files changed (summary)

| File | What changed |
|------|-------------|
| `src/repl_policies.h` | Added `shouldBypass()` virtual with default `return false` |
| `src/cache.cpp` | Added `&& !rp->shouldBypass(&req)` to miss-allocation guard |
| `src/coherence_ctrls.h` | Added `processAccessBypass` declaration; bypass intercept in `MESICC::processAccess` |
| `src/coherence_ctrls.cpp` | Implemented `processAccessBypass` |
| `src/timing_event.h` | Replaced `assert_msg(startCycle >= minStartCycle)` with a clamp |

## Files NOT changed

| File | Reason |
|------|--------|
| `src/cache.h` | `rp` member already exists; no interface change needed |
| `src/cache_arrays.h` / `cache_arrays.cpp` | Not involved in the allocation decision |
| All other existing `ReplPolicy` subclasses | Inherit `shouldBypass() { return false; }` from base |
