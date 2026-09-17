# Bare-metal Monero miner for iOS 26.5.1 — build plan

**Toolchain (fixed by you):** `xtool` under WSL for building and signing · `iLoader` + `SideStore` + `StikDebug` for installation and JIT on iPhone, iOS **26.5.1**.
**Goal:** bare-metal miner — native arm64 hashing, no React Native, no JS bridge, no wrapper app around someone else's binary.

Subject that prompted this: `D:\projects\miner_setup\phone\xmrig-for-android-v0.1.3-release.apk` (v0.1.3)
Source tree: `D:\projects\miner_setup\phone\xmrig-for-android-main\` (upstream v0.1.4, MIT, Garry Lachman)
Researched: 2026-09-17

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

## Part 3 — The JIT problem, and why it is smaller than expected

RandomX generates a fresh program per hash and JIT-compiles it. It needs memory that is both writable and executable. On iOS a normal process cannot have that; you need the `dynamic-codesigning` grant, which on 26.5.1 comes only from an attached debugger (`CS_DEBUGGED`), i.e. StikDebug.

**The good news:** RandomX already has a code path that is correct for this, and it is selected by a *build flag, not a source patch*.

In `src/virtual_memory.c`, the macOS-specific behaviour is gated entirely on `USE_PTHREAD_JIT_WP`:

```c
#ifdef USE_PTHREAD_JIT_WP
    #define MEXTRA MAP_JIT
    #define PEXTRA PROT_EXEC
#else
    #define MEXTRA 0
    #define PEXTRA 0
#endif
mem = mmap(NULL, bytes, PAGE_READWRITE | RESERVED_FLAGS | PEXTRA,
           MAP_ANONYMOUS | MAP_PRIVATE | MEXTRA, -1, 0);
```

and likewise `setPagesRW` / `setPagesRX` use `pthread_jit_write_protect_np()` only under that macro, falling back to plain `mprotect()` otherwise.

`MAP_JIT` and `pthread_jit_write_protect_np()` are the two things that do **not** work on iOS. RandomX's CMake defines `USE_PTHREAD_JIT_WP` when it detects Apple + arm64. **We are not using its CMake.** Under SwiftPM the macro is simply never defined, so we get the portable `mmap` + `mprotect` path for free — exactly the behaviour the hand-patched xmrig iOS forks achieve by editing source.

**Zero modifications to RandomX.** That is the single biggest simplification in this plan.

Two supporting details confirmed in the source:

- **icache correctness is handled.** `jit_compiler_a64.cpp` calls `__builtin___clear_cache()` itself after emitting code (three sites), so the non-`MAP_JIT` path does not produce stale-icache garbage on ARM64.
- **Avoid `RANDOMX_FLAG_SECURE`.** With SECURE set, RandomX flips W^X on every program. Without it, `enableAll()` → `setPagesRWX()` maps the code region RWX **once** and never flips. On iOS that means exactly one privileged operation per VM, at creation, instead of millions.

### 3.1 The JIT probe

Because one `mprotect(..., PROT_READ|PROT_WRITE|PROT_EXEC)` is the entire privileged surface, it is also a perfect pre-flight check. Probe it before touching RandomX:

```swift
func jitAvailable() -> Bool {
    let size = 4096
    let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
    guard let p, p != MAP_FAILED else { return false }
    defer { munmap(p, size) }
    return mprotect(p, size, PROT_READ | PROT_WRITE | PROT_EXEC) == 0
}
```

**The app must never assume JIT.** StikDebug attaches around launch, and the pairing/VPN can be in any state. Design the UI as a gate: `Waiting for JIT…` → poll the probe → only then build the RandomX VM. Without this the app simply crashes on a normal launch and you will waste time thinking the build is broken.

Fallback if the probe fails: RandomX runs its interpreter, roughly **3–5 H/s versus 200+ H/s** with JIT. Surface which mode you are in on screen; do not silently mine at 1% speed.

---

## Part 4 — Project shape

```
ios-miner/
  xtool.yml
  Package.swift
  App.entitlements
  Info.plist
  scripts/fetch-randomx.sh      # clones tevador/RandomX, lays src/ into Sources/CRandomX/
  Sources/
    CRandomX/                   # C/C++ target: RandomX + a thin C shim
      include/rx_shim.h         #   the ONLY header Swift sees
      rx_shim.c
      <RandomX src/*>
    Miner/                      # Swift: stratum, threads, governor, SwiftUI
```

**`xtool.yml`** — confirmed key set is `version`, `bundleID`, `infoPath`, `entitlementsPath`, `iconPath`, `resources`:

```yaml
version: 1
bundleID: com.yourname.iosminer
infoPath: Info.plist
entitlementsPath: App.entitlements
```

**Why the C shim.** RandomX's public API takes a C enum (`randomx_flags`) whose import into Swift is awkward to bit-OR. Rather than fight the Clang importer, expose a handful of `uint32_t`-flavoured functions from `rx_shim.h` (`rx_create`, `rx_vm_create`, `rx_hash`, `rx_destroy`) and keep every enum and opaque type on the C side. The shim is also the right home for the **multi-threaded dataset init** — `randomx_init_dataset` must be split across threads by item range or first-start takes minutes.

**Exclusions in `Package.swift`.** RandomX ships x86 and RISC-V backends that will not compile for arm64; exclude them explicitly:
`jit_compiler_x86.cpp`, `jit_compiler_x86_static.S`, `jit_compiler_x86_static.asm`, `assembly_generator_x86.cpp`, `argon2_avx2.c`, `argon2_ssse3.c`, `asm/`, `cpu_rv64.S`, `jit_compiler_rv64*.{cpp,S}`, `aes_hash_rv64_*.cpp`, `tests/`.
Also add `linkerSettings: [.linkedLibrary("c++")]`, and put a one-line forwarding header in `include/` so both `#include "randomx.h"` (internal) and the target's public headers resolve.

**Things to verify on the first build**, rather than assume:

1. That `__ARM_FEATURE_CRYPTO` is defined for `arm64-apple-ios` so hardware AES is used. If `randomx_get_flags()` does not report `HARD_AES`, add `-mcpu=apple-a12` (or later) to `cxxSettings`.
2. That excluding `assembly_generator_x86.cpp` does not break a reference in `randomx.cpp` — the arch guards should cover it; un-exclude if not.
3. Whether the pool's algo is still `rx/0`. RandomX master now carries a `RANDOMX_FLAG_V2 = 128`. Read the algo from the stratum login response and set the flag from that rather than hardcoding.

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
xtool dev build      # output: ./xtool/Miner.app
```

**Two install routes — you want the second:**

- `xtool dev` builds, signs and installs straight over USB. Best for the edit/run loop while developing.
- For **SideStore**, wrap the built bundle yourself:

```bash
mkdir -p Payload && cp -r xtool/Miner.app Payload/ && zip -r Miner.ipa Payload
```

Then install `Miner.ipa` through SideStore, which re-signs with your own certificate.

**Free-account limits that will bite:** 7-day certificate expiry (SideStore refreshes, but it must be able to reach your device), 3 sideloaded apps at a time, 10 App IDs per week. Also note xtool **prefixes your bundle ID** when signing (e.g. `XTL-1234.com.yourname.iosminer`) to avoid free-account collisions — expect the installed bundle ID not to match `xtool.yml` exactly.

---

## Part 6 — JIT bring-up on 26.5.1

StikDebug supports iOS 17.4+ including 26.x. Three things are all mandatory:

1. **Pairing file** — generated once on the PC with **iLoader** (or `idevicepair`). The StikDebug 3.1 branch **requires a freshly generated pairing file** on iOS 26.4+; an older file silently fails. Regenerate after any iOS update or device reset.
2. **LocalDevVPN / StosVPN** — not optional. StikDebug will not function without the loopback VPN active.
3. **StikDebug itself**, sideloaded alongside the miner.

Routine use is then: open StikDebug → *Enable JIT* → pick the miner. Full PC setup recurs only when the pairing file expires.

Caveats specific to iOS 26: JIT on this branch is reported as fragile, with 26.6 and 27 working for only a few apps. **26.5.1 is inside the working window, but verify with a known-good JIT app (PPSSPP or Dolphin) before blaming your own build.** StikDebug's "Scripts" feature is called out as especially useful for iOS 26 JIT — worth reading if attachment is flaky.

Practical consequence for the app: **JIT does not survive relaunch.** Every cold start needs StikDebug again. Hence the wait-for-JIT gate in 3.1, and a strong reason to keep the app alive once it is running rather than restarting it.

---

## Part 7 — Runtime policy (this is where the hashrate actually comes from)

### 7.1 Memory: fast mode vs light mode

- **Fast mode** (`RANDOMX_FLAG_FULL_MEM`) needs a **2080 MiB** dataset. Roughly an order of magnitude faster per thread.
- **Light mode** needs 256 MiB but is far slower.
- `RANDOMX_FLAG_LARGE_PAGES` will fail on iOS (`VM_FLAGS_SUPERPAGE_SIZE_2MB` is not available to apps) — do not set it.

Decide at runtime, not at compile time: call **`os_proc_available_memory()`** and pick fast mode only if the remaining budget clears the dataset plus scratchpads plus headroom. Getting this wrong means a jetsam kill, not a graceful failure.

To raise the ceiling, try the **`com.apple.developer.kernel.increased-memory-limit`** entitlement (and possibly `extended-virtual-addressing`) in `App.entitlements`. **Open question to test early:** whether it survives. xtool's docs warn some entitlements do not work with free accounts, and separately, SideStore re-signs the IPA with its own profile — so an entitlement xtool applied may or may not persist through that. If it does not, `xtool dev` over USB may preserve it where SideStore does not. Establish this in Phase 1; the whole fast/light decision hangs on it.

Dataset init is minutes single-threaded — always split `randomx_init_dataset` across all cores by item range.

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

Plus a `keepalived` call every ~60s, and reconnect-with-backoff on drop. Your existing C3Pool wallet address works unchanged — workers are just names, so give this one a distinct worker/rig id so it does not collide with `laptop`.

---

## Part 9 — Phases

| Phase | Work | Est. |
|---|---|---|
| 0 | WSL prerequisites: Swift 6.3, usbmuxd, USBIPD passthrough, Xcode 26 xip, `xtool setup`, `swift sdk list` shows `darwin`. Build and install the stock `xtool new` hello-world to the phone. **Do not proceed until a trivial app runs.** | 0.5–1 d |
| 1 | JIT bring-up: iLoader pairing file, StosVPN, StikDebug. Ship an app that does nothing but run the Part 3.1 probe and display the result. Also test the `increased-memory-limit` entitlement here, via both `xtool dev` and SideStore. | 0.5 d |
| 2 | RandomX as a SwiftPM target. Get `rx_shim` hashing and validate against RandomX's official test vectors on-device. This is the make-or-break phase. | 1–2 d |
| 3 | Stratum client in Swift; log-only, no hashing. Confirm login, job receipt, keepalive, reconnect against the real pool. | 1 d |
| 4 | Join them: thread pool, nonce partitioning, share submission. First accepted share. | 1 d |
| 5 | Governor: QoS, thermal states, fast/light decision, dataset re-init on seed change. | 1 d |
| 6 | Minimal SwiftUI: hashrate, accepted/rejected, JIT state, thermal state, mode (fast/light, JIT/interpreter). | 0.5 d |
| 7 | Measure. Sustained rate over an hour, not burst. Compare against the Android phone. Tune thread count. | 0.5 d |
| 8 | *Optional:* silent-audio background mode. | 0.5 d |

**~7–9 working days solo**, assuming Phase 0 and Phase 1 behave. They are also the phases most likely to eat a day each on environment problems rather than code — USB passthrough and pairing files are where this stalls.

---

## Part 10 — Risk register

| Risk | Where it bites | Mitigation |
|---|---|---|
| JIT unavailable or unstable on 26.5.1 | Everything. ~50x hashrate. | Phase 1, before any mining code. Validate StikDebug with PPSSPP first. |
| USBIPD/usbmuxd flakiness in WSL | Phase 0, recurring | xtool's documented iTunes-relay workaround. |
| `increased-memory-limit` stripped by SideStore re-signing | Forces light mode, ~10x | Test both install routes in Phase 1. Fall back to `xtool dev` over USB. |
| Jetsam kill on dataset alloc | Crash on start | Gate on `os_proc_available_memory()`; light mode by default until proven. |
| Algo is no longer `rx/0` | Invalid shares | Read algo from login response; set `RANDOMX_FLAG_V2` accordingly. |
| 7-day cert expiry | App stops launching | SideStore refresh; keep the pairing file current. |
| Thermal ceiling | Sustained rate far below burst | Phase 5 governor; measure over an hour. |

---

## Part 11 — Honest expectation

You have decided to build it, so this is the last time it comes up. Foreground-only, screen-on, plugged-in, JIT re-armed after every launch, re-signed weekly, thermally capped — the sustained rate will be a fraction of what the Android phone already produces unattended, and the interesting part of this project is the port, not the XMR.

The upside of the design above is that it is small: roughly 600–900 lines of your own code, no CMake, no libuv, no OpenSSL, no source patches to RandomX, and no dev fee.

---

## Appendix — evidence used

```bash
# the APK is React Native + xmrig JNI, not Flutter
unzip -l xmrig-for-android-v0.1.3-release.apk | grep -Ei 'xmrig|hermes|react'

# the dead iOS scaffold
ls -la xmrig-for-android-main/ios

# the JIT gate is a build flag, not a patch
curl -sL https://raw.githubusercontent.com/tevador/RandomX/master/src/virtual_memory.c \
  | grep -nE 'USE_PTHREAD_JIT_WP|MAP_JIT|mprotect'

# icache flushing is already handled on arm64
curl -sL https://raw.githubusercontent.com/tevador/RandomX/master/src/jit_compiler_a64.cpp \
  | grep -n clear_cache

# xtool.yml schema and Linux setup
curl -sL https://raw.githubusercontent.com/xtool-org/xtool/main/Documentation/xtool.docc/Control.md
curl -sL https://raw.githubusercontent.com/xtool-org/xtool/main/Documentation/xtool.docc/Installation-Linux.md
```
