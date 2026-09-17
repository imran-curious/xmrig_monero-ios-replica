# Monero Miner for iOS

Mine Monero on an iPhone, at full native speed, on iOS 26.

This is a complete Monero (RandomX) miner written from scratch in Swift and C++. The hard part
was not the mining — it was getting Apple's newest security system to let the app generate and
run its own machine code. Solving that made it **7.5x faster**:

| How the app is started | Speed |
|---|---|
| Normal (tap the icon) | ~400 H/s |
| **Started through StikDebug** | **~3000 H/s** |

Measured on a 6-core iPhone with 12 GB RAM running iOS 26.5.1, using 2 mining threads.

Every step from an empty machine to a running miner is below, with the exact commands.

---

## Read this before you start

**You will not make money.** A desktop CPU does 5,000-15,000 H/s and a mining rig does millions.
At 3000 H/s, your share of the Monero network is close to zero. Expect to earn a few cents per
month, at most. **Do this because the engineering is interesting, not for profit.**

**It is hard on your phone.** Mining runs every CPU core flat out. Your phone will get hot,
the battery will drain in a few hours, and running it for weeks will measurably age the battery.
The app watches the phone's temperature and slows down or pauses when it gets too hot, but that
only limits the damage — it does not prevent it. Don't do this on a phone you depend on.

**Check the rules that apply to you.** Some countries restrict cryptocurrency mining, and some
workplace or carrier agreements forbid it. That's on you to check.

**This is not on the App Store and never will be.** Apple's guidelines prohibit mining apps, so
you have to build and install it yourself. That's what the rest of this guide is for.

---

## Terms used in this guide

| Term | What it means |
|---|---|
| **IPA** | An iPhone app file, like `.exe` on Windows or `.apk` on Android. |
| **Sideloading** | Installing an app without the App Store. Legal, and Apple supports it for developers. |
| **JIT** | "Just-In-Time" compilation. The app writes new machine code while running and then executes it. This is what makes the miner 7.5x faster. |
| **Pairing file** | A small file that proves your computer is trusted by your iPhone. Some tools need one. |
| **Stratum** | The protocol miners use to talk to a mining pool. |
| **Pool** | A group of miners that combine their work and split the payout. Solo mining on a phone would never find a block. |
| **Wallet address** | Where your Monero gets paid. A long string starting with `4`. |

---

## What you'll need

**Hardware**

- An iPhone or iPad running **iOS 26.x** (check in Settings → General → About)
- A **Windows PC, Mac, or Linux machine** to build on
- A **USB cable** to connect them

**Accounts**

- An **Apple ID**. A free one is fine — no $99 developer account needed. Be aware of the free
  account limits, which will affect you:
  - Apps stop working after **7 days** and must be refreshed
  - Only **3 sideloaded apps** on the device at once
  - Only **10 new app IDs per week**
- A **Monero wallet address**. If you don't have one, get the
  [official Monero wallet](https://www.getmonero.org/downloads/) or use an exchange that gives
  you a deposit address.

**Time**

Set aside **2-4 hours** for your first attempt. Most of that is one-time setup of the build
tools. Once it works, rebuilding takes under a minute.

---

# Part 1 — Set up your build machine

You need a Linux environment with Apple's Swift compiler. On Windows, that means WSL.

### Windows only: install WSL

Open **PowerShell as Administrator** and run:

```powershell
wsl --install -d Ubuntu
```

Restart your PC when it asks. On first launch, Ubuntu will ask you to create a username and
password — pick anything, and remember the password, you'll need it for `sudo`.

From here on, **every command runs inside Ubuntu**, not PowerShell. Open it by typing `wsl` in a
terminal, or launching "Ubuntu" from the Start menu.

> On macOS or Linux, skip this — just use your normal terminal.

### Step 1.1 — Install Swift

Go to [swift.org/install](https://www.swift.org/install/linux/), pick your distribution, and
follow their instructions. You need **Swift 6.3 or newer**.

Check it worked:

```bash
swift --version
```

### Step 1.2 — Install the USB tools

```bash
sudo apt-get update
sudo apt-get install -y usbmuxd libimobiledevice-utils
```

### Step 1.3 — Install xtool

[xtool](https://github.com/xtool-org/xtool) is what builds iPhone apps without needing a Mac.

```bash
curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
chmod +x xtool
sudo mv xtool /usr/local/bin/
```

### Step 1.4 — Download Xcode

xtool needs Apple's developer tools to build for iPhone. You must download this **in a web
browser** while signed in to your Apple ID — it can't be downloaded with a command, because
Apple requires a login.

1. Go to [developer.apple.com/download/all](https://developer.apple.com/download/all/)
2. Sign in with your Apple ID
3. Search for **Xcode 26** and download the `.xip` file (it's large — around 10 GB)

On Windows, the file lands in your normal Downloads folder. WSL can reach it at
`/mnt/c/Users/YourName/Downloads/`.

### Step 1.5 — Run xtool setup

```bash
xtool setup
```

This asks you two things:

1. **Your Apple ID login.** Choose **"Password"** mode if you have a free Apple ID. If you have
   two-factor authentication on (you probably do), you may need an
   [app-specific password](https://support.apple.com/en-us/102654).
2. **Where the Xcode `.xip` is.** Give it the full path from Step 1.4.

Then confirm it worked:

```bash
swift sdk list
```

You should see `darwin` in the output. **If you don't, stop here and fix it** — nothing later
will work.

### Step 1.6 — Windows only: pass your iPhone through to WSL

WSL can't see USB devices by default. Install
[usbipd-win](https://github.com/dorssel/usbipd-win/releases) on the Windows side, then in an
**Administrator PowerShell**:

```powershell
usbipd list
```

Find your iPhone in the list and note its `BUSID` (something like `2-4`), then:

```powershell
usbipd bind --busid 2-4
usbipd attach --wsl --busid 2-4
```

Back in Ubuntu, check the phone is visible:

```bash
ideviceinfo
```

> **If this fails** with `AFCClient.Error.muxError` or similar, don't fight it. xtool's docs
> describe a workaround that relays the connection through iTunes on Windows. You can also skip
> USB entirely and install via SideStore instead (Part 3, Option B).

---

# Part 2 — Build the app

### Step 2.1 — Get the code

```bash
git clone <this-repo-url>
cd ios-replica
```

### Step 2.2 — Download RandomX

RandomX is the mining algorithm. It isn't stored in this repo — this script fetches it:

```bash
./scripts/fetch-randomx.sh
```

You should see `==> RandomX source populated successfully.`

### Step 2.3 — Set your wallet address

Open `Sources/Miner/Models.swift` and find line 16:

```swift
public var walletAddress: String = "4..."
```

Replace it with **your own** Monero address. (You can also change it inside the app later, but
setting it here saves typing a 95-character string on a phone keyboard.)

While you're in that file, `poolUrl` is set to `auto.c3pool.org:80`, which is a reasonable
default. Change it if you prefer a different pool.

### Step 2.4 — Build

```bash
xtool dev build -c release --ipa
```

The first build takes a few minutes because it compiles all of RandomX. Later builds take about
10 seconds.

When it finishes you'll see:

```
Build complete!
Wrote to .../xtool/MoneroMiner.ipa
```

**That file — `xtool/MoneroMiner.ipa` — is your app.**

---

# Part 3 — Get the app onto your iPhone

Pick **one** of these. Option A is simpler if USB already works; Option B avoids USB problems.

### Option A — Straight over USB

With the phone connected and visible to WSL:

```bash
xtool dev
```

This builds, signs and installs in one step. Best while you're making changes.

### Option B — SideStore

[SideStore](https://sidestore.io/) installs apps on your iPhone and automatically refreshes them
before the 7-day expiry. Follow their setup guide, then:

1. Copy `xtool/MoneroMiner.ipa` somewhere your phone can reach it (AirDrop, iCloud Drive, or a
   USB transfer)
2. Open SideStore on the phone
3. Go to **My Apps → +** and pick the IPA

> **Note:** xtool adds a prefix to the app's ID when signing (so it looks like
> `XTL-1234.com.monero.iosminer` rather than `com.monero.iosminer`). That's normal and expected
> with a free Apple account.

### Step 3.1 — Trust the app

The first time you tap the app it will refuse to open. On the phone:

**Settings → General → VPN & Device Management → tap your Apple ID → Trust**

Now the app opens. **It will run at ~400 H/s** — slow, because it has no JIT yet. That's what
Parts 4 and 5 fix.

---

# Part 4 — Install StikDebug

This is the piece that unlocks the 7.5x speedup. StikDebug attaches a debugger to the miner,
and only an attached debugger can hand out executable memory on iOS 26.

### Step 4.1 — Create a pairing file

A pairing file proves your PC is trusted by your phone. Generate one with
[iloader](https://github.com/Dadoum/iloader), or with the tool you already used in Part 3.

> **Important:** on iOS 26.4 and newer, StikDebug needs a **freshly generated** pairing file. An
> old one fails silently with no useful error. If something doesn't work later, regenerate this
> first. You also need a new one after any iOS update or device reset.

### Step 4.2 — Install StikDebug

Download the latest [StikDebug](https://github.com/StikDebug/StikDebug/releases) IPA (**3.1.10 or
newer**) and install it the same way you installed the miner.

> **Watch the 3-app limit.** A free Apple account allows only 3 sideloaded apps per device, and
> this limit is **per device, not per Apple ID** — signing in with a different Apple ID will not
> get you around it. If the install fails with "maximum number of installed apps", delete
> something else first.

### Step 4.3 — Set up StikDebug

Open StikDebug and give it your pairing file when it asks. Then go to the **Settings** tab and
make sure these are on:

- **Silent Audio** — keeps StikDebug alive in the background
- **Background Location** — same purpose
- **Always Run Scripts** — required on iOS 26

If it's set up correctly, the bottom of the Settings screen will read something like:

```
Version 3.1.10 • iOS 26.5.1 • TXM (Override)
```

**`TXM (Override)` is what you want to see.** If it says something else, "Always Run Scripts"
isn't on.

---

# Part 5 — Connect the miner to StikDebug

This is the step people miss, and nothing works without it.

StikDebug can only hand out executable memory if it has a **script** loaded for the app. It
assigns one automatically for apps it recognizes — but it recognizes them **by name**, from a
list that was written in advance (Amethyst, MeloNX, XeniOS, RPCS3, and so on). "Monero Miner"
isn't on that list, so it gets nothing by default, and the app silently stays slow.

You assign it manually, once:

1. Open **StikDebug**
2. Go to the **Apps** tab
3. **Press and hold** on the "Monero Miner" row
   *(a long press — not a tap, not a swipe. A menu will pop up.)*
4. Tap **"Assign Script"**
5. A file browser opens. Navigate to:
   **On My iPhone → StikDebug → scripts → `universal.js`**
6. Tap it

That's it. The setting is saved, so you only do this once — unless you reinstall StikDebug.

> **Can't find the `scripts` folder?** StikDebug copies its scripts there the first time it runs.
> Open StikDebug at least once, then try again. You can also reach the folder from
> **Settings → App Folder** to check that `universal.js` is really there.

> To undo it later, the same long-press menu has a **"Reset Script"** option.

---

# Part 6 — Mine

### Every single time you want the fast speed:

**Open StikDebug → Apps tab → tap "Monero Miner".**

> **This is the part that's easy to forget.** If you launch the miner by tapping its icon on the
> home screen, it starts with no debugger attached. It won't crash or show an error — it just
> quietly runs at 400 H/s instead of 3000. **If your speed suddenly dropped by 7x, this is
> almost always why.**

### In the app

1. Check your **wallet address** is correct
2. Set **threads** — start with **2**. More is faster but hotter; see the tuning notes below
3. Choose **Fast Mode** if you have the RAM (it uses about 2 GB and is much faster than Light
   Mode)
4. Press **Start**

### Confirm JIT is actually on

Look at the event log in the app. You want to see:

```
[jit] JIT ACTIVE via iOS 26 debugger arena (brk #0xf00d granted RX pages)
```

If you see that line, everything worked. Your hashrate should climb to around 3000 H/s within a
minute or two (the first minute is spent building the dataset).

### Check your pool

Your miner will appear on your pool's dashboard within a few minutes. For the default pool,
that's [c3pool.com](https://c3pool.com/#/dashboard) — paste your wallet address to see your
worker and its hashrate.

---

## Something went wrong

The app tells you exactly which step failed. Find your line in the event log:

| What the log says | What it means | What to do |
|---|---|---|
| `JIT ACTIVE via iOS 26 debugger arena` | Everything is working. | Nothing. |
| `No debugger attached (CS_DEBUGGED clear)` | You launched from the home screen icon. | Close the app. Open it from **StikDebug → Apps** instead. |
| `brk #0xf00d went unanswered` | StikDebug attached, but no script is loaded for this app. | Redo **Part 5**. Also check "Always Run Scripts" is on. |
| `Debugger answered but granted no region` | The script ran, but the memory request was refused. | Usually the phone is low on RAM. Close other apps and restart. |
| `Region granted but the writable alias failed` | An internal memory mapping failed. | This shouldn't happen — please open an issue. |
| `JIT active via RWX mapping (pre-TXM path)` | You're on an older device using the classic method. | Nothing — this is fine, and fast. |
| `Interpreter mode.` | No JIT at all. | Work through Parts 4-6 again. |

**Other common problems:**

| Problem | Cause | Fix |
|---|---|---|
| App won't open, "Untrusted Developer" | Certificate not trusted yet | Settings → General → VPN & Device Management → Trust |
| App stopped working after a week | Free certificates expire after 7 days | Refresh in SideStore, or rebuild and reinstall |
| "Maximum number of installed apps" | Free accounts allow 3 sideloaded apps **per device** | Delete one. A different Apple ID will not help. |
| StikDebug can't connect to the phone | Stale pairing file | Generate a fresh one (Step 4.1) |
| Miner connects then disconnects | Pool or network issue | Check the log for the actual error — it prints the real errno, not a generic message |
| Hashrate drops after 10-20 minutes | The phone is overheating | Normal and expected. Reduce threads, or remove the case |
| Only ~400 H/s | Almost always the launch method | See **Part 6** |

---

## Tuning

**Threads.** Default is 2. You can raise it, but on a phone this mostly trades sustained speed
for peak speed — more threads means more heat, which means the phone throttles sooner, which can
leave you slower after 20 minutes than you would have been with 2. Try 3, watch the thermal
readout in the app, and only keep it if the state stays "Nominal" for a while.

**Fast Mode vs Light Mode.** Fast Mode builds a 2 GB dataset and is several times faster. Light
Mode uses 256 MB. Use Fast Mode unless your device doesn't have the memory for it.

**Temperature.** The app shows the thermal state. "Nominal" and "Fair" are fine. "Serious" means
iOS is already throttling the CPU. "Critical" means the app pauses itself.

---

## How the JIT actually works

*Background — not required to run the app.*

RandomX is designed so the fast path **must** generate code: each mining program is compiled to
real ARM64 instructions and executed. If you can't do that, you fall back to a bytecode
interpreter that runs about 7x slower — that's the 400 H/s.

iOS has never let a normal app create memory that is both writable and executable. The long-time
workaround for sideloaded apps was a flag called `CS_DEBUGGED`: get a debugger to attach once,
and the kernel relaxes its code-signing check for that process. Every JIT-enabler tool relied on
this for years.

**On A15/M2 and newer running iOS 26, that stopped working.** Memory permissions are now enforced
by TXM (Trusted Execution Monitor) and SPTM (Secure Page Table Monitor) — two components that
sit *outside* the kernel, so a kernel-level flag like `CS_DEBUGGED` doesn't move them. The only
thing left that can make a page executable is a write performed **from outside the process** by
an attached debugger.

Which means the app can't grant itself the memory. It has to ask for it.

### The request

StikDebug's `universal.js` runs on the debugger side and watches for breakpoints. The miner
executes:

```asm
mov x16, #1
brk #0xf00d
```

`x16` picks the operation (`0` = detach, `1` = give me a region, `2` = install more handlers),
`x0` is the requested address (null means "anywhere") and `x1` is the size. That `brk` halts the
process. The script sees it, allocates an executable region using the debugger's own memory
command, prepares it one page at a time, writes the resulting address back into the `x0`
register, and lets the app continue. From the app's point of view, it called a function and got
a pointer back.

### The two-window trick

The region you get back is executable but **not writable** — so the compiler still can't put
anything in it. The fix is to map the same physical memory a second time, with write permission,
using `vm_remap` and `vm_protect`:

```
  writable view  --+
                   +-- the same physical pages
  executable view -+       (granted by the debugger)
```

The compiler writes through one window; the CPU executes through the other. `JitCompilerA64`
carries both pointers: `code` to write to, `codeExec` to jump to. This works because RandomX's
generated code is entirely position-independent — every branch and constant load is relative to
the current instruction — so the same bytes are valid at either address. Only the entry pointer
and the cache-flush ranges needed changing.

After writing, `rx_jit26_sync()` flushes the data cache on the writable view and invalidates the
instruction cache on the executable one, so the CPU sees the new instructions.

### Four things that make it fragile

- **The region can never be released.** Once memory is handed back, it can't be re-blessed. So
  `rx_jit26_free()` keeps a free list and never actually unmaps anything.
- **A `brk` with nobody listening kills the app instantly.** The first request is wrapped in a
  `SIGTRAP` handler with `sigsetjmp`/`siglongjmp`, so an unanswered breakpoint is survivable
  rather than fatal. This is what lets the app fall back to the interpreter instead of crashing.
- **The debugger attaches *after* the app starts.** The app's first request often arrives before
  the script is listening, so it retries for about 40 seconds before giving up.
- **Once granted, the memory stays executable even if the debugger disconnects.** So the JIT
  check looks at whether a region was ever granted, rather than re-testing `CS_DEBUGGED`.

---

## What's in this repo

```
Sources/
  CRandomX/                 RandomX (downloaded), plus this project's additions:
    jit26_arena.c/.h          requests the executable region, builds the writable alias
    rx_shim.c                 the C functions Swift calls; decides if JIT is usable
    jit_compiler_a64.cpp      modified: separate write/execute pointers
  Miner/
    MinerCore.swift           pool protocol, mining threads, temperature governor
    RandomXController.swift   memory and VM lifecycle
    MiningEngine.swift        connects the engine to the UI; reports JIT status
    JITProbe.swift            JIT capability check
    ContentView.swift         the user interface
scripts/fetch-randomx.sh    downloads RandomX
```

Every time mining starts, the app verifies its hashing against RandomX's official test vectors,
for both interpreter and JIT modes. If a vector fails it refuses to mine rather than sending the
pool invalid work.

---

## Credits

- [tevador/RandomX](https://github.com/tevador/RandomX) — the mining algorithm itself.
  BSD 3-Clause licensed; the license is included at `Sources/CRandomX/LICENSE`.
- [StikDebug](https://github.com/StikDebug/StikDebug) and
  [StikJIT](https://github.com/StikDebug/StikJIT) — the debugger, the `brk #0xf00d` protocol, and
  `universal.js`. None of the fast path would exist without their work.
- [xtool](https://github.com/xtool-org/xtool) — builds iOS apps without a Mac.
