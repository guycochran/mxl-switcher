# Comparison: our MXL switcher vs. thiagopnts/switchframe

A reference comparison (Oct 2026). **SwitchFrame** (github.com/thiagopnts/switchframe) is an
independent project with the **same north star as ours**: a browser-controlled, server-side
live production switcher built on the EBU **MXL** shared-memory transport. It is far more
built-out than our prototype, so it is a valuable **source of ideas** — not a competitor to
adopt (2 stars / 0 forks: it's one person's deep solo engine, not a standard).

## What SwitchFrame is
- **Go 1.25 engine + Svelte 5 control UI**, single binary, WebTransport/QUIC (HTTP-3) control.
- Sources decode to **YUV420 server-side**; all switching/mixing/keying/compositing happens on
  the server; browsers are pure control surfaces (identical philosophy to our Core/Skin split).
- **Same substrate as us:** MXL (V210 video / float32 audio shared memory), SRT in/out
  (listener+caller), MPEG-TS recording. Plus MoQ ingest, ST 2110, multi-dest SRT.
- Scale: ~3,000 commits, 291 REST endpoints, 59 GPU/SIMD kernels (Metal + CUDA), AI captions
  (whisper.cpp → CEA-608), AI background removal (TensorRT RVM), 3D-LUT color grade, 8-layer
  DSK, instant replay, multi-operator roles + Opus comms.

## Where it is ahead of us, and why
| Area | SwitchFrame | Us (this repo) |
|---|---|---|
| Core engine | one Go binary, lock-free hot path (<1µs/frame), **atomic graph swap** (zero-drop reconfig) | orchestrated containers: CBC Rust **input-selector** + Python ingests + gst pipelines |
| **"grain too late" wedge** | reader **re-syncs to `head-2` and continues** (transient, not fatal) | CBC selector **wedges/dies** on it → our PTZ-over-relay bug |
| GPU | Metal/CUDA, 59 kernels, actually used | GTX 970 idle; v210 has no HW path; CEF forces SwiftShader (upstream image) |
| v210 pack/unpack | **SIMD** (`v210_10bit_kernels_{amd64,arm64}.s`) | gst `videoconvert` in software (~1 core/active fanout before our tsparse fix) |
| Timing | dedicated `clock` + `stmap` modules, independent monotonic PTS per stream | hand-tuned restamp in `contribution_core.py`, fragile under relay jitter |

## The single most transferable lesson (applied)
SwitchFrame's MXL reader (`server/mxl/reader.go`):
> *"On 'too late' errors, re-sync to the current write head instead of dying."*
> *"Timeout and too-early are transient — don't count as fatal errors."*
It jumps to `head-2` and continues; only ~50 **consecutive** fatals stop it.

This is the exact cure for our recurring **PTZ selector wedge** (`read source grain N: Out of
range - too late`). We hit it because our stack uses CBC's Rust input-selector, which **dies**
on that error where SwitchFrame's own reader **re-syncs**. We can't patch CBC's Rust, so we
applied the same principle at the layer we control: **`mxl-selfheal` now detects the wedge and
re-cuts to a verified-advancing slot**, forcing the router to re-grab from the current head
(commit `feat(selfheal): re-sync a selector wedged on a grain 'too late' error`). That's a
watchdog-level re-sync vs. SwitchFrame's in-reader re-sync — same idea, our architecture.

## Ideas worth borrowing next (ranked)
1. **Re-sync reader (DONE at watchdog layer).** The "transient, not fatal; re-grab head" rule
   is the biggest reliability win and is now in selfheal. If we ever own the selector, bake it
   into the reader itself (the proper place) instead of healing after the fact.
2. **Role-based discovery (already aligned).** Their `discovery.go` ≈ our new `tools/mxl-flows.sh`
   (resolve flows by stable ROLE, not baked UUIDs). We arrived at the same design independently.
3. **SIMD v210** (`v210_10bit_kernels`). Our fanout/conform is the CPU hog (profile: ~1 core
   each). A SIMD v210 pack/unpack (or moving conform to a Go/Rust helper) would reclaim cores
   that gst `videoconvert` burns — cheaper than the GPU path (v210 has no GPU HW path anyway).
4. **Atomic graph swap** for zero-drop reconfig. Our re-wires interrupt PGM (why we built
   never-interrupt + stable-flow pre-wiring). Their atomic swap is the clean general answer; our
   stable-flow approach is the pragmatic version on a selector we don't own.
5. **GPU, selectively** (deferred). Their 59 kernels need a Go/CUDA engine. For us the only
   realistic near-term GPU win is NVENC on the mxl2webrtc x264 encode — a container rebuild,
   lower priority than #3.

## Strategic read
SwitchFrame validates our architecture (MXL + server-side switch + browser control is the right
shape) and shows the mature endpoint. But it's a from-scratch Go engine; our value is being the
**adoptable, MXL-native, container-orchestrated** path that runs on commodity hardware a facility
already has. Borrow their proven algorithms (re-sync reader, SIMD v210, atomic swap); don't chase
feature parity with a 3,000-commit solo engine. Keep our edge: quickstart-able, portable, honest
about what runs on a $400 box.
