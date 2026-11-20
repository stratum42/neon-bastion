/*
 * c/td_sim.h - C11 particle simulation and backdrop kernels for NEON BASTION
 *
 * Operates on flat C buffers (perl5-mt SVf_PACKED_AV backing stores via
 * AvPACKED_DATA, or temporary buffers on stock Perl 5).
 *
 * Determinism invariants:
 *   - Compiled with #pragma STDC FP_CONTRACT OFF (prevents FMA drift)
 *   - Honors PERL_FORCE_SCALAR=1 (forces single-threaded scalar path)
 *   - Bit-identical output between SIMD+worker-pool and scalar paths
 */
#ifndef TKMT_SCENE_TD_SIM_H
#define TKMT_SCENE_TD_SIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Kernel 1: Particle simulation and dual-layer instance emission.
 *
 * Integrates live particles (life[i] > 0) in place:
 *   x += vx * dt;  y += vy * dt;
 *   vx *= drag;    vy *= drag;
 *   life -= dt;
 *
 * For each surviving particle (life > 0 after step), interpolates RGBA from
 * col_start[i] to col_end[i] with quadratic alpha fade-out and emits two
 * stride-4 instances into inst_out ([x, y, (double)rgba_u32, radius]):
 *   1. Outer halo (radius * 2.4, alpha * 0.28)
 *   2. Inner core (radius, faded alpha)
 *
 * Dead particles (life <= 0) are skipped; live instances are compacted at the
 * front of inst_out and any remaining capacity in inst_out is zeroed.
 *
 * inst_cap: maximum number of stride-4 instances that fit in inst_out.
 * workers:  0 = auto, 1 = single-threaded, >1 = worker count.
 *
 * Returns total number of instances written (2 per surviving particle, capped at inst_cap).
 */
size_t tkmt_td_step_particles(
    double       *px,
    double       *py,
    double       *vx,
    double       *vy,
    double       *life,
    const double *max_life,
    const double *size,
    const double *col_start,
    const double *col_end,
    double       *inst_out,
    size_t        inst_cap,
    size_t        count,
    double        dt,
    double        drag,
    int           workers
);

/*
 * Kernel 2: Procedural arena backdrop (RGBA8888).
 *
 * Renders into rgba_out (w * h * 4 bytes, RGBA8888):
 *   - Radial background gradient
 *   - Grid lines and intersection pips (grid_cols x grid_rows)
 *   - Distance-field path conduit along waypoints
 *   - Spawn portal glow at waypoint[0]
 *   - Bastion core glow at waypoint[num_waypoints - 1]
 *   - Edge vignette
 *
 * waypoints_xy:   flat array of [x0, y0, x1, y1, ...] in pixel coordinates.
 * num_waypoints:  number of (x, y) waypoint pairs.
 * time_sec:       animation time in seconds.
 * workers:        0 = auto, 1 = single-threaded, >1 = worker count.
 *
 * Returns 0 on success, -1 on invalid arguments.
 */
int tkmt_td_render_backdrop_rgba8(
    uint8_t      *rgba_out,
    uint32_t      w,
    uint32_t      h,
    uint32_t      grid_cols,
    uint32_t      grid_rows,
    const double *waypoints_xy,
    size_t        num_waypoints,
    double        time_sec,
    int           workers
);

#ifdef __cplusplus
}
#endif

#endif /* TKMT_SCENE_TD_SIM_H */
