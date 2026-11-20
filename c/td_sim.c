/*
 * c/td_sim.c - C11 particle simulation and backdrop kernels for NEON BASTION
 *
 * Implements:
 *   1. tkmt_td_step_particles        (SoA particle physics + stride-4 halo/core emission)
 *   2. tkmt_td_render_backdrop_rgba8 (procedural distance-field arena backdrop)
 *
 * Determinism invariants:
 *   - #pragma STDC FP_CONTRACT OFF (Clang/MSVC) / -std=c11 (GCC) disables FMA contraction
 *   - NEON float64x2_t (aarch64) / SSE2 __m128d (x86_64) execute the same
 *     IEEE-754 operation sequence as the scalar path
 *   - PERL_FORCE_SCALAR=1 forces the single-threaded scalar path
 *   - Persistent worker pool avoids per-frame thread creation
 */

#if !defined(__GNUC__) || defined(__clang__)
#  pragma STDC FP_CONTRACT OFF
#endif

#include "tkmt_thread.h"
#include "td_sim.h"

#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static int td_ascii_strcasecmp(const char *a, const char *b) {
    if (!a || !b) return (a == b) ? 0 : (a ? 1 : -1);
    while (*a && *b) {
        int ca = tolower((unsigned char)*a);
        int cb = tolower((unsigned char)*b);
        if (ca != cb) return ca - cb;
        a++;
        b++;
    }
    return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}

static int td_force_scalar(void) {
    const char *val = getenv("PERL_FORCE_SCALAR");
    if (!val || !*val) return 0;
    if (strcmp(val, "0") == 0) return 0;
    if (td_ascii_strcasecmp(val, "false") == 0) return 0;
    if (td_ascii_strcasecmp(val, "no") == 0) return 0;
    if (td_ascii_strcasecmp(val, "off") == 0) return 0;
    return 1;
}

static int td_default_workers(void) {
    int cores = tkmt_cpu_count();
    if (cores < 1)  cores = 1;
    if (cores > 16) cores = 16;
    return cores;
}

#if defined(__aarch64__)
#  include <arm_neon.h>
#  define TKMT_TD_HAVE_NEON_F64 1
#else
#  define TKMT_TD_HAVE_NEON_F64 0
#endif

#if defined(__SSE2__) || defined(_M_X64) || defined(_M_AMD64)
#  include <emmintrin.h>
#  define TKMT_TD_HAVE_SSE2_F64 1
#else
#  define TKMT_TD_HAVE_SSE2_F64 0
#endif

/* =========================================================================
 * Lightweight persistent cross-platform worker pool (POSIX + Win32, fork-safe)
 * ========================================================================= */

#define TKMT_TD_MAX_WORKERS 16

typedef void (*td_job_fn_t)(void *ctx, int worker_id, int total_workers);

typedef struct td_pool_state {
    tkmt_static_mutex_t dispatch_lock;
    tkmt_mutex_t        work_lock;
    tkmt_cond_t         work_cv;
    tkmt_cond_t         done_cv;
    int                 sync_inited;

    tkmt_thread_t       threads[TKMT_TD_MAX_WORKERS];
    int                 num_threads;
    int                 shutdown;
    int                 atexit_reg;
    uint64_t            owner_pid;

    uint64_t            generation;
    td_job_fn_t         fn;
    void               *ctx;
    int                 active_helpers;
    int                 total_workers;
    int                 helpers_done;
} td_pool_state_t;

static td_pool_state_t g_td_pool = {
    .dispatch_lock  = TKMT_STATIC_MUTEX_INIT,
    .sync_inited    = 0,
    .num_threads    = 0,
    .shutdown       = 0,
    .atexit_reg     = 0,
    .owner_pid      = 0,
    .generation     = 0,
    .fn             = NULL,
    .ctx            = NULL,
    .active_helpers = 0,
    .total_workers  = 1,
    .helpers_done   = 0,
};

typedef struct td_helper_arg {
    int helper_idx;
} td_helper_arg_t;

static td_helper_arg_t g_td_helper_args[TKMT_TD_MAX_WORKERS];

static tkmt_thread_ret_t TKMT_THREAD_CALL td_pool_worker_main(void *arg) {
    int helper_idx = ((td_helper_arg_t *)arg)->helper_idx;
    int worker_id  = helper_idx + 1;
    uint64_t seen_gen = 0;

    tkmt_mutex_lock(&g_td_pool.work_lock);
    for (;;) {
        while (!g_td_pool.shutdown && g_td_pool.generation == seen_gen) {
            tkmt_cond_wait(&g_td_pool.work_cv, &g_td_pool.work_lock);
        }
        if (g_td_pool.shutdown) {
            tkmt_mutex_unlock(&g_td_pool.work_lock);
            TKMT_THREAD_RETURN_ZERO;
        }
        seen_gen = g_td_pool.generation;
        int participating = (helper_idx < g_td_pool.active_helpers);
        td_job_fn_t fn    = g_td_pool.fn;
        void *ctx         = g_td_pool.ctx;
        int total         = g_td_pool.total_workers;
        tkmt_mutex_unlock(&g_td_pool.work_lock);

        if (participating && fn) {
            fn(ctx, worker_id, total);
        }

        tkmt_mutex_lock(&g_td_pool.work_lock);
        if (participating) {
            g_td_pool.helpers_done++;
            if (g_td_pool.helpers_done >= g_td_pool.active_helpers) {
                tkmt_cond_signal(&g_td_pool.done_cv);
            }
        }
    }
}

static void td_pool_atexit_shutdown(void) {
    if (!g_td_pool.sync_inited || g_td_pool.owner_pid != tkmt_process_id()) return;
    tkmt_mutex_lock(&g_td_pool.work_lock);
    int n = g_td_pool.num_threads;
    if (n <= 0 || g_td_pool.shutdown) {
        tkmt_mutex_unlock(&g_td_pool.work_lock);
        return;
    }
    g_td_pool.shutdown = 1;
    tkmt_cond_broadcast(&g_td_pool.work_cv);
    tkmt_mutex_unlock(&g_td_pool.work_lock);

    for (int i = 0; i < n; i++) {
        tkmt_thread_join(g_td_pool.threads[i]);
    }
    g_td_pool.num_threads = 0;
}

static void td_pool_ensure_helpers_locked(int need_helpers) {
    uint64_t me = tkmt_process_id();
    if (!g_td_pool.sync_inited || (g_td_pool.owner_pid != 0 && g_td_pool.owner_pid != me)) {
        tkmt_mutex_init(&g_td_pool.work_lock);
        tkmt_cond_init(&g_td_pool.work_cv);
        tkmt_cond_init(&g_td_pool.done_cv);
        g_td_pool.sync_inited = 1;
        g_td_pool.num_threads = 0;
        g_td_pool.shutdown    = 0;
        g_td_pool.generation  = 0;
        g_td_pool.owner_pid   = me;
    }
    if (g_td_pool.owner_pid == 0) {
        g_td_pool.owner_pid = me;
    }
    if (!g_td_pool.atexit_reg) {
        atexit(td_pool_atexit_shutdown);
        g_td_pool.atexit_reg = 1;
    }
    if (need_helpers > TKMT_TD_MAX_WORKERS) {
        need_helpers = TKMT_TD_MAX_WORKERS;
    }
    while (g_td_pool.num_threads < need_helpers) {
        int idx = g_td_pool.num_threads;
        g_td_helper_args[idx].helper_idx = idx;
        if (tkmt_thread_create(&g_td_pool.threads[idx], td_pool_worker_main, &g_td_helper_args[idx]) != 0) {
            break;
        }
        g_td_pool.num_threads++;
    }
}

static void td_pool_dispatch(int workers, td_job_fn_t fn, void *ctx) {
    if (workers <= 1) {
        fn(ctx, 0, 1);
        return;
    }
    if (workers > TKMT_TD_MAX_WORKERS) {
        workers = TKMT_TD_MAX_WORKERS;
    }

    tkmt_static_mutex_lock(&g_td_pool.dispatch_lock);
    int want_helpers = workers - 1;
    td_pool_ensure_helpers_locked(want_helpers);

    int active_helpers = (want_helpers <= g_td_pool.num_threads) ? want_helpers : g_td_pool.num_threads;
    int total_workers  = active_helpers + 1;

    if (active_helpers <= 0) {
        tkmt_static_mutex_unlock(&g_td_pool.dispatch_lock);
        fn(ctx, 0, 1);
        return;
    }

    tkmt_mutex_lock(&g_td_pool.work_lock);
    g_td_pool.fn             = fn;
    g_td_pool.ctx            = ctx;
    g_td_pool.active_helpers = active_helpers;
    g_td_pool.total_workers  = total_workers;
    g_td_pool.helpers_done   = 0;
    g_td_pool.generation++;
    tkmt_cond_broadcast(&g_td_pool.work_cv);
    tkmt_mutex_unlock(&g_td_pool.work_lock);

    fn(ctx, 0, total_workers);

    tkmt_mutex_lock(&g_td_pool.work_lock);
    while (g_td_pool.helpers_done < active_helpers) {
        tkmt_cond_wait(&g_td_pool.done_cv, &g_td_pool.work_lock);
    }
    tkmt_mutex_unlock(&g_td_pool.work_lock);

    tkmt_static_mutex_unlock(&g_td_pool.dispatch_lock);
}

/* =========================================================================
 * Helper math & RGBA packing utilities
 * ========================================================================= */

static inline uint8_t td_clamp_u8(double v) {
    if (v <= 0.0)   return 0u;
    if (v >= 255.0) return 255u;
    return (uint8_t)(v + 0.5);
}

static inline uint32_t td_pack_rgba(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    return (uint32_t)r
         | ((uint32_t)g << 8)
         | ((uint32_t)b << 16)
         | ((uint32_t)a << 24);
}

static inline uint32_t td_double_to_u32(double v) {
    if (v <= 0.0) return 0u;
    if (v >= 4294967295.0) return 0xFFFFFFFFu;
    return (uint32_t)(uint64_t)v;
}

/* =========================================================================
 * Kernel 1: tkmt_td_step_particles
 * ========================================================================= */

typedef struct td_particles_ctx {
    double       *px;
    double       *py;
    double       *vx;
    double       *vy;
    double       *life;
    const double *max_life;
    const double *size;
    const double *col_start;
    const double *col_end;
    double       *inst_out;
    size_t        inst_cap;
    size_t        count;
    double        dt;
    double        drag;
    int           force_scalar;

    /* Per-worker counts & prefix-summed output instance offsets */
    size_t        chunk_start[TKMT_TD_MAX_WORKERS];
    size_t        chunk_end[TKMT_TD_MAX_WORKERS];
    size_t        chunk_alive[TKMT_TD_MAX_WORKERS];
    size_t        chunk_inst_off[TKMT_TD_MAX_WORKERS];
} td_particles_ctx_t;

/*
 * Emit two stride-4 instances for a single surviving particle:
 *   slot 0: outer halo (radius * 2.4, alpha * 0.28)
 *   slot 1: inner core (radius, faded alpha)
 * Returns number of instances written (0, 1, or 2 depending on inst_cap).
 */
static inline size_t td_emit_particle_pair(
    double *inst_out,
    size_t  out_idx,
    size_t  inst_cap,
    double  x,
    double  y,
    double  nl,
    double  ml,
    double  rad,
    double  c0_d,
    double  c1_d)
{
    if (out_idx >= inst_cap) return 0u;

    double denom = (ml > 0.0) ? ml : 1.0;
    double rem   = nl / denom;
    if (rem < 0.0) rem = 0.0;
    if (rem > 1.0) rem = 1.0;
    double age  = 1.0 - rem;
    /* Quadratic ease-out fade */
    double fade = rem * (2.0 - rem);

    uint32_t c0 = td_double_to_u32(c0_d);
    uint32_t c1 = td_double_to_u32(c1_d);

    double r0 = (double)(c0 & 0xFFu);
    double g0 = (double)((c0 >> 8) & 0xFFu);
    double b0 = (double)((c0 >> 16) & 0xFFu);
    double a0 = (double)((c0 >> 24) & 0xFFu);

    double r1 = (double)(c1 & 0xFFu);
    double g1 = (double)((c1 >> 8) & 0xFFu);
    double b1 = (double)((c1 >> 16) & 0xFFu);
    double a1 = (double)((c1 >> 24) & 0xFFu);

    uint8_t cr = td_clamp_u8(r0 + ((r1 - r0) * age));
    uint8_t cg = td_clamp_u8(g0 + ((g1 - g0) * age));
    uint8_t cb = td_clamp_u8(b0 + ((b1 - b0) * age));
    double  af = (a0 + ((a1 - a0) * age)) * fade;

    uint8_t core_a = td_clamp_u8(af);
    uint8_t halo_a = td_clamp_u8(af * 0.28);

    uint32_t halo_rgba = td_pack_rgba(cr, cg, cb, halo_a);
    uint32_t core_rgba = td_pack_rgba(cr, cg, cb, core_a);

    /* Instance 0: outer halo */
    double *dst = inst_out + (out_idx * 4u);
    dst[0] = x;
    dst[1] = y;
    dst[2] = (double)halo_rgba;
    dst[3] = rad * 2.4;

    if (out_idx + 1u >= inst_cap) return 1u;

    /* Instance 1: inner core */
    dst[4] = x;
    dst[5] = y;
    dst[6] = (double)core_rgba;
    dst[7] = rad;
    return 2u;
}

static size_t td_integrate_scalar_range(
    const td_particles_ctx_t *c,
    size_t start,
    size_t end)
{
    double *px   = c->px;
    double *py   = c->py;
    double *vx   = c->vx;
    double *vy   = c->vy;
    double *life = c->life;
    const double dt   = c->dt;
    const double drag = c->drag;

    size_t alive = 0u;
    for (size_t i = start; i < end; i++) {
        double l = life[i];
        if (l <= 0.0) continue;

        double cvx = vx[i];
        double cvy = vy[i];
        double nx  = px[i] + (cvx * dt);
        double ny  = py[i] + (cvy * dt);
        double nvx = cvx * drag;
        double nvy = cvy * drag;
        double nl  = l - dt;
        if (nl <= 0.0) {
            nl = 0.0;
        } else {
            alive++;
        }

        px[i]   = nx;
        py[i]   = ny;
        vx[i]   = nvx;
        vy[i]   = nvy;
        life[i] = nl;
    }
    return alive;
}

#if TKMT_TD_HAVE_NEON_F64
static size_t td_integrate_neon_range(
    const td_particles_ctx_t *c,
    size_t start,
    size_t end)
{
    double *px   = c->px;
    double *py   = c->py;
    double *vx   = c->vx;
    double *vy   = c->vy;
    double *life = c->life;

    const float64x2_t vdt   = vdupq_n_f64(c->dt);
    const float64x2_t vdrag = vdupq_n_f64(c->drag);
    const float64x2_t vzero = vdupq_n_f64(0.0);

    size_t alive = 0u;
    size_t i = start;
    for (; i + 1u < end; i += 2u) {
        float64x2_t vl = vld1q_f64(life + i);
        uint64x2_t  m_live = vcgtq_f64(vl, vzero);
        uint64_t    m0 = vgetq_lane_u64(m_live, 0);
        uint64_t    m1 = vgetq_lane_u64(m_live, 1);
        if ((m0 | m1) == 0u) continue;

        float64x2_t vpx = vld1q_f64(px + i);
        float64x2_t vpy = vld1q_f64(py + i);
        float64x2_t vvx = vld1q_f64(vx + i);
        float64x2_t vvy = vld1q_f64(vy + i);

        float64x2_t vnx  = vaddq_f64(vpx, vmulq_f64(vvx, vdt));
        float64x2_t vny  = vaddq_f64(vpy, vmulq_f64(vvy, vdt));
        float64x2_t vnvx = vmulq_f64(vvx, vdrag);
        float64x2_t vnvy = vmulq_f64(vvy, vdrag);
        float64x2_t vnl  = vsubq_f64(vl, vdt);

        uint64x2_t  m_surv = vcgtq_f64(vnl, vzero);
        vnl = vbslq_f64(m_surv, vnl, vzero);

        vpx = vbslq_f64(m_live, vnx,  vpx);
        vpy = vbslq_f64(m_live, vny,  vpy);
        vvx = vbslq_f64(m_live, vnvx, vvx);
        vvy = vbslq_f64(m_live, vnvy, vvy);
        vl  = vbslq_f64(m_live, vnl,  vl);

        vst1q_f64(px + i,   vpx);
        vst1q_f64(py + i,   vpy);
        vst1q_f64(vx + i,   vvx);
        vst1q_f64(vy + i,   vvy);
        vst1q_f64(life + i, vl);

        if (m0 && vgetq_lane_u64(m_surv, 0)) alive++;
        if (m1 && vgetq_lane_u64(m_surv, 1)) alive++;
    }

    if (i < end) {
        alive += td_integrate_scalar_range(c, i, end);
    }
    return alive;
}
#elif TKMT_TD_HAVE_SSE2_F64
static size_t td_integrate_sse2_range(
    const td_particles_ctx_t *c,
    size_t start,
    size_t end)
{
    double *px   = c->px;
    double *py   = c->py;
    double *vx   = c->vx;
    double *vy   = c->vy;
    double *life = c->life;

    const __m128d vdt   = _mm_set1_pd(c->dt);
    const __m128d vdrag = _mm_set1_pd(c->drag);
    const __m128d vzero = _mm_setzero_pd();

    size_t alive = 0u;
    size_t i = start;
    for (; i + 1u < end; i += 2u) {
        __m128d vl     = _mm_loadu_pd(life + i);
        __m128d m_live = _mm_cmpgt_pd(vl, vzero);
        int     mask   = _mm_movemask_pd(m_live);
        if (mask == 0) continue;

        __m128d vpx = _mm_loadu_pd(px + i);
        __m128d vpy = _mm_loadu_pd(py + i);
        __m128d vvx = _mm_loadu_pd(vx + i);
        __m128d vvy = _mm_loadu_pd(vy + i);

        __m128d vnx  = _mm_add_pd(vpx, _mm_mul_pd(vvx, vdt));
        __m128d vny  = _mm_add_pd(vpy, _mm_mul_pd(vvy, vdt));
        __m128d vnvx = _mm_mul_pd(vvx, vdrag);
        __m128d vnvy = _mm_mul_pd(vvy, vdrag);
        __m128d vnl  = _mm_sub_pd(vl, vdt);

        __m128d m_surv = _mm_cmpgt_pd(vnl, vzero);
        vnl = _mm_and_pd(m_surv, vnl);

        vpx = _mm_or_pd(_mm_and_pd(m_live, vnx),  _mm_andnot_pd(m_live, vpx));
        vpy = _mm_or_pd(_mm_and_pd(m_live, vny),  _mm_andnot_pd(m_live, vpy));
        vvx = _mm_or_pd(_mm_and_pd(m_live, vnvx), _mm_andnot_pd(m_live, vvx));
        vvy = _mm_or_pd(_mm_and_pd(m_live, vnvy), _mm_andnot_pd(m_live, vvy));
        vl  = _mm_or_pd(_mm_and_pd(m_live, vnl),  _mm_andnot_pd(m_live, vl));

        _mm_storeu_pd(px + i,   vpx);
        _mm_storeu_pd(py + i,   vpy);
        _mm_storeu_pd(vx + i,   vvx);
        _mm_storeu_pd(vy + i,   vvy);
        _mm_storeu_pd(life + i, vl);

        int surv_mask = mask & _mm_movemask_pd(m_surv);
        if (surv_mask & 1) alive++;
        if (surv_mask & 2) alive++;
    }

    if (i < end) {
        alive += td_integrate_scalar_range(c, i, end);
    }
    return alive;
}
#endif

static void td_particles_pass1_worker(void *vctx, int worker_id, int total_workers) {
    td_particles_ctx_t *c = (td_particles_ctx_t *)vctx;
    (void)total_workers;
    size_t start = c->chunk_start[worker_id];
    size_t end   = c->chunk_end[worker_id];
    if (start >= end) {
        c->chunk_alive[worker_id] = 0u;
        return;
    }

    if (c->force_scalar) {
        c->chunk_alive[worker_id] = td_integrate_scalar_range(c, start, end);
        return;
    }
#if TKMT_TD_HAVE_NEON_F64
    c->chunk_alive[worker_id] = td_integrate_neon_range(c, start, end);
#elif TKMT_TD_HAVE_SSE2_F64
    c->chunk_alive[worker_id] = td_integrate_sse2_range(c, start, end);
#else
    c->chunk_alive[worker_id] = td_integrate_scalar_range(c, start, end);
#endif
}

static void td_particles_pass2_worker(void *vctx, int worker_id, int total_workers) {
    const td_particles_ctx_t *c = (const td_particles_ctx_t *)vctx;
    (void)total_workers;
    size_t start   = c->chunk_start[worker_id];
    size_t end     = c->chunk_end[worker_id];
    size_t out_idx = c->chunk_inst_off[worker_id];
    size_t cap     = c->inst_cap;
    if (start >= end || out_idx >= cap || c->chunk_alive[worker_id] == 0u) {
        return;
    }

    const double *px        = c->px;
    const double *py        = c->py;
    const double *life      = c->life;
    const double *max_life  = c->max_life;
    const double *size      = c->size;
    const double *col_start = c->col_start;
    const double *col_end   = c->col_end;
    double       *inst_out  = c->inst_out;

    for (size_t i = start; i < end && out_idx < cap; i++) {
        double nl = life[i];
        if (nl <= 0.0) continue;
        out_idx += td_emit_particle_pair(
            inst_out, out_idx, cap,
            px[i], py[i], nl, max_life[i], size[i],
            col_start[i], col_end[i]);
    }
}

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
    int           workers)
{
    if (!px || !py || !vx || !vy || !life || !max_life || !size || !col_start || !col_end || count == 0u) {
        if (inst_out && inst_cap > 0u) {
            memset(inst_out, 0, inst_cap * 4u * sizeof(double));
        }
        return 0u;
    }

    int force_scalar = td_force_scalar();
    int use_workers;
    if (force_scalar) {
        use_workers = 1;
    } else if (workers <= 0) {
        use_workers = (count < 2048u) ? 1 : td_default_workers();
    } else {
        use_workers = workers;
    }
    if (use_workers > TKMT_TD_MAX_WORKERS) {
        use_workers = TKMT_TD_MAX_WORKERS;
    }
    size_t blocks = (count + 7u) / 8u;
    if ((size_t)use_workers > blocks) {
        use_workers = (int)blocks;
    }
    if (use_workers < 1) use_workers = 1;

    /* Fast single-pass scalar path when single-threaded and forced scalar (or small count) */
    if (use_workers == 1 && (force_scalar || count < 256u)) {
        size_t out_idx = 0u;
        for (size_t i = 0; i < count; i++) {
            double l = life[i];
            if (l <= 0.0) continue;

            double cvx = vx[i];
            double cvy = vy[i];
            double nx  = px[i] + (cvx * dt);
            double ny  = py[i] + (cvy * dt);
            double nvx = cvx * drag;
            double nvy = cvy * drag;
            double nl  = l - dt;
            if (nl <= 0.0) {
                nl = 0.0;
            }

            px[i]   = nx;
            py[i]   = ny;
            vx[i]   = nvx;
            vy[i]   = nvy;
            life[i] = nl;

            if (nl > 0.0 && inst_out && out_idx < inst_cap) {
                out_idx += td_emit_particle_pair(
                    inst_out, out_idx, inst_cap,
                    nx, ny, nl, max_life[i], size[i],
                    col_start[i], col_end[i]);
            }
        }
        if (inst_out && out_idx < inst_cap) {
            memset(inst_out + (out_idx * 4u), 0, (inst_cap - out_idx) * 4u * sizeof(double));
        }
        return out_idx;
    }

    td_particles_ctx_t ctx;
    ctx.px           = px;
    ctx.py           = py;
    ctx.vx           = vx;
    ctx.vy           = vy;
    ctx.life         = life;
    ctx.max_life     = max_life;
    ctx.size         = size;
    ctx.col_start    = col_start;
    ctx.col_end      = col_end;
    ctx.inst_out     = inst_out;
    ctx.inst_cap     = inst_cap;
    ctx.count        = count;
    ctx.dt           = dt;
    ctx.drag         = drag;
    ctx.force_scalar = force_scalar;

    /* Partition into 8-double cache-line-aligned chunks */
    for (int w = 0; w < use_workers; w++) {
        size_t b0 = (blocks * (size_t)w) / (size_t)use_workers;
        size_t b1 = (blocks * (size_t)(w + 1)) / (size_t)use_workers;
        size_t s  = b0 * 8u;
        size_t e  = b1 * 8u;
        if (s > count) s = count;
        if (e > count) e = count;
        ctx.chunk_start[w]    = s;
        ctx.chunk_end[w]      = e;
        ctx.chunk_alive[w]    = 0u;
        ctx.chunk_inst_off[w] = 0u;
    }

    /* Pass 1: integrate physics in parallel & count alive per chunk */
    td_pool_dispatch(use_workers, td_particles_pass1_worker, &ctx);

    /* Prefix sum alive counts -> deterministic instance output offsets */
    size_t total_inst = 0u;
    for (int w = 0; w < use_workers; w++) {
        ctx.chunk_inst_off[w] = total_inst;
        total_inst += ctx.chunk_alive[w] * 2u;
    }
    size_t written = (total_inst < inst_cap) ? total_inst : inst_cap;

    /* Pass 2: emit halo + core instances in parallel at exact deterministic offsets */
    if (inst_out && written > 0u) {
        td_pool_dispatch(use_workers, td_particles_pass2_worker, &ctx);
    }

    /* Zero unused tail slots */
    if (inst_out && written < inst_cap) {
        memset(inst_out + (written * 4u), 0, (inst_cap - written) * 4u * sizeof(double));
    }

    return written;
}

/* =========================================================================
 * Kernel 2: tkmt_td_render_backdrop_rgba8
 * ========================================================================= */

typedef struct td_seg {
    double ax;
    double ay;
    double dx;
    double dy;
    double inv_len2;
    double len;
    double cum_len;
} td_seg_t;

typedef struct td_backdrop_ctx {
    uint8_t        *rgba_out;
    uint32_t        w;
    uint32_t        h;
    double          inv_w;
    double          inv_h;
    double          half_w;
    double          half_h;
    uint32_t        grid_cols;
    uint32_t        grid_rows;
    double          cell_w;
    double          cell_h;
    double          lane_half_w;
    const td_seg_t *segs;
    size_t          num_segs;
    int             has_spawn;
    double          spawn_x;
    double          spawn_y;
    int             has_bastion;
    double          bastion_x;
    double          bastion_y;
    double          time_sec;
    double          spawn_pulse;
    double          bastion_pulse;
    _Atomic uint32_t next_row;
} td_backdrop_ctx_t;

static inline double td_smoothstep(double edge0, double edge1, double x) {
    double t = (x - edge0) / (edge1 - edge0);
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    return t * t * (3.0 - (2.0 * t));
}

static void td_render_backdrop_row(const td_backdrop_ctx_t *c, uint32_t py) {
    uint8_t       *row = c->rgba_out + ((size_t)py * (size_t)c->w * 4u);
    const uint32_t w   = c->w;
    const double   y   = (double)py + 0.5;

    /* Normalized radial coords for background gradient & vignette */
    const double ny  = (y - c->half_h) / c->half_h;
    const double ny2 = ny * ny;

    /* Grid row metrics */
    const int    has_grid = (c->grid_cols > 0u && c->grid_rows > 0u && c->cell_w > 1.0 && c->cell_h > 1.0);
    double       gy_dist  = 100.0;
    double       gy_frac  = 0.5;
    if (has_grid) {
        double gpos = y / c->cell_h;
        gy_frac = gpos - floor(gpos);
        double d0 = gy_frac * c->cell_h;
        double d1 = (1.0 - gy_frac) * c->cell_h;
        gy_dist = (d0 < d1) ? d0 : d1;
    }

    const double dy_spawn   = y - c->spawn_y;
    const double dy_spawn2  = dy_spawn * dy_spawn;
    const double dy_bast    = y - c->bastion_y;
    const double dy_bast2   = dy_bast * dy_bast;

    const double lane_hw    = c->lane_half_w;
    const double lane_hw2   = lane_hw * lane_hw;
    const double rail_outer = (lane_hw + 3.0) * (lane_hw + 3.0);
    const double pulse_off  = c->time_sec * 110.0;

    for (uint32_t px = 0; px < w; px++) {
        const double x   = (double)px + 0.5;
        const double nx  = (x - c->half_w) / c->half_w;
        const double r2  = (nx * nx) + ny2;

        /* 1. Radial background gradient */
        double bg_grad = 1.0 - (r2 * 0.42);
        if (bg_grad < 0.0) bg_grad = 0.0;
        double rr = 4.0  + (11.0 * bg_grad);
        double gg = 6.0  + (15.0 * bg_grad);
        double bb = 14.0 + (28.0 * bg_grad);

        /* 2. Grid lines and intersection pips */
        if (has_grid) {
            double gposx   = x / c->cell_w;
            double gx_frac = gposx - floor(gposx);
            double dx0     = gx_frac * c->cell_w;
            double dx1     = (1.0 - gx_frac) * c->cell_w;
            double gx_dist = (dx0 < dx1) ? dx0 : dx1;
            double g_min   = (gx_dist < gy_dist) ? gx_dist : gy_dist;

            if (g_min < 1.25) {
                double line_a = (1.25 - g_min) * 0.8;
                rr += 14.0 * line_a;
                gg += 34.0 * line_a;
                bb += 58.0 * line_a;
            }

            /* Grid vertex pips */
            double corner_d2 = (gx_dist * gx_dist) + (gy_dist * gy_dist);
            if (corner_d2 < 12.25) {
                double pip = 1.0 - (corner_d2 / 12.25);
                pip = pip * pip;
                rr += 24.0 * pip;
                gg += 72.0 * pip;
                bb += 105.0 * pip;
            }

            /* Faint diagonal tile line */
            double diag = fabs((gx_frac + gy_frac) - 1.0);
            if (diag < 0.025) {
                double da = (0.025 - diag) * 40.0;
                rr += 3.5 * da;
                gg += 9.0 * da;
                bb += 16.0 * da;
            }
        }

        /* 3. Distance-field path conduit along waypoints */
        if (c->num_segs > 0u) {
            double min_d2   = 1.0e30;
            double best_s   = 0.0;
            const td_seg_t *segs = c->segs;
            const size_t nsegs   = c->num_segs;

            for (size_t s = 0; s < nsegs; s++) {
                double px_ax = x - segs[s].ax;
                double py_ay = y - segs[s].ay;
                double t     = ((px_ax * segs[s].dx) + (py_ay * segs[s].dy)) * segs[s].inv_len2;
                if (t < 0.0) t = 0.0;
                if (t > 1.0) t = 1.0;
                double cx = px_ax - (t * segs[s].dx);
                double cy = py_ay - (t * segs[s].dy);
                double d2 = (cx * cx) + (cy * cy);
                if (d2 < min_d2) {
                    min_d2 = d2;
                    best_s = segs[s].cum_len + (t * segs[s].len);
                }
            }

            /* Darkened lane bed */
            if (min_d2 < lane_hw2) {
                rr = (rr * 0.42) + 2.0;
                gg = (gg * 0.48) + 6.0;
                bb = (bb * 0.56) + 14.0;
            }

            /* Outer distance-field bloom */
            double bloom = 1.0 / (1.0 + (min_d2 * 0.0014));
            double bloom2 = bloom * bloom;
            rr += 10.0  * bloom2;
            gg += 92.0  * bloom2;
            bb += 155.0 * bloom2;

            /* Inner glow, center line, and lane rails */
            if (min_d2 < rail_outer) {
                double d = sqrt(min_d2);

                /* Lane edge rails */
                double rail_d = fabs(d - lane_hw);
                if (rail_d < 2.2) {
                    double rail = 1.0 - (rail_d / 2.2);
                    rail = rail * rail;
                    rr += 28.0  * rail;
                    gg += 150.0 * rail;
                    bb += 210.0 * rail;
                }

                /* Traveling pulse along path */
                double wave = 0.78 + (0.22 * sin((best_s - pulse_off) * 0.065));

                /* Inner cyan glow */
                double inner = 1.0 / (1.0 + (min_d2 * 0.025));
                rr += 25.0  * inner * wave;
                gg += 155.0 * inner * wave;
                bb += 215.0 * inner * wave;

                /* Center filament */
                if (d < 4.5) {
                    double core = 1.0 - (d / 4.5);
                    core = core * core;
                    rr += 140.0 * core * wave;
                    gg += 235.0 * core * wave;
                    bb += 255.0 * core * wave;
                }
            }
        }

        /* 4. Spawn portal glow at waypoint[0] */
        if (c->has_spawn) {
            double dx = x - c->spawn_x;
            double d2 = (dx * dx) + dy_spawn2;
            double aura = 1.0 / (1.0 + (d2 * 0.00055));
            double aura2 = aura * aura * c->spawn_pulse;
            rr += 225.0 * aura2;
            gg += 24.0  * aura2;
            bb += 62.0  * aura2;

            if (d2 < 1600.0) {
                double d = sqrt(d2);
                double ring_d = fabs(d - 22.0);
                if (ring_d < 3.5) {
                    double ring = 1.0 - (ring_d / 3.5);
                    ring = ring * ring;
                    rr += 255.0 * ring;
                    gg += 55.0  * ring;
                    bb += 110.0 * ring;
                }
                if (d < 10.0) {
                    double core = 1.0 - (d / 10.0);
                    core = core * core;
                    rr = rr * (1.0 - core) + (255.0 * core);
                    gg = gg * (1.0 - core) + (75.0  * core);
                    bb = bb * (1.0 - core) + (115.0 * core);
                }
            }
        }

        /* 5. Bastion core glow at waypoint[-1] */
        if (c->has_bastion) {
            double dx = x - c->bastion_x;
            double d2 = (dx * dx) + dy_bast2;
            double aura = 1.0 / (1.0 + (d2 * 0.00050));
            double aura2 = aura * aura * c->bastion_pulse;
            rr += 22.0  * aura2;
            gg += 220.0 * aura2;
            bb += 175.0 * aura2;

            if (d2 < 2025.0) {
                double d = sqrt(d2);
                double ring_d = fabs(d - 26.0);
                if (ring_d < 3.5) {
                    double ring = 1.0 - (ring_d / 3.5);
                    ring = ring * ring;
                    rr += 45.0  * ring;
                    gg += 255.0 * ring;
                    bb += 210.0 * ring;
                }
                double ring2_d = fabs(d - 16.0);
                if (ring2_d < 2.2) {
                    double ring2 = 1.0 - (ring2_d / 2.2);
                    ring2 = ring2 * ring2;
                    rr += 90.0  * ring2;
                    gg += 255.0 * ring2;
                    bb += 235.0 * ring2;
                }
                if (d < 9.0) {
                    double core = 1.0 - (d / 9.0);
                    core = core * core;
                    rr += 175.0 * core;
                    gg += 255.0 * core;
                    bb += 245.0 * core;
                }
            }
        }

        /* 6. Edge vignette */
        double vig = 1.0 - (0.38 * td_smoothstep(0.55, 1.85, r2));
        rr *= vig;
        gg *= vig;
        bb *= vig;

        uint8_t *dst = row + ((size_t)px * 4u);
        dst[0] = td_clamp_u8(rr);
        dst[1] = td_clamp_u8(gg);
        dst[2] = td_clamp_u8(bb);
        dst[3] = 255u;
    }
}

static void td_backdrop_worker_fn(void *vctx, int worker_id, int total_workers) {
    td_backdrop_ctx_t *c = (td_backdrop_ctx_t *)vctx;
    (void)worker_id;
    (void)total_workers;

    const uint32_t h    = c->h;
    const uint32_t tile = 8u;
    for (;;) {
        uint32_t y0 = atomic_fetch_add_explicit(&c->next_row, tile, memory_order_relaxed);
        if (y0 >= h) break;
        uint32_t y1 = y0 + tile;
        if (y1 > h) y1 = h;
        for (uint32_t y = y0; y < y1; y++) {
            td_render_backdrop_row(c, y);
        }
    }
}

int tkmt_td_render_backdrop_rgba8(
    uint8_t      *rgba_out,
    uint32_t      w,
    uint32_t      h,
    uint32_t      grid_cols,
    uint32_t      grid_rows,
    const double *waypoints_xy,
    size_t        num_waypoints,
    double        time_sec,
    int           workers)
{
    if (!rgba_out || w == 0u || h == 0u) {
        return -1;
    }

    td_seg_t stack_segs[64];
    td_seg_t *segs = NULL;
    int segs_heap  = 0;
    size_t num_segs = 0u;

    if (waypoints_xy && num_waypoints >= 2u) {
        num_segs = num_waypoints - 1u;
        if (num_segs <= 64u) {
            segs = stack_segs;
        } else {
            segs = (td_seg_t *)malloc(num_segs * sizeof(td_seg_t));
            if (!segs) return -1;
            segs_heap = 1;
        }
        double cum = 0.0;
        for (size_t i = 0; i < num_segs; i++) {
            double ax = waypoints_xy[(i * 2u) + 0u];
            double ay = waypoints_xy[(i * 2u) + 1u];
            double bx = waypoints_xy[((i + 1u) * 2u) + 0u];
            double by = waypoints_xy[((i + 1u) * 2u) + 1u];
            double dx = bx - ax;
            double dy = by - ay;
            double l2 = (dx * dx) + (dy * dy);
            double len = (l2 > 0.0) ? sqrt(l2) : 0.0;
            segs[i].ax       = ax;
            segs[i].ay       = ay;
            segs[i].dx       = dx;
            segs[i].dy       = dy;
            segs[i].inv_len2 = (l2 > 1.0e-12) ? (1.0 / l2) : 0.0;
            segs[i].len      = len;
            segs[i].cum_len  = cum;
            cum += len;
        }
    }

    td_backdrop_ctx_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.rgba_out    = rgba_out;
    ctx.w           = w;
    ctx.h           = h;
    ctx.inv_w       = 1.0 / (double)w;
    ctx.inv_h       = 1.0 / (double)h;
    ctx.half_w      = (double)w * 0.5;
    ctx.half_h      = (double)h * 0.5;
    ctx.grid_cols   = grid_cols;
    ctx.grid_rows   = grid_rows;
    ctx.cell_w      = (grid_cols > 0u) ? ((double)w / (double)grid_cols) : 0.0;
    ctx.cell_h      = (grid_rows > 0u) ? ((double)h / (double)grid_rows) : 0.0;

    double min_cell = (ctx.cell_w > 0.0 && ctx.cell_h > 0.0)
                    ? ((ctx.cell_w < ctx.cell_h) ? ctx.cell_w : ctx.cell_h)
                    : 48.0;
    ctx.lane_half_w = min_cell * 0.36;
    if (ctx.lane_half_w < 10.0) ctx.lane_half_w = 10.0;
    if (ctx.lane_half_w > 34.0) ctx.lane_half_w = 34.0;

    ctx.segs     = segs;
    ctx.num_segs = num_segs;
    if (waypoints_xy && num_waypoints >= 1u) {
        ctx.has_spawn = 1;
        ctx.spawn_x   = waypoints_xy[0];
        ctx.spawn_y   = waypoints_xy[1];
    }
    if (waypoints_xy && num_waypoints >= 2u) {
        ctx.has_bastion = 1;
        ctx.bastion_x   = waypoints_xy[((num_waypoints - 1u) * 2u) + 0u];
        ctx.bastion_y   = waypoints_xy[((num_waypoints - 1u) * 2u) + 1u];
    }

    ctx.time_sec      = time_sec;
    ctx.spawn_pulse   = 0.90 + (0.10 * sin(time_sec * 3.2));
    ctx.bastion_pulse = 0.90 + (0.10 * cos(time_sec * 2.6));
    atomic_init(&ctx.next_row, 0u);

    int force_scalar = td_force_scalar();
    int use_workers;
    if (force_scalar) {
        use_workers = 1;
    } else if (workers <= 0) {
        use_workers = ((size_t)w * (size_t)h < 4096u) ? 1 : td_default_workers();
    } else {
        use_workers = workers;
    }
    if (use_workers > TKMT_TD_MAX_WORKERS) {
        use_workers = TKMT_TD_MAX_WORKERS;
    }
    if (use_workers < 1) use_workers = 1;

    if (use_workers == 1) {
        for (uint32_t y = 0; y < h; y++) {
            td_render_backdrop_row(&ctx, y);
        }
    } else {
        td_pool_dispatch(use_workers, td_backdrop_worker_fn, &ctx);
    }

    if (segs_heap) {
        free(segs);
    }
    return 0;
}
