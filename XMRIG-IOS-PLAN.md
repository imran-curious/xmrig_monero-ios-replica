# Bare-metal Monero miner for iOS 26.5.1 — build plan and build log

> **Status: built, installed, and mining.** Measured **~3000 H/s** on a 6-core iPhone,
> 12 GB RAM, iOS 26.5.1 (23F81), 2 threads, fast mode — against ~400 H/s on the
> interpreter. Confirmed on-device 2026-09-17.
>
> This document was written *before* the build. Sections that the build proved wrong have
> been corrected in place and marked as such rather than quietly deleted — **Part 3 was
> substantially wrong** and is the most useful part of the record. Everything from Part 9
> onward now reports outcomes instead of estimates.

**Toolchain (fixed by you):** `xtool` under WSL for building and signing · `iLoader` + `SideStore` + `StikDebug` for installation and JIT on iPhone, iOS **26.5.1**.
**Goal:** bare-metal miner — native arm64 hashing, no React Native, no JS bridge, no wrapper app around someone else's binary.

Subject that prompted this: `D:\projects\miner_setup\phone\xmrig-for-android-v0.1.3-release.apk` (v0.1.3)
Source tree: `D:\projects\miner_setup\phone\xmrig-for-android-main\` (upstream v0.1.4, MIT, Garry Lachman)
Researched: 2026-09-17 · Built and corrected: 2026-09-17

---
---

## Part 1 — There is nothing to download; this has to be built

| Check | Result |
|---|---|
| App Store, on-device miners | Banned by policy (see below). |
| Upstream XMRig official binaries | Windows, Linux, macOS, FreeBSD. **No iOS.** |
| `XMRig-for-Android` project | Android only. Its `ios/` folder is dead scaffolding — see 1.2. |
| XMRig Multi (Android+iOS+desktop, announced 2026-09-05) | **Repo is gone.** Both published URLs 404 today. |
| mxmrig.com | Domain does not resolve (`ENOTFOUND`). |
| `Crypto Miner for Monero XMR` (App Store id1320235885) | Live listing, **last updated 22 Dec 2017** — six months before Apple's mining ban. Reviews report it does not work. Dead. |

### 1.1 The App Store is permanently closed to this

> **3.1.5(b)(ii) Mining:** Apps may not mine for cryptocurrencies unless the processing is performed off device (e.g. cloud-based mining).

> **2.4.2** ... Apps should not rapidly drain battery, generate excessive heat, or put unnecessary strain on device resources. ... Apps, including any third-party advertisements displayed within them, may not run unrelated background processes, such as cryptocurrency mining.

Irrelevant to your plan — SideStore never touches review — but it is why no prebuilt IPA exists and why one never will.

### 1.2 The `ios/` folder in your source tree is a trap

```
xmrig-for-android-main/ios/
  Pods/                        (DoubleConversion, boost-for-react-native only)
  ReactNativeXMRig.xcodeproj/
  ReactNativeXMRig.xcworkspace/
  ReactNativeXMRigTests/
```

No `ios/ReactNativeXMRig/` app folder — no `AppDelegate`, no `Info.plist`, no `main.m`, no `Podfile`. Scheme user data belongs to `garrylachman`. An abandoned skeleton inherited from the ancestor project `react-native-xmrig`. It will not open, `pod install`, or build. **Treat as zero prior work.** Delete it rather than trying to repair it.

### 1.3 TrollStore is off the table

TrollStore tops out well below iOS 26. On **26.5.1** your only route to executable memory is a debugger attachment, i.e. StikDebug. That single fact drives most of the design below.

---
---

## Part 2 — What the toolchain choice forces

### 2.1 xtool means SwiftPM, not CMake

xtool's whole model is: **build a SwiftPM package into an iOS `.app`**. There is no Xcode project, no CMake integration, no `xcodebuild`. This is the most important constraint in the document, because xmrig is a CMake project that hard-depends on **libuv** (event loop, networking) and optionally OpenSSL.

Cross-compiling libuv to `arm64-apple-ios` from WSL, without CMake's Apple-platform support and without `xcrun`, is the single largest time sink in a naive port — and it buys you a network stack that iOS already gives you for free in `Network.framework`.

**So: do not port xmrig.** Port only the part that actually hashes.

### 2.2 Bare metal = RandomX core + Swift stratum

Split the miner the way it should have been split:

| Layer | Implementation | Why |
|---|---|---|
| Hashing | **tevador/RandomX** compiled as a SwiftPM C/C++ target | Zero external dependencies. Pure computation. This is the only part that must be native. |
| Pool protocol | Swift over `Network.framework` (`NWConnection`), newline-delimited JSON-RPC | Replaces libuv entirely. ~200 lines. |
| Threads / governor | Swift, `pthread` QoS + `ProcessInfo.thermalState` | iOS-specific policy that xmrig has no concept of. |
| UI | Minimal SwiftUI — hashrate, shares, JIT state, thermal state | Enough to see what is happening. Nothing more. |

Consequences worth noting: **no donate fee to patch out** (xmrig's 1% never enters the picture), no TLS stack to cross-compile, and total control over JIT initialisation — which is the thing that decides whether this works at all.

Trade-off, stated plainly: you reimplement stratum login/job/submit and keepalive, roughly 400–600 lines across the Swift side. You give up xmrig's algo switching, HTTP API, config profiles and benchmark mode. For a single-algo miner on a phone, that is the right trade.

---
---

## Part 3 — The JIT problem (this section was wrong; corrected after the build)

**What this section originally claimed:** that RandomX's `USE_PTHREAD_JIT_WP` macro is never
defined under SwiftPM, so the portable `mmap` + `mprotect(PROT_EXEC)` path would hand us
executable memory for free under `CS_DEBUGGED` — and therefore **zero modifications to
RandomX**, "the single biggest simplification in this plan."

**That is false on iOS 26.** It was true up to roughly iOS 17. It cost more time than anything
else in this project, so the correction is recorded in full.

### 3.1 Why `mprotect` is not enough on iOS 26

On A15+/M2+ under iOS 26, page permissions are no longer the kernel's to grant. Two monitors
sit outside it:

- **SPTM** (Secure Page Table Monitor) owns every page-table write.
- **TXM** (Trusted Execution Monitor) owns code-signing and entitlement decisions.

`CS_DEBUGGED` is still set when a debugger attaches, and `mprotect(..., PROT_EXEC)` still
**returns 0** — it just does not produce an executable page. The probe passes and the code
faults on first call. That is the trap: a success return that means nothing.

Under iOS 26 the only mechanism that marks a page executable in a third-party process is an
**out-of-process write by an attached debugger**. The process cannot bless its own memory
under any entitlement a free account can obtain.

### 3.2 The debugger arena (`brk #0xf00d`)

StikDebug's `universal.js` installs a `brk` handler. The app requests executable memory by
trapping with arguments in registers:

| `x16` | Request | Arguments |
|---|---|---|
| `0` | Detach | — |
| `1` | Prepare region | `x0` = desired address or `NULL`, `x1` = length. **Returns the RX address in `x0`.** |
| `2` | Inject extra handlers | — |

The region that comes back is **RX only**. To write into it, build a second, writable view of
the *same physical pages* with `vm_remap` + `vm_protect`. `JitCompilerA64` then carries two
pointers:

- `code` — the RW alias, where instructions are emitted
- `codeExec` — the RX address the debugger granted, where they are executed

`getProgramFunc()` returns `codeExec`, and `syncCode(begin, end)` publishes writes made through
`code` to instruction fetch at `codeExec`. This works only because RandomX's generated code is
fully PC-relative — nothing in it holds an absolute address of itself.

Implementation lives in `Sources/CRandomX/jit26_arena.{c,h}`, with `jit_compiler_a64.{cpp,hpp}`
patched for the split views. **So RandomX is modified after all**, in exactly two files.
`scripts/fetch-randomx.sh` now knows this and will not overwrite them.

### 3.3 Arena invariants

Each of these was learned by breaking it:

- **Never unmap a granted region.** Once released it cannot be blessed again; the process is
  stuck on the interpreter until relaunch.
- **A `brk` with no listener kills the process.** Guarded with `sigaction(SIGTRAP)` plus
  `sigsetjmp`/`siglongjmp`, so a missing debugger degrades to the interpreter instead of
  crashing on launch.
- **The debugger attaches *after* launch.** `universal.js` is not in place when `main()` runs,
  so the first request retries for ~40 s before giving up.
- **Do not poison the state on an early failure.** An arena status set before the debugger
  check has run makes the later success invisible to the UI.
- **Executability survives detach.** Once granted, pages stay executable even if the debugger
  goes away — but a cold start must redo the whole handshake.

### 3.4 The JIT probe, corrected

The naive probe in the original plan returns `true` on iOS 26 while delivering nothing. What
the app actually reports is arena state, from `rx_jit_arena_status()`:

| Status | Meaning |
|---|---|
| 0 | Untried |
| 1 | **JIT active** — the arena granted RX pages |
| 2 | No debugger attached (`CS_DEBUGGED` clear) — the app was launched from its icon |
| 3 | Debugger attached but `brk #0xf00d` went unanswered — no JIT script assigned |
| 4 | Debugger answered but granted no region |
| 5 | Region granted but the writable alias could not be built |

Each maps to a line in the event log (`MiningEngine.jitStatusLine()`), so a failure is legible
on screen instead of being inferred from a disappointing hashrate.

**The app must never assume JIT.** The UI gates on it: `Waiting for JIT…` → poll → build the
RandomX VM only once the arena is ready.

**Measured fallback cost — not the estimate this plan originally carried.** The interpreter is
not 3–5 H/s. On this hardware it is **~400 H/s**, against **~3000 H/s** with the arena: a
**7.5x** gap, not 50x. Both figures on a 6-core iPhone, 12 GB RAM, iOS 26.5.1, 2 threads.

Two claims from the original section did hold:

- **Avoid `RANDOMX_FLAG_SECURE`.** With SECURE set, RandomX flips W^X per program, which the
  split-view design cannot support at all.
- **icache flushing is already handled.** `jit_compiler_a64.cpp` calls
  `__builtin___clear_cache()` after emitting code; the patch reroutes those calls through
  `syncCode()` so the flush lands on the executable view.
---

## Part 4 — Project shape

Planned, and what it actually became:

```
ios-replica/
  xtool.yml
  Package.swift
  App.entitlements
  Info.plist
  LICENSE                       # MIT for this project's code
  README.md
  scripts/fetch-randomx.sh      # pulls tevador/RandomX; PRESERVES the files below
  Sources/
    CRandomX/                   # C/C++ target: RandomX + shim + the iOS 26 arena
      include/rx_shim.h         #   the ONLY header Swift sees
      include/randomx.h         #   forwarding shim
      include/module.modulemap
      rx_shim.c
      jit26_arena.c             #   brk #0xf00d handshake + vm_remap alias  <- ours
      jit26_arena.h             #                                          <- ours
      jit_compiler_a64.cpp      #   PATCHED for split RW/RX views          <- ours
      jit_compiler_a64.hpp      #   PATCHED                                <- ours
      LICENSE                   #   tevador, BSD 3-Clause
      <RandomX src/*>
    Miner/                      # Swift
      MoneroMinerApp.swift
      ContentView.swift         #   hashrate, shares, JIT state, thermal, event log
      MiningEngine.swift        #   @MainActor bridge, JIT polling, self-test
      MinerCore.swift           #   thread pool, nonce partitioning, share submit
      RandomXController.swift   #   cache/dataset lifecycle
      JITProbe.swift
      AudioKeeper.swift         #   silent-audio background mode
      Models.swift              #   MiningConfig, LocalMiningStats
```

**The six files marked `<- ours` are why `Sources/CRandomX/` is committed rather than
gitignored, and why the fetch script stages upstream and drops those names before copying.
Re-running the original version of that script silently reverted the JIT.**

**`xtool.yml`** — confirmed key set is `version`, `bundleID`, `infoPath`, `entitlementsPath`, `iconPath`, `resources`:

```yaml
version: 1
bundleID: com.monero.iosminer
deploymentTarget: "17.0"
infoPath: Info.plist
entitlementsPath: App.entitlements
```

`deploymentTarget` is also accepted and is worth setting explicitly.

**Why the C shim.** RandomX's public API takes a C enum (`randomx_flags`) whose import into Swift is awkward to bit-OR. Rather than fight the Clang importer, expose a handful of `uint32_t`-flavoured functions from `rx_shim.h` (`rx_create`, `rx_vm_create`, `rx_hash`, `rx_destroy`) and keep every enum and opaque type on the C side. The shim is also the right home for the **multi-threaded dataset init** — `randomx_init_dataset` must be split across threads by item range or first-start takes minutes.

**Exclusions in `Package.swift`.** RandomX ships x86 and RISC-V backends that will not compile for arm64; exclude them explicitly:
`jit_compiler_x86.cpp`, `jit_compiler_x86_static.S`, `jit_compiler_x86_static.asm`, `assembly_generator_x86.cpp`, `argon2_avx2.c`, `argon2_ssse3.c`, `asm/`, `cpu_rv64.S`, `jit_compiler_rv64*.{cpp,S}`, `aes_hash_rv64_*.cpp`, `tests/`.
Also add `linkerSettings: [.linkedLibrary("c++")]`, and put a one-line forwarding header in `include/` so both `#include "randomx.h"` (internal) and the target's public headers resolve.

**Things to verify on the first build** — and what they turned out to be:

1. `__ARM_FEATURE_CRYPTO` for hardware AES. **Needed the nudge:** `-mcpu=apple-a12` is set in `cxxSettings` alongside `-O3`. Check `randomx_get_flags()` reports `HARD_AES`.
2. Excluding `assembly_generator_x86.cpp` breaking a reference in `randomx.cpp`. **Fine** — the arch guards cover it.
3. Whether the pool's algo is still `rx/0`. **It is.** `RANDOMX_FLAG_V2 = 128` exists but is not in play; still read the algo from the login response rather than hardcoding.

The target also links `c++` and builds as `cxxLanguageStandard: .cxx14`, with `publicHeadersPath: "include"`.

---
---

## Part 5 — The WSL build pipeline

**Prerequisites** (from xtool's own Linux/Windows install doc):

- **Swift 6.3** toolchain for your distro from swift.org.
- **`usbmuxd`** — `sudo apt-get install usbmuxd`; `libimobiledevice-utils` for `ideviceinfo` is worth having.
- **USBIPD** on the Windows side to pass the iPhone through to WSL. If you hit `AFCClient.Error.muxError`, xtool's docs point to a workaround that relays the connection from iTunes on Windows instead.
- **Xcode 26 `.xip`** from developer.apple.com — must be downloaded in a browser (authenticated), not `curl`. xtool extracts it into a Darwin Swift SDK.

```bash
curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
chmod +x xtool && sudo mv xtool /usr/local/bin/
xtool setup          # login (choose "Password" mode for a free Apple ID) + point it at Xcode.xip
swift sdk list       # expect: darwin
```

**Build:**

```bash
xtool new Miner      # generate the template first, then graft in the layout from Part 4
cd Miner
xtool dev build -c release --ipa    # output: ./xtool/MoneroMiner.ipa
```

**`--ipa` does the packaging for you** — the manual `Payload/` + `zip` dance below turned out
to be unnecessary, and hand-zipping is a good way to produce an IPA that installs but will not
launch. Build release, not debug: a debug build of RandomX is not worth measuring.

**Two install routes — you want the second:**

- `xtool dev` builds, signs and installs straight over USB. Best for the edit/run loop while developing.
- For **SideStore**, install the `--ipa` output directly; SideStore re-signs with your own
  certificate. (Only fall back to `mkdir -p Payload && cp -r xtool/Miner.app Payload/ &&
  zip -r Miner.ipa Payload` if you have a bundle and no IPA.)

**Free-account limits that will bite:** 7-day certificate expiry (SideStore refreshes, but it must be able to reach your device), **3 sideloaded apps at a time — per *device*, not per Apple ID** (signing in with a second Apple ID does not buy three more slots; this was tested), 10 App IDs per week. Also note xtool **prefixes your bundle ID** when signing (e.g. `XTL-1234.com.yourname.iosminer`) to avoid free-account collisions — expect the installed bundle ID not to match `xtool.yml` exactly.

---
---

## Part 6 — JIT bring-up on 26.5.1 (as actually performed)

The original three-step version of this section was incomplete, and the step it omitted is the
one that decides whether the miner runs at 400 or 3000 H/s.

**What you need:**

1. **A freshly generated pairing file.** StikDebug 3.1+ on iOS 26.4+ rejects an old one
   *silently*. Regenerate after any iOS update or device reset.
2. **StikDebug 3.1.10 or later**, sideloaded alongside the miner.
3. **`universal.js`**, placed at On My iPhone → StikDebug → scripts (also reachable through
   Settings → App Folder).

**VPN — the original plan was wrong here too.** It listed StosVPN / LocalDevVPN as mandatory.
On this device it was not needed, and an active VPN actively broke the pool connection with
`Network.NWError error 22` (`EINVAL`). Mining only worked with **all VPNs disabled**.

**StikDebug settings:** enable **Silent Audio**, **Background Location**, and **Always Run
Scripts** ("Treats device as TXM-capable to bypass hardware checks"). The footer should read
`Version 3.1.10 • iOS 26.5.1 • TXM (Override)`. Note that 3.1.10 has **no Picture in Picture
toggle**, whatever older guides say.

### 6.1 Assigning the script — the step nothing does for you

StikDebug auto-assigns `universal.js` by matching a **hardcoded list of app display names**
(`AutoScriptAssignments.swift`: Amethyst, MeloNX, XeniOS, MeloCafe, Manic EMU, DukeX, TachyonU,
touchHLE, HyperHLE, Applesauce, RPCS3). **"Monero Miner" is on no list**, so it is assigned
nothing, every `brk #0xf00d` goes unanswered, and the arena reports status 3 — which looks
identical to a working app apart from the hashrate.

Assign it by hand: **Apps tab → long-press the Monero Miner row → "Assign Script" → On My
iPhone → StikDebug → scripts → `universal.js`**. The choice persists in `UserDefaults`
(`bundleScriptMap`) but is lost if StikDebug is reinstalled.

### 6.2 Launching

**Launch the miner from StikDebug → Apps → Monero Miner. Every time.** Tapping the app's own
home-screen icon produces a perfectly functional miner at **400 H/s**, with no error anywhere —
it is simply running the interpreter. This is the single easiest thing to get wrong, and the
symptom (a working app) gives nothing away.

Confirm in the event log: `[jit] JIT ACTIVE via iOS 26 debugger arena (brk #0xf00d granted RX
pages)`.

**Correction to the original claim that "JIT does not survive relaunch":** granted pages stay
executable even after the debugger detaches, so an already-running miner is safe. It is the
*cold start* that needs StikDebug, because the handshake has to happen again.
---

## Part 7 — Runtime policy (this is where the hashrate actually comes from)

### 7.1 Memory: fast mode vs light mode

- **Fast mode** (`RANDOMX_FLAG_FULL_MEM`) needs a **2080 MiB** dataset. Roughly an order of magnitude faster per thread.
- **Light mode** needs 256 MiB but is far slower.
- `RANDOMX_FLAG_LARGE_PAGES` will fail on iOS (`VM_FLAGS_SUPERPAGE_SIZE_2MB` is not available to apps) — do not set it.

Decide at runtime, not at compile time: call **`os_proc_available_memory()`** and pick fast mode only if the remaining budget clears the dataset plus scratchpads plus headroom. Getting this wrong means a jetsam kill, not a graceful failure.

To raise the ceiling, try the **`com.apple.developer.kernel.increased-memory-limit`** entitlement (and possibly `extended-virtual-addressing`) in `App.entitlements`. **Open question to test early:** whether it survives. xtool's docs warn some entitlements do not work with free accounts, and separately, SideStore re-signs the IPA with its own profile — so an entitlement xtool applied may or may not persist through that. If it does not, `xtool dev` over USB may preserve it where SideStore does not. Establish this in Phase 1; the whole fast/light decision hangs on it.

Dataset init is minutes single-threaded — always split `randomx_init_dataset` across all cores by item range.

**Outcome:** the entitlements survived. `increased-memory-limit` and
`extended-virtual-addressing` both held through signing and install, and **fast mode
(2080 MB) runs** on a 12 GB device with no jetsam kill. The fast/light decision is still
made at runtime from `os_proc_available_memory()`, but on this hardware it always lands on
fast. Light mode remains the default until proven, which is the right way round.

### 7.2 Cores: QoS is the only lever

iPhones are big.LITTLE. A thread at default QoS lands on efficiency cores and hashes at a fraction of the rate. Set **`QOS_CLASS_USER_INTERACTIVE`** on every mining thread (`pthread_set_qos_class_self_np`, or `Thread.qualityOfService = .userInteractive`).

There is **no thread affinity** on iOS — `THREAD_AFFINITY_POLICY` is unsupported on arm64, and there is no `sched_setaffinity`. QoS is all you get. (Same shape as the GPU situation in your notes, where the core-clock lock was the only usable control.)

Start at **threads = P-core count** (2 on most A-series), not `activeProcessorCount`. Each RandomX thread wants a 2 MiB scratchpad and they contend for L2; more threads on E-cores can easily be net-negative. Measure rather than assume.

### 7.3 Thermal governor

Subscribe to `ProcessInfo.thermalStateDidChangeNotification` and act on `ProcessInfo.processInfo.thermalState`:

| State | Action |
|---|---|
| `.nominal` | full thread count |
| `.fair` | full |
| `.serious` | drop to 1 thread |
| `.critical` | pause; resume on recovery |

Your own notes already record the Android phone is **skin-temperature-throttle-bound rather than config-bound**. An iPhone's passive envelope is smaller and iOS governs harder, so this is not optional garnish — it is the difference between a sustained rate and a sawtooth.

### 7.4 Staying alive

- **Baseline:** `UIApplication.shared.isIdleTimerDisabled = true`, mine in the foreground with the screen on, plugged in.
- **Optional, screen-off:** declare `UIBackgroundModes: [audio]` in `Info.plist` and hold an `AVAudioSession` playing silence. This is the standard trick for keeping a sideloaded app running with the screen off. Stated honestly: it is an abuse of the background mode, it is only available to you because you are sideloading, and iOS may still throttle or reclaim the process. Treat it as an experiment in a later phase, not as part of the core build.

There is no legitimate background-execution mode for this. Android's foreground service — the thing your APK uses with `WAKE_LOCK` — has no iOS equivalent.

---
---

## Part 8 — Stratum, since you are writing it yourself

Newline-delimited JSON-RPC over plain TCP via `NWConnection`. Use a non-TLS pool port so there is no OpenSSL dependency.

**Login**

```json
{"id":1,"jsonrpc":"2.0","method":"login",
 "params":{"login":"<wallet address>","pass":"<worker name>",
           "agent":"ios-bare/0.1","algo":["rx/0"]}}
```

Response carries `result.id` (the RPC session id used on submits) and `result.job`.

**Job** — `blob` (hex), `job_id`, `target` (hex), `seed_hash`, `height`. Also arrives unsolicited as `{"method":"job","params":{…}}`; always abandon the current job immediately on a new one.

- **Nonce** occupies **bytes 39–42** of the blob, little-endian. Give each thread a disjoint nonce range.
- **`seed_hash` change ⇒ reinitialise the cache** (and dataset). This is the expensive event; handle it as a first-class state transition, not an afterthought.
- **Target decoding:** 8 hex chars is a 32-bit target — `target64 = 0xFFFFFFFFFFFFFFFF / (0xFFFFFFFF / t32)`; 16 hex chars is already a 64-bit LE target.
- **Share test:** interpret the **last 8 bytes** of the 32-byte hash as a little-endian `UInt64` and accept if `<= target64`.

**Submit**

```json
{"id":N,"jsonrpc":"2.0","method":"submit",
 "params":{"id":"<result.id from login>","job_id":"<job_id>",
           "nonce":"<8 hex, LE>","result":"<64 hex>"}}
```

**Pool endpoint, learned the hard way:** `mine.c3pool.org` is dead. Use
**`auto.c3pool.org:80`**. A `posix 22` / `NWError 22` on connect is almost always an active
VPN rather than a pool or code problem — see Part 6. C3Pool's difficulty floor is 15000.

Plus a `keepalived` call every ~60s, and reconnect-with-backoff on drop. Your existing C3Pool wallet address works unchanged — workers are just names, so give this one a distinct worker/rig id so it does not collide with `laptop`.

---
---

## Part 9 — Phases (all complete)

| Phase | Work | Est. | Outcome |
|---|---|---|---|
| 0 | WSL prerequisites, `xtool setup`, hello-world on device | 0.5–1 d | Done. Xcode `.xip` download (~10 GB, browser only) dominated the time. |
| 1 | JIT bring-up + entitlement test | 0.5 d | **Underestimated by a wide margin.** The `mprotect` assumption in Part 3 was wrong and had to be replaced with the debugger arena. Entitlements survived signing and install. |
| 2 | RandomX as a SwiftPM target, validated against official test vectors | 1–2 d | Done, self-test passes for both interpreter and JIT modes. `-mcpu=apple-a12` was needed for hardware AES. |
| 3 | Stratum client, log-only | 1 d | Done. Cost an extra cycle on the dead `mine.c3pool.org` endpoint and the VPN-induced `NWError 22`. |
| 4 | Thread pool, nonce partitioning, first accepted share | 1 d | Done. |
| 5 | Governor: QoS, thermal, fast/light, seed re-init | 1 d | Done. Fast mode confirmed working. |
| 6 | SwiftUI: hashrate, shares, JIT state, thermal, mode | 0.5 d | Done, plus a six-state event log for arena diagnosis (3.4) — which paid for itself immediately. |
| 7 | Measure sustained rate | 0.5 d | 400 H/s interpreter → **3000 H/s** with the arena. |
| 8 | *Optional:* silent-audio background mode | 0.5 d | Implemented (`AudioKeeper.swift`). |

**The estimate was ~7–9 days.** Phase 1 was the one that blew up, exactly as predicted — just
for a different reason than predicted. The risk register called it "JIT unavailable or unstable
on 26.5.1"; the reality was that JIT was available through a mechanism this document did not
know existed.
---

## Part 10 — Risk register, settled

| Risk | Predicted impact | What happened |
|---|---|---|
| JIT unavailable or unstable on 26.5.1 | Everything, ~50x | **Half right.** `mprotect` JIT is genuinely dead on iOS 26 — but the debugger arena works, and the real gap was 7.5x, not 50x. |
| USBIPD/usbmuxd flakiness in WSL | Phase 0, recurring | Manageable. |
| `increased-memory-limit` stripped by SideStore re-signing | Forces light mode, ~10x | **Did not happen.** Entitlements survived; fast mode runs. |
| Jetsam kill on dataset alloc | Crash on start | **Did not happen** on 12 GB. The `os_proc_available_memory()` gate stays in. |
| Algo is no longer `rx/0` | Invalid shares | Non-issue; `rx/0` still current. |
| 7-day cert expiry | App stops launching | Unchanged and unavoidable on a free account. |
| Thermal ceiling | Sustained rate far below burst | **The live constraint.** With the arena working, heat is now the ceiling — not the interpreter, not the config. |
| *(unforeseen)* Script assignment | — | Not in the original register at all, and it is the most fragile part of the system: a StikDebug reinstall silently drops the miner to 400 H/s. See 6.1. |
| *(unforeseen)* Launch path | — | Also absent. Launching from the home-screen icon costs 7.5x, with no error shown. See 6.2. |
| *(unforeseen)* `fetch-randomx.sh` clobbering the patch | — | The script overwrote the two patched JIT files with upstream copies. Fixed; the fix is now tested. |
---

## Part 11 — Honest expectation, revisited

The original text said the interesting part of this project would be the port, not the XMR.
That was right, and it is worth repeating now that it works: **~3000 H/s is not meaningful
income.** It is a phone doing about what a single desktop core does, while getting hot.

What the build actually cost, against the estimate: roughly the predicted amount of Swift and
stratum code, plus an entire subsystem — the arena — that this plan did not anticipate because
it assumed iOS 26 behaved like iOS 17.

**What is fragile now**, in order of how easily it breaks:

1. The **launch path** — must be StikDebug, every cold start (6.2).
2. The **script assignment** — manual, and lost on StikDebug reinstall (6.1).
3. The **pairing file** — must be regenerated after any iOS update (Part 6).
4. The **7-day certificate** — re-sign weekly.

**What the ceiling is now:** thermal. Same conclusion as the Android phone in the earlier
notes, reached from the opposite direction — there the config was never the limit either.

The design goal held up: no CMake, no libuv, no OpenSSL, no dev fee, and the only patched
upstream files are the two the arena required.
---

## Appendix — evidence used

```bash
# the APK is React Native + xmrig JNI, not Flutter

unzip -l xmrig-for-android-v0.1.3-release.apk | grep -Ei 'xmrig|hermes|react'

# the dead iOS scaffold

ls -la xmrig-for-android-main/ios

# the JIT gate is a build flag, not a patch
# (true of RandomX's source; NOT sufficient on iOS 26 - see Part 3)

curl -sL https://raw.githubusercontent.com/tevador/RandomX/master/src/virtual_memory.c \
  | grep -nE 'USE_PTHREAD_JIT_WP|MAP_JIT|mprotect'

# icache flushing is already handled on arm64

curl -sL https://raw.githubusercontent.com/tevador/RandomX/master/src/jit_compiler_a64.cpp \
  | grep -n clear_cache

# xtool.yml schema and Linux setup

curl -sL https://raw.githubusercontent.com/xtool-org/xtool/main/Documentation/xtool.docc/Control.md
curl -sL https://raw.githubusercontent.com/xtool-org/xtool/main/Documentation/xtool.docc/Installation-Linux.md
```

**Added after the build — the iOS 26 findings the research above did not surface:**

```bash
# the split RW/RX views that make the arena usable

grep -n 'codeExec\|arenaBacked\|syncCode' Sources/CRandomX/jit_compiler_a64.hpp

# the brk #0xf00d handshake

grep -n '0xf00d\|vm_remap\|sigsetjmp' Sources/CRandomX/jit26_arena.c

# the six arena states, and the log line for each

grep -n 'RX_JIT26_' Sources/CRandomX/jit26_arena.h
grep -n 'case [1-5]:' Sources/Miner/MiningEngine.swift

# StikDebug's hardcoded auto-assign list - "Monero Miner" is not on it

# (StikDebug source: Sources/.../AutoScriptAssignments.swift)

```

The two claims in the original appendix about `USE_PTHREAD_JIT_WP` and `mprotect` are still
factually true about RandomX's source — they were just no longer sufficient on iOS 26. The
error was not in reading the code; it was in assuming the kernel still had the final say over
page permissions.
