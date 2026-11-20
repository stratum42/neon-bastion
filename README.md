# NEON BASTION

NEON BASTION is a small, fun tower defense exercise exploring what a Perl and
Tcl/Tk desktop application can do when paired with `Tcl::Tk::MT` and
`perl5-mt`. It builds on the long-standing work of the Perl 5 and Tcl/Tk
communities and tries out packed `MT::Array` buffers (`NV` and `U8`), a small
C11 XS helper (`NeonBastion::SimXS`) for particle integration and procedural
backdrop synthesis, and `Tcl::Tk::MT`'s Metal, Vulkan, and software canvas
backends.

## Requirements

- `perl5-mt` (or stock Perl 5, with automatic unpacked fallback)
- `Tcl::Tk::MT` installed in `@INC`, pointed to via `TCL_TK_MT_DIR`, or built side-by-side at `../tcl-tk-mt`
- A C11 compiler (`clang`, `gcc`, or `cl`)

## Build & Test

Set `PERL` to your `perl5-mt` (or `perl`) binary and `PERL_SRC` to the matching source tree when building against an uninstalled `perl5-mt`:

```sh
export PERL=../perl5-mt/perl
export PERL5LIB=../perl5-mt/lib

$PERL Makefile.PL PERL_SRC=../perl5-mt
make

# Run full test suite (kernel parity + headless game verification)
$PERL -MApp::Prove \
    -e 'my $a = App::Prove->new; $a->process_args("-b", "-v", "t/"); exit($a->run ? 0 : 1)'

# Verify bit-identical scalar twin parity
PERL_FORCE_SCALAR=1 $PERL -MApp::Prove \
    -e 'my $a = App::Prove->new; $a->process_args("-b", "-v", "t/01_td_sim.t"); exit($a->run ? 0 : 1)'
```

If `perl` is already installed on `PATH`, run `perl Makefile.PL && make && prove -b -v t/`.

## Running

### Interactive Desktop Mode

```sh
$PERL neon_bastion.pl
```

### Auto-Play Demo Mode

```sh
$PERL neon_bastion.pl --demo
```

### Headless Benchmark & Snapshot Export

```sh
$PERL neon_bastion.pl --headless --demo --frames=120 --json --snapshot=/tmp/neon_bastion.ppm
```

Compare against the software renderer:

```sh
$PERL neon_bastion.pl --headless --demo --frames=120 --json --backend=software
```

If `Tcl::Tk::MT` is built in a custom directory rather than installed in `@INC` or `../tcl-tk-mt`, set `TCL_TK_MT_DIR=/path/to/tcl-tk-mt`.

## CLI Options

| Option | Description |
|---|---|
| `--demo` | Enable built-in Auto-Play |
| `--headless` | Run offscreen simulation and render benchmark without opening a window |
| `--frames=N` | Fixed-dt frames to execute in headless mode (default: `120`) |
| `--json` | Emit structured JSON metrics in headless mode |
| `--snapshot=PATH` | Write the final headless frame as a binary PPM (`P6`) image |
| `--backend=NAME` | Override graphics backend (`auto`, `metal`, `vulkan`, `software`) |
| `--auto-exit-ms=N` | Automatically close the interactive window after `N` ms |
| `--help`, `-h` | Print CLI usage |

## Controls & Hotkeys

- **Left-Click Tile**: Place the selected tower, or select an existing tower to inspect its range ring.
- **Right-Click / `Esc`**: Deselect the current tower.
- **`1` / `2` / `3` / `4`**: Select **PULSE** ($50), **RAIL** ($100), **FROST** ($80), or **TESLA** ($130).
- **`U`**: Upgrade selected tower (Levels 1 to 3).
- **`S`**: Sell selected tower (70% credit refund).
- **`Space`**: Launch next wave.
- **`F`**: Toggle 1x / 2x simulation speed.
- **`A`**: Toggle Auto-Play AI.
- **`R`**: Restart mission.

## Towers & Enemies

| Tower | Cost | Role |
|---|---|---|
| **PULSE** | $50 | Rapid-fire twin plasma bolts with muzzle and impact sparks |
| **RAIL** | $100 | High-damage piercing railgun beam with shockwave rings |
| **FROST** | $80 | Expanding cryo-nova rings that slow enemies in radius |
| **TESLA** | $130 | Procedural chain-lightning jumping across up to 5 targets |

| Enemy | Archetype |
|---|---|
| **SWARM** | Fast crimson diamonds spawning in packs |
| **STRIKER** | Agile orange chevrons |
| **TANK** | Heavily armored violet hexagons |
| **PHANTOM** | High-speed neon-green delta triangles |
| **DREADNOUGHT** | Boss unit every 5 waves with multi-ring shatter burst and screen shake |

## Architecture

- **`SimXS.xs`, `c/td_sim.{h,c}`, `c/tkmt_thread.h`, `c/mt_compat.h`, `lib/NeonBastion/SimXS.pm`**: `PERL_XS_THREADSAFE` C11 helper for particle integration and procedural backdrop rendering. Reads and writes `SVf_PACKED_AV` backing stores (`AvPACKED_DATA`) directly under `perl5-mt`, with a fallback path for stock Perl 5. Uses NEON (`float64x2_t`) or SSE2 (`__m128d`) with a small pthread/Win32 worker pool, and matches the `PERL_FORCE_SCALAR=1` scalar path bit-for-bit.
- **`neon_bastion.pl`**: CLI entry point, headless benchmark harness, and interactive `Tcl::Tk::MT` desktop UI.
- **`lib/NeonBastion/Config.pm`**: 960x600 (16x10) S-curve arena geometry, tower and enemy tables, 10 waves plus Endless Mode, and Auto-Play build plan.
- **`lib/NeonBastion/Sim.pm`**: Fixed-timestep game simulation in Perl (waves, targeting, combat, Auto-Play) with a preallocated `MT::Array::packed('NV', ...)` particle ring buffer stepped by `NeonBastion::SimXS::step_particles`.
- **`lib/NeonBastion/Renderer.pm`**: Procedural distance-field backdrop (`NeonBastion::SimXS::render_backdrop_rgba8` uploaded via `Photo::put_rgba_packed`), batched canvas primitives, instanced halo+core particles (`createInstances` with stride-4 `[x, y, rgba_u32, radius]`), and pan-offset screen shake.

## Sample Performance (Metal vs Software)

Game logic, targeting, waves, and the Tk UI stay in Perl, while particle
integration and backdrop synthesis run in the small C11 XS helper. For
reference, here are sample numbers from the headless benchmark
(`--headless --demo --frames=120 --json`, 960x600, Apple Silicon macOS,
`perl5-mt`):

| Backend | FPS | Frame p50 (ms) | Frame p95 (ms) | Sim avg (ms) | Render avg (ms) | Total (ms) |
|---|---:|---:|---:|---:|---:|---:|
| **Metal** | 261.6 | 3.79 | 4.67 | 0.19 | 3.63 | 458.6 |
| **Software** | 120.3 | 8.31 | 8.82 | 0.16 | 8.15 | 997.7 |
