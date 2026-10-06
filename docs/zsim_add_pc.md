# zsim: Adding PC to Replacement Policies

All changes needed to expose `req->pc` inside any zsim replacement policy.

---

## `src/memory_hierarchy.h`

Add `uint64_t pc` to the end of `struct MemReq`. Placing it last means every
existing aggregate initializer elsewhere (coherence controllers, prefetcher,
trace driver) zero-initializes it automatically — no edits needed in those files.

```diff
     uint32_t flags;

+    // PC of the instruction that triggered this access.
+    // Set by FilterCache from the core's current BBL address; 0 for internal cache ops.
+    uint64_t pc;
+
     inline void set(Flag f) {flags |= f;}
     inline bool is (Flag f) const {return flags & f;}
 };
```

---

## `src/filter_cache.h`

Three additions. `FilterCache` is the L1 shim every core talks to; `replace()`
is the only place a `MemReq` is built from a real core request and fired up the
hierarchy.

**1 — New private member**

```diff
         lock_t filterLock;
         uint64_t fGETSHit, fGETXHit;
+        Address curPc;
```

**2 — Initialize in constructor, add `setPc()` public method**

```diff
             fGETSHit = fGETXHit = 0;
             srcId = -1;
             reqFlags = 0;
+            curPc = 0;
         }

         void setFlags(uint32_t flags) {
             reqFlags = flags;
         }

+        void setPc(Address pc) {
+            curPc = pc;
+        }
+
```

**3 — Pass `curPc` into the `MemReq` in `replace()`**

```diff
-            MemReq req = {pLineAddr, isLoad? GETS : GETX, 0, &dummyState, curCycle, &filterLock, dummyState, srcId, reqFlags};
+            MemReq req = {pLineAddr, isLoad? GETS : GETX, 0, &dummyState, curCycle, &filterLock, dummyState, srcId, reqFlags, curPc};
```

---

## `src/simple_core.cpp`

Set the PC at the top of `bbl()`. The BBL callback fires before the memory
access callbacks for the instructions within it, so `curPc` is always set
before any `replace()` is triggered.

```diff
 void SimpleCore::bbl(Address bblAddr, BblInfo* bblInfo) {
+    l1d->setPc(bblAddr);
     //info("BBL %s %p", name.c_str(), bblInfo);
```

---

## `src/timing_core.cpp`

Same pattern as `SimpleCore`.

```diff
 void TimingCore::bblAndRecord(Address bblAddr, BblInfo* bblInfo) {
+    l1d->setPc(bblAddr);
     instrs += bblInfo->instrs;
```

---

## `src/ooo_core.h`

Add `prevBblAddr` alongside `prevBbl`. OOO simulates the *previous* BBL's
memory accesses when processing the *next* BBL's callback, so we need to carry
the address one step behind.

```diff
         BblInfo* prevBbl;
+        Address prevBblAddr; // address of the BBL currently being simulated (set one BBL behind)
```

---

## `src/ooo_core.cpp`

Four edits.

**1 — Initialize in constructor**

```diff
     prevBbl = nullptr;
+    prevBblAddr = 0;
```

**2 — Store address on the first-BBL early-return path**

```diff
     if (!prevBbl) {
         prevBbl = bblInfo;
+        prevBblAddr = bblAddr;
         loads = stores = 0;
         return;
     }
```

**3 — Set PC before replaying data accesses; advance `prevBblAddr`**

```diff
     /* Simulate execution of previous BBL */

+    // Set PC on L1D so replacement policy can see which BBL's loads/stores these are
+    l1d->setPc(prevBblAddr);
+
     uint32_t bblInstrs = prevBbl->instrs;
     DynBbl* bbl = &(prevBbl->oooBbl[0]);
     prevBbl = bblInfo;
+    prevBblAddr = bblAddr;
```

**4 — Set PC before the instruction fetch loop**

```diff
     // Simulate current bbl ifetch
+    l1i->setPc(bblAddr);
     Address endAddr = bblAddr + bblInfo->bytes;
     for (Address fetchAddr = bblAddr; fetchAddr < endAddr; fetchAddr += lineSize) {
```

The ifetch loop uses `bblAddr` (the *current* BBL being fetched), which is
different from `prevBblAddr` used for data accesses above.

---

## Using `pc` in a replacement policy

```cpp
void update(uint32_t id, const MemReq* req) override {
    uint64_t pc = req->pc;  // BBL start address; 0 for internal cache ops
    ...
}

uint32_t rankCands(const MemReq* req, SetAssocCands cands) override {
    uint64_t pc = req->pc;
    ...
}
```

`pc` is `0` for writebacks (PUTS/PUTX from coherence controllers), prefetcher
requests, and trace-driven accesses. Guard with `if (req->pc != 0)` if needed.

**Granularity note**: `pc` is the BBL *start* address, not the per-instruction
PC. This is almost always sufficient for replacement policy use. Per-instruction
PC would require threading a `pc` argument through every PIN analysis callback
and every core load/store path.

---

## Files NOT changed

| File | Reason |
|------|--------|
| `src/coherence_ctrls.cpp` | Existing initializers have 9 fields; `pc` zero-initializes as the 10th |
| `src/prefetcher.cpp` | Same |
| `src/trace_driver.cpp` | Same |
| `src/repl_policies.h` | Already receives `const MemReq* req`; `req->pc` just works |
| `src/cache.h` / `cache.cpp` | Pass-through; no `MemReq` construction |
| `src/cache_arrays.h` / `cache_arrays.cpp` | Pass-through; no `MemReq` construction |
