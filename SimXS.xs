/*
 * SimXS.xs - PERL_XS_THREADSAFE XS bindings for NeonBastion::SimXS
 *
 * Exposes:
 *   - NeonBastion::SimXS::step_particles
 *   - NeonBastion::SimXS::render_backdrop_rgba8
 *   - NeonBastion::SimXS::is_perl5_mt
 *   - NeonBastion::SimXS::have_packed_av
 *   - NeonBastion::SimXS::av_packed_type
 *
 * Uses perl5-mt SVf_PACKED_AV (NV/U8) directly when available, falling back
 * to standard AV access on stock Perl 5. Honors PERL_FORCE_SCALAR=1.
 *
 * Instance output layout (inst_aref): stride-4 doubles per instance
 * [x, y, (double)rgba_u32, radius], 2 instances (halo, core) per live particle.
 */

#include "c/mt_compat.h"
#include "c/td_sim.h"

#include <string.h>

/* -------------------------------------------------------------------------
 * Zero-copy mutable packed-AV helpers (with stock Perl 5 fallback)
 * ------------------------------------------------------------------------- */

static int nb_av_rw_nv(
    pTHX_ SV *aref, size_t min_len, int read_in,
    double **out_buf, size_t *out_len, int *out_owned, AV **out_av,
    const char *label)
{
    *out_buf   = NULL;
    *out_len   = 0;
    *out_owned = 0;
    *out_av    = NULL;

    if (!aref || !SvROK(aref) || SvTYPE(SvRV(aref)) != SVt_PVAV) {
        croak("%s: expected arrayref", label);
    }
    AV *av = (AV *)SvRV(aref);
    SSize_t top = av_top_index(av);
    size_t len = (top < 0) ? 0u : (size_t)(top + 1);
    if (len < min_len) {
        croak("%s: array too small (%zu < %zu)", label, len, min_len);
    }
    *out_len = len;
    *out_av  = av;

    if (min_len == 0u) {
        return 1;
    }

#if TKMT_HAVE_PACKED_AV
    if (AvPACKED_TYPE(av) == AV_PACKED_NV && sizeof(NV) == sizeof(double)) {
        *out_buf   = (double *)AvPACKED_DATA(av);
        *out_owned = 0;
        return 1;
    }
#endif

    double *tmp = (double *)malloc(min_len * sizeof(double));
    if (!tmp) return 0;

    if (read_in) {
#if TKMT_HAVE_PACKED_AV
        U8 ptype = AvPACKED_TYPE(av);
        if (ptype == AV_PACKED_NV) {
            const NV *src = (const NV *)AvPACKED_DATA(av);
            for (size_t i = 0; i < min_len; i++) tmp[i] = (double)src[i];
        } else if (ptype == AV_PACKED_IV) {
            const IV *src = (const IV *)AvPACKED_DATA(av);
            for (size_t i = 0; i < min_len; i++) tmp[i] = (double)src[i];
        } else if (ptype == AV_PACKED_U8) {
            const U8 *src = (const U8 *)AvPACKED_DATA(av);
            for (size_t i = 0; i < min_len; i++) tmp[i] = (double)src[i];
        } else
#endif
        {
            for (size_t i = 0; i < min_len; i++) {
                SV **svp = av_fetch(av, (SSize_t)i, 0);
                tmp[i] = (svp && *svp) ? (double)SvNV(*svp) : 0.0;
            }
        }
    }

    *out_buf   = tmp;
    *out_owned = 1;
    return 1;
}

static void nb_av_commit_nv(pTHX_ AV *av, double *buf, size_t write_len, int owned) {
    if (!owned) return;
    if (av && buf && write_len > 0u) {
        for (size_t i = 0; i < write_len; i++) {
            SV **svp = av_fetch(av, (SSize_t)i, 1);
            if (svp && *svp) {
                sv_setnv(*svp, (NV)buf[i]);
            }
        }
    }
    free(buf);
}

static int nb_av_rw_u8(
    pTHX_ SV *out_sv, size_t need_bytes,
    uint8_t **out_buf, int *out_owned, AV **out_av,
    const char *label)
{
    *out_buf   = NULL;
    *out_owned = 0;
    *out_av    = NULL;

    if (!out_sv) croak("%s: output buffer required", label);

    if (SvROK(out_sv) && SvTYPE(SvRV(out_sv)) == SVt_PVAV) {
        AV *av = (AV *)SvRV(out_sv);
        SSize_t top = av_top_index(av);
        size_t len = (top < 0) ? 0u : (size_t)(top + 1);
        if (len < need_bytes) {
            croak("%s: output array too small (%zu < %zu)", label, len, need_bytes);
        }
        *out_av = av;

#if TKMT_HAVE_PACKED_AV
        if (AvPACKED_TYPE(av) == AV_PACKED_U8) {
            *out_buf   = (uint8_t *)AvPACKED_DATA(av);
            *out_owned = 0;
            return 1;
        }
#endif
        uint8_t *tmp = (uint8_t *)malloc(need_bytes ? need_bytes : 1u);
        if (!tmp) return 0;
        *out_buf   = tmp;
        *out_owned = 1;
        return 1;
    }

    if (!SvREADONLY(out_sv)) {
        if (!SvPOK(out_sv)) {
            sv_setpvn(out_sv, "", 0);
        }
        SvPOK_only(out_sv);
        char *dst = SvGROW(out_sv, need_bytes + 1u);
        *out_buf   = (uint8_t *)dst;
        *out_owned = 2; /* direct PV scalar write */
        return 1;
    }

    croak("%s: output buffer must be a mutable U8 arrayref or writable byte scalar", label);
    return 0;
}

static void nb_av_commit_u8(pTHX_ SV *out_sv, AV *av, uint8_t *buf, size_t len, int owned) {
    if (owned == 0) {
        return; /* zero-copy packed U8 AV already written in place */
    }
    if (owned == 2) {
        SvCUR_set(out_sv, len);
        buf[len] = '\0';
        return;
    }
    if (owned == 1) {
        if (av && buf && len > 0u) {
            for (size_t i = 0; i < len; i++) {
                SV **svp = av_fetch(av, (SSize_t)i, 1);
                if (svp && *svp) {
                    sv_setuv(*svp, (UV)buf[i]);
                }
            }
        }
        free(buf);
    }
}

/* ========================================================================= */

MODULE = NeonBastion::SimXS   PACKAGE = NeonBastion::SimXS

PROTOTYPES: DISABLE

int
is_perl5_mt()
    CODE:
        RETVAL = TKMT_IS_PERL5_MT;
    OUTPUT:
        RETVAL

int
have_packed_av()
    CODE:
        RETVAL = TKMT_HAVE_PACKED_AV;
    OUTPUT:
        RETVAL

int
av_packed_type(aref)
        SV *aref
    CODE:
        RETVAL = 0;
#if TKMT_HAVE_PACKED_AV
        if (aref && SvROK(aref) && SvTYPE(SvRV(aref)) == SVt_PVAV) {
            RETVAL = (int)AvPACKED_TYPE((AV *)SvRV(aref));
        }
#endif
    OUTPUT:
        RETVAL

UV
step_particles(px_aref, py_aref, vx_aref, vy_aref, life_aref, max_life_aref, size_aref, col_start_aref, col_end_aref, inst_aref, count, dt, drag, workers = 0)
        SV *px_aref
        SV *py_aref
        SV *vx_aref
        SV *vy_aref
        SV *life_aref
        SV *max_life_aref
        SV *size_aref
        SV *col_start_aref
        SV *col_end_aref
        SV *inst_aref
        UV count
        double dt
        double drag
        int workers
    CODE:
        if (!inst_aref || !SvROK(inst_aref) || SvTYPE(SvRV(inst_aref)) != SVt_PVAV) {
            croak("step_particles(inst_out): expected arrayref");
        }
        AV *inst_av_chk = (AV *)SvRV(inst_aref);
        SSize_t inst_top = av_top_index(inst_av_chk);
        size_t inst_total = (inst_top < 0) ? 0u : (size_t)(inst_top + 1);
        size_t inst_cap = inst_total / 4u;

        if (count == 0) {
            if (inst_cap > 0u) {
                double *inst = NULL;
                size_t inst_len = 0;
                int inst_own = 0;
                AV *inst_av = NULL;
                if (nb_av_rw_nv(aTHX_ inst_aref, inst_cap * 4u, 0, &inst, &inst_len, &inst_own, &inst_av, "step_particles(inst_out)")) {
                    memset(inst, 0, inst_cap * 4u * sizeof(double));
                    nb_av_commit_nv(aTHX_ inst_av, inst, inst_cap * 4u, inst_own);
                }
            }
            RETVAL = 0;
        } else {
            double *px = NULL, *py = NULL, *vx = NULL, *vy = NULL, *life = NULL;
            double *max_life = NULL, *size = NULL, *col_start = NULL, *col_end = NULL, *inst = NULL;
            size_t px_len = 0, py_len = 0, vx_len = 0, vy_len = 0, life_len = 0;
            size_t ml_len = 0, sz_len = 0, cs_len = 0, ce_len = 0, inst_len = 0;
            int px_own = 0, py_own = 0, vx_own = 0, vy_own = 0, life_own = 0;
            int ml_own = 0, sz_own = 0, cs_own = 0, ce_own = 0, inst_own = 0;
            AV *px_av = NULL, *py_av = NULL, *vx_av = NULL, *vy_av = NULL, *life_av = NULL;
            AV *ml_av = NULL, *sz_av = NULL, *cs_av = NULL, *ce_av = NULL, *inst_av = NULL;

            int ok =
                nb_av_rw_nv(aTHX_ px_aref,        (size_t)count, 1, &px,        &px_len,   &px_own,   &px_av,   "step_particles(px)") &&
                nb_av_rw_nv(aTHX_ py_aref,        (size_t)count, 1, &py,        &py_len,   &py_own,   &py_av,   "step_particles(py)") &&
                nb_av_rw_nv(aTHX_ vx_aref,        (size_t)count, 1, &vx,        &vx_len,   &vx_own,   &vx_av,   "step_particles(vx)") &&
                nb_av_rw_nv(aTHX_ vy_aref,        (size_t)count, 1, &vy,        &vy_len,   &vy_own,   &vy_av,   "step_particles(vy)") &&
                nb_av_rw_nv(aTHX_ life_aref,      (size_t)count, 1, &life,      &life_len, &life_own, &life_av, "step_particles(life)") &&
                nb_av_rw_nv(aTHX_ max_life_aref,  (size_t)count, 1, &max_life,  &ml_len,   &ml_own,   &ml_av,   "step_particles(max_life)") &&
                nb_av_rw_nv(aTHX_ size_aref,      (size_t)count, 1, &size,      &sz_len,   &sz_own,   &sz_av,   "step_particles(size)") &&
                nb_av_rw_nv(aTHX_ col_start_aref, (size_t)count, 1, &col_start, &cs_len,   &cs_own,   &cs_av,   "step_particles(col_start)") &&
                nb_av_rw_nv(aTHX_ col_end_aref,   (size_t)count, 1, &col_end,   &ce_len,   &ce_own,   &ce_av,   "step_particles(col_end)");

            if (ok && inst_cap > 0u) {
                ok = nb_av_rw_nv(aTHX_ inst_aref, inst_cap * 4u, 0, &inst, &inst_len, &inst_own, &inst_av, "step_particles(inst_out)");
            }

            if (!ok) {
                if (px_own)   free(px);
                if (py_own)   free(py);
                if (vx_own)   free(vx);
                if (vy_own)   free(vy);
                if (life_own) free(life);
                if (ml_own)   free(max_life);
                if (sz_own)   free(size);
                if (cs_own)   free(col_start);
                if (ce_own)   free(col_end);
                if (inst_own) free(inst);
                croak("step_particles: out of memory");
            }

            size_t written = tkmt_td_step_particles(
                px, py, vx, vy, life,
                max_life, size, col_start, col_end,
                inst, inst_cap, (size_t)count, dt, drag, workers);

            nb_av_commit_nv(aTHX_ px_av,   px,   (size_t)count, px_own);
            nb_av_commit_nv(aTHX_ py_av,   py,   (size_t)count, py_own);
            nb_av_commit_nv(aTHX_ vx_av,   vx,   (size_t)count, vx_own);
            nb_av_commit_nv(aTHX_ vy_av,   vy,   (size_t)count, vy_own);
            nb_av_commit_nv(aTHX_ life_av, life, (size_t)count, life_own);
            if (ml_own) free(max_life);
            if (sz_own) free(size);
            if (cs_own) free(col_start);
            if (ce_own) free(col_end);
            if (inst && inst_cap > 0u) {
                nb_av_commit_nv(aTHX_ inst_av, inst, inst_cap * 4u, inst_own);
            }

            RETVAL = (UV)written;
        }
    OUTPUT:
        RETVAL

int
render_backdrop_rgba8(rgba_out_sv, w, h, grid_cols, grid_rows, waypoints_nv, time_sec = 0.0, workers = 0)
        SV *rgba_out_sv
        UV w
        UV h
        UV grid_cols
        UV grid_rows
        SV *waypoints_nv
        double time_sec
        int workers
    CODE:
        if (w == 0 || h == 0) {
            croak("render_backdrop_rgba8: invalid dimensions");
        }

        const double *wp_buf = NULL;
        size_t wp_len = 0;
        int wp_owned = 0;
        if (waypoints_nv && SvOK(waypoints_nv)) {
            if (!SvROK(waypoints_nv) || SvTYPE(SvRV(waypoints_nv)) != SVt_PVAV) {
                croak("render_backdrop_rgba8: waypoints_nv must be an arrayref");
            }
            if (!tkmt_av_read_nv(aTHX_ (AV *)SvRV(waypoints_nv), &wp_buf, &wp_len, &wp_owned)) {
                croak("render_backdrop_rgba8: out of memory reading waypoints_nv");
            }
        }

        size_t need = (size_t)w * (size_t)h * 4u;
        uint8_t *out_buf = NULL;
        int out_owned = 0;
        AV *out_av = NULL;
        if (!nb_av_rw_u8(aTHX_ rgba_out_sv, need, &out_buf, &out_owned, &out_av, "render_backdrop_rgba8")) {
            if (wp_owned) free((void *)wp_buf);
            croak("render_backdrop_rgba8: out of memory");
        }

        int rc = tkmt_td_render_backdrop_rgba8(
            out_buf, (uint32_t)w, (uint32_t)h,
            (uint32_t)grid_cols, (uint32_t)grid_rows,
            wp_buf, wp_len / 2u, time_sec, workers);

        nb_av_commit_u8(aTHX_ rgba_out_sv, out_av, out_buf, need, out_owned);
        if (wp_owned) free((void *)wp_buf);
        RETVAL = rc;
    OUTPUT:
        RETVAL
