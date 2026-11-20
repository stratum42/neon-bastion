use strict;
use warnings;
use File::Spec;
use FindBin;
use Test::More;
use Time::HiRes qw(time);

BEGIN {
    my $root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
    my @tk_roots;
    if (defined $ENV{TCL_TK_MT_DIR} && length $ENV{TCL_TK_MT_DIR}) {
        push @tk_roots, File::Spec->rel2abs($ENV{TCL_TK_MT_DIR});
    }
    push @tk_roots, File::Spec->rel2abs(File::Spec->catdir($root, '..', 'tcl-tk-mt'));
    for my $tk_root (@tk_roots) {
        for my $sub (
            File::Spec->catdir($tk_root, 'blib', 'lib'),
            File::Spec->catdir($tk_root, 'blib', 'arch'),
            File::Spec->catdir($tk_root, 'lib'),
        ) {
            push @INC, $sub if -d $sub;
        }
    }
}

use NeonBastion::SimXS;
use Tcl::Tk::MT::Gfx;

my $have_packed = NeonBastion::SimXS::have_packed_av();
my $has_mt_arr  = ($have_packed && eval { require MT::Array; 1 }) ? 1 : 0;

ok(defined(&NeonBastion::SimXS::step_particles),        'NeonBastion::SimXS::step_particles XSUB exists');
ok(defined(&NeonBastion::SimXS::render_backdrop_rgba8), 'NeonBastion::SimXS::render_backdrop_rgba8 XSUB exists');

sub make_nv_buf {
    my (@vals) = @_;
    return $has_mt_arr ? MT::Array::packed('NV', @vals) : \@vals;
}

sub make_iv_buf {
    my (@vals) = @_;
    return $has_mt_arr ? MT::Array::packed('IV', @vals) : \@vals;
}

sub make_u8_buf {
    my ($len) = @_;
    return $has_mt_arr ? MT::Array::packed('U8', (0) x $len) : [ (0) x $len ];
}

sub hash_doubles {
    my ($aref) = @_;
    return Tcl::Tk::MT::Gfx::sha256_hex(pack('d<*', @$aref));
}

sub hash_u8_aref {
    my ($aref) = @_;
    return Tcl::Tk::MT::Gfx::sha256_hex(pack('C*', @$aref));
}

sub clamp_u8 {
    my ($v) = @_;
    return 0   if $v <= 0.0;
    return 255 if $v >= 255.0;
    return int($v + 0.5);
}

# =========================================================================
# 1. Kernel 1: td_step_particles lifecycle, compaction & Perl reference
# =========================================================================
{
    my $n    = 17; # odd count exercising SIMD pairs + scalar tail
    my $dt   = 0.05;
    my $drag = 0.94;

    my $c_cyan    = Tcl::Tk::MT::Gfx::rgba(40,  240, 255, 255);
    my $c_magenta = Tcl::Tk::MT::Gfx::rgba(255, 30,  160, 200);
    my $c_gold    = Tcl::Tk::MT::Gfx::rgba(255, 210, 40,  240);
    my $c_crimson = Tcl::Tk::MT::Gfx::rgba(240, 20,  60,  120);

    my (@x0, @y0, @vx0, @vy0, @l0, @ml0, @sz0, @cs0, @ce0);
    for my $i (0 .. $n - 1) {
        push @x0,  100.0 + $i * 12.5;
        push @y0,  200.0 - $i * 4.25;
        push @vx0, 40.0  - $i * 5.0;
        push @vy0, -30.0 + $i * 3.5;
        # Mix already-dead (life=0), dying-this-step (life=0.03 < dt), and alive
        my $life = ($i % 5 == 0) ? 0.0
                 : ($i % 5 == 1) ? 0.03
                 :                 0.20 + ($i % 7) * 0.12;
        push @l0,  $life;
        push @ml0, 1.0;
        push @sz0, 2.0 + ($i % 4) * 1.25;
        push @cs0, ($i % 2 == 0) ? $c_cyan    : $c_gold;
        push @ce0, ($i % 2 == 0) ? $c_magenta : $c_crimson;
    }

    # Pure-Perl reference
    my @rx  = @x0;
    my @ry  = @y0;
    my @rvx = @vx0;
    my @rvy = @vy0;
    my @rl  = @l0;
    my @rinst = (0.0) x ($n * 2 * 4);
    my $r_written = 0;
    for my $i (0 .. $n - 1) {
        next if $rl[$i] <= 0.0;
        $rx[$i]  = $rx[$i] + $rvx[$i] * $dt;
        $ry[$i]  = $ry[$i] + $rvy[$i] * $dt;
        $rvx[$i] = $rvx[$i] * $drag;
        $rvy[$i] = $rvy[$i] * $drag;
        $rl[$i]  = $rl[$i] - $dt;
        if ($rl[$i] <= 0.0) {
            $rl[$i] = 0.0;
            next;
        }
        my $rem  = $rl[$i] / $ml0[$i];
        $rem = 0.0 if $rem < 0.0;
        $rem = 1.0 if $rem > 1.0;
        my $age  = 1.0 - $rem;
        my $fade = $rem * (2.0 - $rem);

        my $c0 = $cs0[$i];
        my $c1 = $ce0[$i];
        my ($r0, $g0, $b0, $a0) = ($c0 & 0xFF, ($c0 >> 8) & 0xFF, ($c0 >> 16) & 0xFF, ($c0 >> 24) & 0xFF);
        my ($r1, $g1, $b1, $a1) = ($c1 & 0xFF, ($c1 >> 8) & 0xFF, ($c1 >> 16) & 0xFF, ($c1 >> 24) & 0xFF);

        my $cr = clamp_u8($r0 + ($r1 - $r0) * $age);
        my $cg = clamp_u8($g0 + ($g1 - $g0) * $age);
        my $cb = clamp_u8($b0 + ($b1 - $b0) * $age);
        my $af = ($a0 + ($a1 - $a0) * $age) * $fade;
        my $core_a = clamp_u8($af);
        my $halo_a = clamp_u8($af * 0.28);

        my $halo_rgba = Tcl::Tk::MT::Gfx::rgba($cr, $cg, $cb, $halo_a);
        my $core_rgba = Tcl::Tk::MT::Gfx::rgba($cr, $cg, $cb, $core_a);

        my $o = $r_written * 4;
        $rinst[$o + 0] = $rx[$i];
        $rinst[$o + 1] = $ry[$i];
        $rinst[$o + 2] = $halo_rgba + 0.0;
        $rinst[$o + 3] = $sz0[$i] * 2.4;

        $rinst[$o + 4] = $rx[$i];
        $rinst[$o + 5] = $ry[$i];
        $rinst[$o + 6] = $core_rgba + 0.0;
        $rinst[$o + 7] = $sz0[$i];
        $r_written += 2;
    }

    my $px   = make_nv_buf(@x0);
    my $py   = make_nv_buf(@y0);
    my $vx   = make_nv_buf(@vx0);
    my $vy   = make_nv_buf(@vy0);
    my $life = make_nv_buf(@l0);
    my $ml   = make_nv_buf(@ml0);
    my $sz   = make_nv_buf(@sz0);
    my $cs   = make_nv_buf(map { $_ + 0.0 } @cs0);
    my $ce   = make_nv_buf(map { $_ + 0.0 } @ce0);
    # Pre-fill inst_out with sentinel values to verify dead-tail zeroing
    my $inst = make_nv_buf((999.0) x ($n * 2 * 4));

    if ($has_mt_arr) {
        is(NeonBastion::SimXS::av_packed_type($px),   2, 'td_step_particles px is AV_PACKED_NV');
        is(NeonBastion::SimXS::av_packed_type($inst), 2, 'td_step_particles inst_out is AV_PACKED_NV');
    }

    my $written = NeonBastion::SimXS::step_particles(
        $px, $py, $vx, $vy, $life, $ml, $sz, $cs, $ce,
        $inst, $n, $dt, $drag, 4
    );

    is($written, $r_written, "td_step_particles compacted live instances ($written == $r_written)");
    is($written % 2, 0, 'emitted instance count is even (halo + core per live particle)');

    my $max_err = 0.0;
    for my $i (0 .. $n - 1) {
        for my $d (
            abs($px->[$i]   - $rx[$i]),
            abs($py->[$i]   - $ry[$i]),
            abs($vx->[$i]   - $rvx[$i]),
            abs($vy->[$i]   - $rvy[$i]),
            abs($life->[$i] - $rl[$i]),
        ) {
            $max_err = $d if $d > $max_err;
        }
    }
    cmp_ok($max_err, '<', 1e-12, "particle state matches Perl reference (max_err=$max_err)");

    my $inst_err = 0.0;
    for my $i (0 .. ($n * 2 * 4) - 1) {
        my $d = abs($inst->[$i] - $rinst[$i]);
        $inst_err = $d if $d > $inst_err;
    }
    cmp_ok($inst_err, '<', 1e-12, "dual-layer halo+core instances & zeroed tail match reference (max_err=$inst_err)");

    # Verify packed IV color arrays produce bit-identical output
    my $px2   = make_nv_buf(@x0);
    my $py2   = make_nv_buf(@y0);
    my $vx2   = make_nv_buf(@vx0);
    my $vy2   = make_nv_buf(@vy0);
    my $life2 = make_nv_buf(@l0);
    my $cs_iv = make_iv_buf(@cs0);
    my $ce_iv = make_iv_buf(@ce0);
    my $inst2 = make_nv_buf((0.0) x ($n * 2 * 4));

    my $written2 = NeonBastion::SimXS::step_particles(
        $px2, $py2, $vx2, $vy2, $life2, $ml, $sz, $cs_iv, $ce_iv,
        $inst2, $n, $dt, $drag, 4
    );
    is($written2, $written, 'packed IV col_start/col_end writes same instance count');
    is(hash_doubles($inst2), hash_doubles($inst), 'packed IV col_start/col_end matches NV bit-for-bit');

    # Verify inst_out feeds directly into Scene::create_instances
    my $scene = Tcl::Tk::MT::Gfx::create_scene(800, 600);
    my $iid = $scene->create_instances($inst, 2, 1, 4);
    ok($iid > 0, 'td_step_particles inst_out accepted by Scene::create_instances');
}

# =========================================================================
# 2. Kernel 1: 16,385-particle SIMD+pthreads vs PERL_FORCE_SCALAR=1 parity
# =========================================================================
{
    my $n    = 16385; # 16K+ odd count across multiple cache-line blocks
    my $dt   = 0.016;
    my $drag = 0.965;

    srand(2026);
    my $c0_a = Tcl::Tk::MT::Gfx::rgba(0,   255, 255, 255) + 0.0;
    my $c1_a = Tcl::Tk::MT::Gfx::rgba(160, 40,  255, 180) + 0.0;
    my $c0_b = Tcl::Tk::MT::Gfx::rgba(255, 220, 60,  255) + 0.0;
    my $c1_b = Tcl::Tk::MT::Gfx::rgba(255, 40,  80,  160) + 0.0;

    my (@x0, @y0, @vx0, @vy0, @l0, @ml0, @sz0, @cs0, @ce0);
    for my $i (0 .. $n - 1) {
        push @x0,  rand(1280.0);
        push @y0,  rand(720.0);
        push @vx0, (rand(240.0) - 120.0);
        push @vy0, (rand(240.0) - 120.0);
        my $ml = 0.10 + rand(0.90);
        push @l0,  ($i % 4 == 0) ? 0.0 : rand($ml);
        push @ml0, $ml;
        push @sz0, 1.5 + rand(4.5);
        push @cs0, ($i & 1) ? $c0_a : $c0_b;
        push @ce0, ($i & 1) ? $c1_a : $c1_b;
    }

    my %hashes;
    my %counts;
    my $simd_ms = 0.0;
    for my $mode (qw(simd scalar)) {
        local $ENV{PERL_FORCE_SCALAR} = ($mode eq 'scalar') ? 1 : 0;
        my $px   = make_nv_buf(@x0);
        my $py   = make_nv_buf(@y0);
        my $vx   = make_nv_buf(@vx0);
        my $vy   = make_nv_buf(@vy0);
        my $life = make_nv_buf(@l0);
        my $ml   = make_nv_buf(@ml0);
        my $sz   = make_nv_buf(@sz0);
        my $cs   = make_nv_buf(@cs0);
        my $ce   = make_nv_buf(@ce0);
        my $inst = make_nv_buf((0.0) x ($n * 2 * 4));

        my $t0 = time();
        my $w = 0;
        for my $step (1 .. 5) {
            $w = NeonBastion::SimXS::step_particles(
                $px, $py, $vx, $vy, $life, $ml, $sz, $cs, $ce,
                $inst, $n, $dt, $drag, 4
            );
        }
        my $elapsed_ms = (time() - $t0) * 1000.0 / 5.0;
        $simd_ms = $elapsed_ms if $mode eq 'simd';

        $counts{$mode} = $w;
        $hashes{$mode} = {
            px   => hash_doubles($px),
            py   => hash_doubles($py),
            vx   => hash_doubles($vx),
            vy   => hash_doubles($vy),
            life => hash_doubles($life),
            inst => hash_doubles($inst),
        };
    }

    is($counts{simd}, $counts{scalar}, "td_step_particles 16K live instance count matches ($counts{simd})");
    for my $k (qw(px py vx vy life inst)) {
        is($hashes{simd}{$k}, $hashes{scalar}{$k},
            "td_step_particles bit-identical SIMD+pthreads vs PERL_FORCE_SCALAR=1 ($k)");
    }
    note(sprintf("td_step_particles(n=%d, 4 workers): %.3f ms/step", $n, $simd_ms));
}

# =========================================================================
# 3. Kernel 2: td_render_backdrop_rgba8 visual sanity & exact scalar parity
# =========================================================================
{
    my ($w, $h) = (161, 113); # odd dimensions to test row tiling
    my ($cols, $rows) = (16, 10);
    my $waypoints = make_nv_buf(
        20.0, 28.0,
        125.0, 28.0,
        125.0, 84.0,
        40.0, 84.0,
        142.0, 96.0,
    );

    my $buf_mt     = make_u8_buf($w * $h * 4);
    my $buf_scalar = make_u8_buf($w * $h * 4);

    if ($has_mt_arr) {
        is(NeonBastion::SimXS::av_packed_type($buf_mt), 3, 'backdrop output is AV_PACKED_U8');
    }

    {
        local $ENV{PERL_FORCE_SCALAR} = 0;
        my $rc = NeonBastion::SimXS::render_backdrop_rgba8(
            $buf_mt, $w, $h, $cols, $rows, $waypoints, 1.25, 4
        );
        is($rc, 0, 'td_render_backdrop_rgba8 (pthreads) succeeded');
    }
    {
        local $ENV{PERL_FORCE_SCALAR} = 1;
        my $rc = NeonBastion::SimXS::render_backdrop_rgba8(
            $buf_scalar, $w, $h, $cols, $rows, $waypoints, 1.25, 4
        );
        is($rc, 0, 'td_render_backdrop_rgba8 (PERL_FORCE_SCALAR=1) succeeded');
    }

    is(hash_u8_aref($buf_mt), hash_u8_aref($buf_scalar),
        'td_render_backdrop_rgba8 bit-identical pthreads vs PERL_FORCE_SCALAR=1');

    # Writable byte-string scalar output matches packed U8 AV bit-for-bit
    my $str_out = '';
    my $rc_str = NeonBastion::SimXS::render_backdrop_rgba8(
        $str_out, $w, $h, $cols, $rows, $waypoints, 1.25, 4
    );
    is($rc_str, 0, 'td_render_backdrop_rgba8 writable byte-string succeeded');
    is(length($str_out), $w * $h * 4, 'backdrop byte-string has exact w*h*4 length');
    is(Tcl::Tk::MT::Gfx::sha256_hex($str_out), hash_u8_aref($buf_mt),
        'backdrop byte-string matches packed U8 AV bit-for-bit');

    # Helper to read pixel (x, y)
    my $px_at = sub {
        my ($x, $y) = @_;
        my $off = ($y * $w + $x) * 4;
        return @{$buf_mt}[$off .. $off + 3];
    };

    # Verify non-blank backdrop output and opaque alpha
    my %distinct;
    my $bad_alpha = 0;
    for (my $i = 0; $i < $w * $h * 4; $i += 4) {
        $distinct{"$buf_mt->[$i],$buf_mt->[$i+1],$buf_mt->[$i+2]"} = 1;
        $bad_alpha++ if $buf_mt->[$i + 3] != 255;
    }
    cmp_ok(scalar(keys %distinct), '>', 100,
        'procedural backdrop has rich color variation (' . scalar(keys %distinct) . ' distinct RGB values)');
    is($bad_alpha, 0, 'all backdrop pixels have alpha=255');

    # Spawn portal at waypoint[0] = (20, 28) has strong crimson aura (R > G and R > B)
    my ($sr, $sg, $sb, $sa) = $px_at->(20, 28);
    cmp_ok($sr, '>', 180, "spawn portal core has bright crimson R ($sr)");
    cmp_ok($sr, '>', $sg + 40, "spawn portal R ($sr) dominates G ($sg)");

    # Bastion core at waypoint[-1] = (142, 96) has bright emerald/cyan aura (G & B high)
    my ($br, $bg, $bb, $ba) = $px_at->(142, 96);
    cmp_ok($bg, '>', 180, "bastion core has bright emerald G ($bg)");
    cmp_ok($bb, '>', 160, "bastion core has bright cyan B ($bb)");

    # Midpoint of first conduit segment (72, 28) is glowing cyan/blue vs dark corner (2, 110)
    my ($cr, $cg, $cb, $ca) = $px_at->(72, 28);
    my ($kr, $kg, $kb, $ka) = $px_at->(2, 110);
    cmp_ok($cb, '>', $kb + 100, "conduit core B ($cb) glows brightly above dark corner B ($kb)");
    cmp_ok($cg, '>', $kg + 100, "conduit core G ($cg) glows brightly above dark corner G ($kg)");
    cmp_ok($kr + $kg + $kb, '<', 80, "corner pixel ($kr,$kg,$kb) is dark obsidian");

    # Verify zero-copy upload to headless software surface via put_rgba_packed
    my $surf = Tcl::Tk::MT::Gfx::create_surface($w, $h, 'software', 1.0, 1);
    ok(defined $surf, 'created headless software surface');
    my $tid = $surf->put_rgba_packed(0, $w, $h, $buf_mt);
    ok($tid > 0, 'put_rgba_packed accepted zero-copy backdrop U8 buffer');
}

done_testing();
