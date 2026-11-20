package NeonBastion::Renderer;

use strict;
use warnings;
use Time::HiRes qw(time);
use NeonBastion::Config ();
use Tcl::Tk::MT::Photo ();

our $VERSION = '0.01';

my $TWO_PI = 6.283185307179586;

my $HAS_PACKED_AV    = 0;
my $HAS_TD_BACKDROP  = 0;

BEGIN {
    eval { require NeonBastion::SimXS; 1 };
    if (eval { NeonBastion::SimXS::have_packed_av() } && eval { require MT::Array; 1 }) {
        $HAS_PACKED_AV = 1;
    }
    $HAS_TD_BACKDROP = defined(&NeonBastion::SimXS::render_backdrop_rgba8) ? 1 : 0;
}

sub new {
    my ($class, %opts) = @_;
    my $canvas = $opts{canvas} or die "NeonBastion::Renderer requires canvas";
    my $w      = int($opts{width}  || $NeonBastion::Config::ARENA_W);
    my $h      = int($opts{height} || $NeonBastion::Config::ARENA_H);

    # Flatten waypoints for C11 backdrop kernel
    my @wp_flat;
    for my $wp (@NeonBastion::Config::PATH_WAYPOINTS) {
        push @wp_flat, $wp->[0] + 0.0, $wp->[1] + 0.0;
    }
    my $waypoints_nv = $HAS_PACKED_AV
        ? MT::Array::packed('NV', @wp_flat)
        : \@wp_flat;

    # Preallocated zero-copy RGBA8888 backdrop buffer
    my $bg_rgba = $HAS_PACKED_AV
        ? MT::Array::packed('U8', (0) x ($w * $h * 4))
        : ("\0" x ($w * $h * 4));

    my $photo = Tcl::Tk::MT::Photo->new(
        $canvas->interp,
        -width   => $w,
        -height  => $h,
        -surface => $canvas->surface,
    );

    my $self = bless {
        canvas           => $canvas,
        width            => $w,
        height           => $h,
        waypoints_nv     => $waypoints_nv,
        bg_rgba          => $bg_rgba,
        bg_photo         => $photo,
        bg_item_id       => undef,
        particle_inst_id => undef,
        bg_frame_div     => 4,       # refresh animated procedural backdrop every 4 frames
        last_bg_frame    => -999,
        hover_col        => -1,
        hover_row        => -1,
        build_type       => 'pulse',
        selected_tower   => undef,
        last_shake       => 0,
    }, $class;

    $self->_update_backdrop(0.0);
    $self->{bg_item_id} = $canvas->createImage(
        0, 0,
        -image  => $photo,
        -anchor => 'nw',
        -tags   => 'bg',
    );

    return $self;
}

sub set_hover {
    my ($self, $col, $row) = @_;
    $self->{hover_col} = defined($col) ? int($col) : -1;
    $self->{hover_row} = defined($row) ? int($row) : -1;
}

sub set_build_type {
    my ($self, $type) = @_;
    $self->{build_type} = $type if defined $type && exists $NeonBastion::Config::TOWERS{$type};
}

sub set_selected_tower {
    my ($self, $tower) = @_;
    $self->{selected_tower} = $tower;
}

sub _update_backdrop {
    my ($self, $time_sec) = @_;
    if ($HAS_TD_BACKDROP) {
        NeonBastion::SimXS::render_backdrop_rgba8(
            $self->{bg_rgba},
            $self->{width},
            $self->{height},
            $NeonBastion::Config::GRID_COLS,
            $NeonBastion::Config::GRID_ROWS,
            $self->{waypoints_nv},
            $time_sec + 0.0,
            0,
        );
    }
    $self->{bg_photo}->put_rgba_packed($self->{bg_rgba}, $self->{width}, $self->{height});
}

sub _regular_poly {
    my ($cx, $cy, $r, $sides, $rot) = @_;
    $rot ||= 0.0;
    my @pts;
    for (my $i = 0; $i < $sides; $i++) {
        my $a = $rot + ($TWO_PI * $i) / $sides;
        push @pts, ($cx + cos($a) * $r), ($cy + sin($a) * $r);
    }
    return \@pts;
}

sub render_frame {
    my ($self, $sim) = @_;
    my $t0 = time();
    my $c  = $self->{canvas};

    # Refresh procedural backdrop every N frames
    if ($sim->{frame_num} - $self->{last_bg_frame} >= $self->{bg_frame_div}) {
        $self->_update_backdrop($sim->{sim_time});
        $self->{last_bg_frame} = $sim->{frame_num};
    }

    # Screen shake via canvas pan offset
    if ($sim->{shake_mag} > 0.05) {
        $c->set_pan_zoom($sim->{shake_x}, $sim->{shake_y}, 1.0, 1.0);
        $self->{last_shake} = 1;
    }
    elsif ($self->{last_shake}) {
        $c->set_pan_zoom(0.0, 0.0, 1.0, 1.0);
        $self->{last_shake} = 0;
    }

    $c->batch(sub {
        $c->delete('dyn');
        if (defined $self->{particle_inst_id}) {
            $c->delete($self->{particle_inst_id});
            $self->{particle_inst_id} = undef;
        }

        my $t = $sim->{sim_time};

        # 1. Animated Spawn Portal & Bastion Core accents
        $self->_draw_portals($c, $sim, $t);

        # 2. Hover placement preview & range ring
        $self->_draw_hover_preview($c, $sim);

        # 3. Selected tower range ring
        if (my $sel = $self->{selected_tower}) {
            my $spec = $NeonBastion::Config::TOWERS{ $sel->{type} };
            my $lvl  = $spec->{levels}[ $sel->{level} - 1 ];
            my $r    = $lvl->{range};
            $c->createOval(
                $sel->{x} - $r, $sel->{y} - $r, $sel->{x} + $r, $sel->{y} + $r,
                -outline => $spec->{color},
                -fill    => '',
                -width   => 1.8,
                -tags    => 'dyn',
            );
            $c->createRectangle(
                $sel->{x} - 28, $sel->{y} - 28, $sel->{x} + 28, $sel->{y} + 28,
                -outline => '#ffffff',
                -fill    => '',
                -width   => 1.5,
                -tags    => 'dyn',
            );
        }

        # 4. Expanding Cryo-Nova rings
        for my $n (@{ $sim->{novas} }) {
            my $r = $n->{radius};
            $c->createOval(
                $n->{x} - $r, $n->{y} - $r, $n->{x} + $r, $n->{y} + $r,
                -outline => $n->{color},
                -fill    => '',
                -width   => 3.5,
                -tags    => 'dyn',
            );
            my $r2 = $r * 0.88;
            $c->createOval(
                $n->{x} - $r2, $n->{y} - $r2, $n->{x} + $r2, $n->{y} + $r2,
                -outline => $n->{glow},
                -fill    => '',
                -width   => 1.5,
                -tags    => 'dyn',
            );
        }

        # 5. Towers (4 distinct silhouettes + level 1-3 upgrades + rotating turrets)
        for my $tw (@{ $sim->{towers} }) {
            $self->_draw_tower($c, $tw, $t);
        }

        # 6. Enemies (5 archetypes + slow tint + hit-flash + mini HP bars)
        for my $e (@{ $sim->{enemies} }) {
            next unless $e->{alive};
            $self->_draw_enemy($c, $e, $t);
        }

        # 7. Pulse plasma projectiles
        for my $p (@{ $sim->{projectiles} }) {
            my $tx = $p->{x} - $p->{vx} * 0.022;
            my $ty = $p->{y} - $p->{vy} * 0.022;
            $c->createLine(
                $tx, $ty, $p->{x}, $p->{y},
                -fill  => $p->{color},
                -width => 4.0,
                -tags  => 'dyn',
            );
            $c->createLine(
                $tx, $ty, $p->{x}, $p->{y},
                -fill  => $p->{glow},
                -width => 1.8,
                -tags  => 'dyn',
            );
        }

        # 8. Railgun piercing beams + Tesla jagged chain-lightning arcs
        for my $b (@{ $sim->{beams} }) {
            my $pts = $b->{points};
            next unless $pts && @$pts >= 4;
            my $alpha_ratio = $b->{max_life} > 0 ? ($b->{life} / $b->{max_life}) : 1.0;

            if ($b->{kind} eq 'rail') {
                my $w_out = 4.0 + 6.0 * $alpha_ratio;
                my $w_in  = 1.5 + 2.5 * $alpha_ratio;
                $c->createLine(@$pts, -fill => $b->{color},      -width => $w_out, -tags => 'dyn');
                $c->createLine(@$pts, -fill => $b->{core_color}, -width => $w_in,  -tags => 'dyn');
                for my $rg (@{ $b->{rings} || [] }) {
                    my $rr = 6.0 + (1.0 - $alpha_ratio) * 18.0;
                    $c->createOval(
                        $rg->[0] - $rr, $rg->[1] - $rr, $rg->[0] + $rr, $rg->[1] + $rr,
                        -outline => $b->{core_color},
                        -fill    => '',
                        -width   => 1.8,
                        -tags    => 'dyn',
                    );
                }
            }
            elsif ($b->{kind} eq 'tesla') {
                $c->createLine(@$pts, -fill => $b->{color},      -width => 5.0 * $alpha_ratio + 1.5, -tags => 'dyn');
                $c->createLine(@$pts, -fill => $b->{core_color}, -width => 2.0 * $alpha_ratio + 0.8, -tags => 'dyn');
            }
        }

        # 9. Instanced particles (packed NV stride-4 buffer)
        if ($sim->{p_inst_count} > 0) {
            $self->{particle_inst_id} = $c->createInstances(
                $sim->{p_inst_out},
                { -shape => 'circle', -stride => 4, -aa => 1 },
            );
        }

        # 10. Wave / Alert Banner
        if ($sim->{wave_banner_t} > 0.0 && length($sim->{wave_banner})) {
            my $bx = $self->{width} * 0.5;
            my $by = 46;
            my $is_warn = ($sim->{wave_banner} =~ /WARNING|BREACHED/) ? 1 : 0;
            my $bcol    = $is_warn ? '#ff2a6d' : '#00f0ff';
            $c->createRectangle(
                $bx - 240, $by - 20, $bx + 240, $by + 20,
                -fill    => '#0b1224',
                -outline => $bcol,
                -width   => 2.0,
                -tags    => 'dyn',
            );
            $c->createText(
                $bx, $by,
                -text   => $sim->{wave_banner},
                -fill   => $bcol,
                -font   => 'Helvetica 15 bold',
                -anchor => 'center',
                -tags   => 'dyn',
            );
        }
    });

    $c->render();
    return (time() - $t0) * 1000.0;
}

sub _draw_portals {
    my ($self, $c, $sim, $t) = @_;
    my ($sx, $sy) = @{ $NeonBastion::Config::PATH_WAYPOINTS[0] };
    my ($bx, $by) = @{ $NeonBastion::Config::PATH_WAYPOINTS[-1] };

    # Spawn Portal (pulsing crimson rift)
    my $sr = 18.0 + sin($t * 5.0) * 3.0;
    $c->createPolygon(
        _regular_poly($sx, $sy, $sr + 5.0, 6, $t * 1.4),
        -fill => '#3b0718', -outline => '#ff2a6d', -width => 2.2, -tags => 'dyn',
    );
    $c->createOval(
        $sx - $sr * 0.65, $sy - $sr * 0.65, $sx + $sr * 0.65, $sy + $sr * 0.65,
        -fill => '#ff2a6d', -outline => '#fda4af', -width => 1.5, -tags => 'dyn',
    );

    # Bastion core
    my $hp_frac = $sim->{max_core_hp} > 0 ? ($sim->{core_hp} / $sim->{max_core_hp}) : 0.0;
    my $core_col = $hp_frac > 0.45 ? '#00f0ff' : ($hp_frac > 0.2 ? '#fbbf24' : '#ef4444');
    my $br = 20.0 + cos($t * 4.0) * 2.5;
    $c->createPolygon(
        _regular_poly($bx, $by, $br + 4.0, 8, -$t * 0.9),
        -fill => '#082f49', -outline => $core_col, -width => 2.5, -tags => 'dyn',
    );
    $c->createPolygon(
        _regular_poly($bx, $by, $br * 0.58, 4, $t * 1.8),
        -fill => $core_col, -outline => '#ffffff', -width => 1.5, -tags => 'dyn',
    );
}

sub _draw_hover_preview {
    my ($self, $c, $sim) = @_;
    my ($col, $row) = ($self->{hover_col}, $self->{hover_row});
    return unless NeonBastion::Config::in_bounds_tile($col, $row);
    return if $sim->tower_at($col, $row);

    my $type = $self->{build_type};
    my $spec = $NeonBastion::Config::TOWERS{$type} or return;
    my ($ok) = $sim->can_build($col, $row, $type);
    my ($cx, $cy) = NeonBastion::Config::tile_center($col, $row);

    my $pcol = $ok ? '#00f0ff' : '#ef4444';
    my $half = $NeonBastion::Config::TILE_SIZE * 0.5 - 3;

    $c->createRectangle(
        $cx - $half, $cy - $half, $cx + $half, $cy + $half,
        -outline => $pcol,
        -fill    => '',
        -width   => 2.0,
        -tags    => 'dyn',
    );
    if ($ok) {
        my $r = $spec->{levels}[0]{range};
        $c->createOval(
            $cx - $r, $cy - $r, $cx + $r, $cy + $r,
            -outline => $spec->{color},
            -fill    => '',
            -width   => 1.2,
            -tags    => 'dyn',
        );
    }
}

sub _draw_tower {
    my ($self, $c, $tw, $t) = @_;
    my $spec = $NeonBastion::Config::TOWERS{ $tw->{type} };
    my ($x, $y) = ($tw->{x}, $tw->{y});
    my $lvl = $tw->{level};
    my $ang = $tw->{angle};
    my $ca  = cos($ang);
    my $sa  = sin($ang);
    my $rec = $tw->{recoil} || 0.0;

    my $col  = $spec->{color};
    my $dark = $spec->{color_dark};
    my $glow = $spec->{color_glow};

    # Pedestal base (upgraded levels add outer glowing trim)
    my $base_r = 21.0 + ($lvl - 1) * 2.0;
    if ($tw->{type} eq 'pulse') {
        $c->createPolygon(
            _regular_poly($x, $y, $base_r, 8, 0.3927),
            -fill => $dark, -outline => $col, -width => 1.6 + $lvl * 0.4, -tags => 'dyn',
        );
        # Twin rotating plasma barrels
        my $px = -$sa * 5.0;
        my $py =  $ca * 5.0;
        my $blen = (18.0 + $lvl * 2.5) - $rec;
        for my $side (-1, 1) {
            my $bx0 = $x + $px * $side;
            my $by0 = $y + $py * $side;
            $c->createLine(
                $bx0, $by0, $bx0 + $ca * $blen, $by0 + $sa * $blen,
                -fill => $glow, -width => 3.6, -tags => 'dyn',
            );
        }
        $c->createOval($x - 9, $y - 9, $x + 9, $y + 9, -fill => '#0c4a6e', -outline => $glow, -width => 1.8, -tags => 'dyn');
    }
    elsif ($tw->{type} eq 'rail') {
        $c->createPolygon(
            _regular_poly($x, $y, $base_r + 1.0, 6, 0.0),
            -fill => $dark, -outline => $col, -width => 1.8 + $lvl * 0.4, -tags => 'dyn',
        );
        # Split magnetic railgun barrel
        my $px = -$sa * 4.2;
        my $py =  $ca * 4.2;
        my $blen = (24.0 + $lvl * 3.0) - $rec;
        for my $side (-1, 1) {
            my $bx0 = $x + $px * $side - $ca * 4.0;
            my $by0 = $y + $py * $side - $sa * 4.0;
            $c->createLine(
                $bx0, $by0, $x + $px * $side + $ca * $blen, $y + $py * $side + $sa * $blen,
                -fill => $col, -width => 3.0, -tags => 'dyn',
            );
        }
        # Glowing energy core line down center of rail
        $c->createLine(
            $x, $y, $x + $ca * ($blen - 2.0), $y + $sa * ($blen - 2.0),
            -fill => $glow, -width => 1.8, -tags => 'dyn',
        );
        $c->createPolygon(
            _regular_poly($x, $y, 9.0, 4, $ang),
            -fill => $col, -outline => $glow, -width => 1.5, -tags => 'dyn',
        );
    }
    elsif ($tw->{type} eq 'frost') {
        $c->createPolygon(
            _regular_poly($x, $y, $base_r, 6, 0.5236),
            -fill => $dark, -outline => $col, -width => 1.6 + $lvl * 0.4, -tags => 'dyn',
        );
        # Crystalline core + orbiting cryo nodes (1..3 by level)
        my $cr = 8.0 + sin($t * 4.0 + $tw->{id}) * 1.5;
        $c->createPolygon(
            _regular_poly($x, $y, $cr + 3.0, 4, $t * 1.2),
            -fill => $col, -outline => $glow, -width => 1.5, -tags => 'dyn',
        );
        for my $k (0 .. $lvl) {
            my $oa = $t * 2.2 + ($TWO_PI * $k) / ($lvl + 1);
            my $ox = $x + cos($oa) * 14.0;
            my $oy = $y + sin($oa) * 14.0;
            $c->createOval($ox - 3, $oy - 3, $ox + 3, $oy + 3, -fill => $glow, -outline => $col, -width => 1.0, -tags => 'dyn');
        }
    }
    elsif ($tw->{type} eq 'tesla') {
        $c->createOval(
            $x - $base_r, $y - $base_r, $x + $base_r, $y + $base_r,
            -fill => $dark, -outline => $col, -width => 1.8 + $lvl * 0.4, -tags => 'dyn',
        );
        # Concentric Tesla coil rings
        $c->createOval($x - 13, $y - 13, $x + 13, $y + 13, -fill => '', -outline => $col, -width => 1.6, -tags => 'dyn');
        # Rotating prongs
        for my $k (0 .. 2) {
            my $pa = -$t * 2.6 + ($TWO_PI * $k) / 3.0;
            $c->createLine(
                $x + cos($pa) * 7.0, $y + sin($pa) * 7.0,
                $x + cos($pa) * 17.0, $y + sin($pa) * 17.0,
                -fill => $glow, -width => 2.0, -tags => 'dyn',
            );
        }
        my $orb = 6.5 + sin($t * 9.0 + $tw->{id}) * 1.5;
        $c->createOval($x - $orb, $y - $orb, $x + $orb, $y + $orb, -fill => $glow, -outline => '#ffffff', -width => 1.4, -tags => 'dyn');
    }

    # Level pips along bottom of tile
    for my $i (0 .. $lvl - 1) {
        my $px = $x - ($lvl - 1) * 5.0 + $i * 10.0;
        my $py = $y + 22.0;
        $c->createOval($px - 2.6, $py - 2.6, $px + 2.6, $py + 2.6, -fill => $glow, -outline => $col, -width => 1.0, -tags => 'dyn');
    }

    # Muzzle flash glow
    if ($tw->{muzzle_flash} > 0.0 && ($tw->{type} eq 'pulse' || $tw->{type} eq 'rail')) {
        my $fx = $x + $ca * 24.0;
        my $fy = $y + $sa * 24.0;
        $c->createOval($fx - 6, $fy - 6, $fx + 6, $fy + 6, -fill => '#ffffff', -outline => $col, -width => 2.0, -tags => 'dyn');
    }
}

sub _draw_enemy {
    my ($self, $c, $e, $t) = @_;
    my $spec = $NeonBastion::Config::ENEMIES{ $e->{type} };
    my ($x, $y) = ($e->{x}, $e->{y});
    my $r   = $e->{radius};
    my $ang = $e->{angle};
    my $ca  = cos($ang);
    my $sa  = sin($ang);

    my $fill    = $e->{hit_flash} > 0.0 ? '#ffffff' : ($e->{slow_timer} > 0.0 ? '#60a5fa' : $spec->{color});
    my $outline = $e->{slow_timer} > 0.0 ? '#e0f2fe' : $spec->{outline};

    my $shape = $spec->{shape};
    if ($shape eq 'diamond') {
        my @pts = (
            $x + $ca * ($r + 2), $y + $sa * ($r + 2),
            $x - $sa * ($r * 0.75), $y + $ca * ($r * 0.75),
            $x - $ca * ($r + 2), $y - $sa * ($r + 2),
            $x + $sa * ($r * 0.75), $y - $ca * ($r * 0.75),
        );
        $c->createPolygon(\@pts, -fill => $fill, -outline => $outline, -width => 1.6, -tags => 'dyn');
    }
    elsif ($shape eq 'chevron') {
        my @pts = (
            $x + $ca * ($r + 3), $y + $sa * ($r + 3),
            $x - $ca * $r - $sa * $r, $y - $sa * $r + $ca * $r,
            $x - $ca * ($r * 0.35), $y - $sa * ($r * 0.35),
            $x - $ca * $r + $sa * $r, $y - $sa * $r - $ca * $r,
        );
        $c->createPolygon(\@pts, -fill => $fill, -outline => $outline, -width => 1.8, -tags => 'dyn');
    }
    elsif ($shape eq 'hexagon') {
        $c->createPolygon(
            _regular_poly($x, $y, $r, 6, $ang),
            -fill => $fill, -outline => $outline, -width => 2.4, -tags => 'dyn',
        );
        $c->createOval(
            $x - $r * 0.5, $y - $r * 0.5, $x + $r * 0.5, $y + $r * 0.5,
            -fill => '#2e1065', -outline => $outline, -width => 1.4, -tags => 'dyn',
        );
    }
    elsif ($shape eq 'triangle') {
        my @pts = (
            $x + $ca * ($r + 4), $y + $sa * ($r + 4),
            $x - $ca * $r - $sa * ($r * 0.85), $y - $sa * $r + $ca * ($r * 0.85),
            $x - $ca * $r + $sa * ($r * 0.85), $y - $sa * $r - $ca * ($r * 0.85),
        );
        $c->createPolygon(\@pts, -fill => $fill, -outline => $outline, -width => 1.8, -tags => 'dyn');
    }
    elsif ($shape eq 'boss') {
        my $pulse = sin($e->{pulse_phase}) * 2.5;
        $c->createOval(
            $x - ($r + 6 + $pulse), $y - ($r + 6 + $pulse),
            $x + ($r + 6 + $pulse), $y + ($r + 6 + $pulse),
            -fill => '', -outline => '#fde047', -width => 2.2, -tags => 'dyn',
        );
        $c->createPolygon(
            _regular_poly($x, $y, $r, 8, $t * 0.8),
            -fill => $fill, -outline => $outline, -width => 2.8, -tags => 'dyn',
        );
        $c->createPolygon(
            _regular_poly($x, $y, $r * 0.52, 6, -$t * 1.6),
            -fill => '#4c0519', -outline => '#fde047', -width => 2.0, -tags => 'dyn',
        );
    }

    # Mini HP bar above enemy
    if ($e->{hp} < $e->{max_hp} || $shape eq 'boss') {
        my $bw   = ($shape eq 'boss') ? 48.0 : ($r * 2.0 + 4.0);
        my $bh   = ($shape eq 'boss') ? 5.0  : 3.5;
        my $bx0  = $x - $bw * 0.5;
        my $by0  = $y - $r - 10.0;
        my $frac = $e->{max_hp} > 0 ? ($e->{hp} / $e->{max_hp}) : 0.0;
        $frac = 0.0 if $frac < 0.0;
        $frac = 1.0 if $frac > 1.0;

        my $hp_col = $frac > 0.55 ? '#22c55e' : ($frac > 0.25 ? '#fbbf24' : '#ef4444');
        $c->createRectangle($bx0, $by0, $bx0 + $bw, $by0 + $bh, -fill => '#0f172a', -outline => '#334155', -width => 0.8, -tags => 'dyn');
        if ($frac > 0.0) {
            $c->createRectangle($bx0, $by0, $bx0 + $bw * $frac, $by0 + $bh, -fill => $hp_col, -outline => '', -tags => 'dyn');
        }
    }
}

1;

__END__

=head1 NAME

NeonBastion::Renderer - Canvas and Photo renderer for NEON BASTION

=head1 DESCRIPTION

Draws the NEON BASTION arena onto a L<Tcl::Tk::MT::Canvas>. Uploads the
procedural backdrop from L<NeonBastion::SimXS/render_backdrop_rgba8> via
L<Tcl::Tk::MT::Photo/put_rgba_packed>, batches towers, enemies, projectiles,
and beams per frame, and submits the packed particle instance buffer with
C<createInstances>.

=cut
