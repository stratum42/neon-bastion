package NeonBastion::Sim;

use strict;
use warnings;
use POSIX qw(floor);
use NeonBastion::Config ();

our $VERSION = '0.01';

my $TWO_PI = 6.283185307179586;

my $HAS_PACKED_AV = 0;
my $HAS_TD_STEP   = 0;

BEGIN {
    eval { require NeonBastion::SimXS; 1 };
    if (eval { NeonBastion::SimXS::have_packed_av() } && eval { require MT::Array; 1 }) {
        $HAS_PACKED_AV = 1;
    }
    $HAS_TD_STEP = defined(&NeonBastion::SimXS::step_particles) ? 1 : 0;
}

sub have_packed_av { $HAS_PACKED_AV }
sub has_td_step    { $HAS_TD_STEP }

sub _alloc_nv {
    my ($len) = @_;
    if ($HAS_PACKED_AV) {
        return MT::Array::packed('NV', (0.0) x $len);
    }
    return [ (0.0) x $len ];
}

sub new {
    my ($class, %opts) = @_;
    my $max_p = int($opts{max_particles} || $NeonBastion::Config::MAX_PARTICLES);
    my $self = bless {
        # Game economy & progression
        credits         => $NeonBastion::Config::START_CREDITS,
        core_hp         => $NeonBastion::Config::START_CORE_HP,
        max_core_hp     => $NeonBastion::Config::START_CORE_HP,
        wave            => 0,
        score           => 0,
        kills           => 0,
        enemies_spawned => 0,
        towers_built    => 0,
        game_over       => 0,
        endless_mode    => 0,

        # Controls & timing
        sim_time        => 0.0,
        frame_num       => 0,
        speed_mult      => 1,
        auto_play       => $opts{demo} ? 1 : 0,
        ai_timer        => 0.0,
        ai_plan_idx     => 0,
        wave_active     => 0,
        wave_inter_t    => 0.0,
        wave_banner     => '',
        wave_banner_t   => 0.0,

        # Entities
        next_id         => 1,
        towers          => [],
        tower_grid      => {},
        enemies         => [],
        spawn_queue     => [],
        projectiles     => [],
        beams           => [],
        novas           => [],

        # Screen shake
        shake_mag       => 0.0,
        shake_x         => 0.0,
        shake_y         => 0.0,

        # Preallocated particle system (zero per-frame allocations)
        p_cap           => $max_p,
        p_cursor        => 0,
        p_high_water    => 0,
        p_live          => 0,
        p_inst_count    => 0,
        peak_particles  => 0,
        p_px            => _alloc_nv($max_p),
        p_py            => _alloc_nv($max_p),
        p_vx            => _alloc_nv($max_p),
        p_vy            => _alloc_nv($max_p),
        p_life          => _alloc_nv($max_p),
        p_max_life      => _alloc_nv($max_p),
        p_size          => _alloc_nv($max_p),
        p_col_start     => _alloc_nv($max_p),
        p_col_end       => _alloc_nv($max_p),
        p_inst_out      => _alloc_nv($max_p * 2 * 4),

        # Deterministic PRNG state for reproducible headless benchmarks
        rng_state       => int($opts{seed} || 133742),
    }, $class;

    if ($self->{auto_play}) {
        $self->_run_ai_decisions();
        $self->start_next_wave();
    }

    return $self;
}

# Fast xorshift32 PRNG in [0, 1)
sub _rand {
    my ($self) = @_;
    my $x = $self->{rng_state} & 0xFFFFFFFF;
    $x ^= ($x << 13) & 0xFFFFFFFF;
    $x ^= ($x >> 17) & 0xFFFFFFFF;
    $x ^= ($x << 5)  & 0xFFFFFFFF;
    $x = 1 if $x == 0;
    $self->{rng_state} = $x;
    return $x / 4294967296.0;
}

sub set_auto_play {
    my ($self, $v) = @_;
    $self->{auto_play} = $v ? 1 : 0;
    if ($self->{auto_play} && $self->{wave} == 0 && !$self->{wave_active}) {
        $self->_run_ai_decisions();
        $self->start_next_wave();
    }
}

sub toggle_speed {
    my ($self) = @_;
    $self->{speed_mult} = ($self->{speed_mult} == 1) ? 2 : 1;
    return $self->{speed_mult};
}

sub add_shake {
    my ($self, $mag) = @_;
    $self->{shake_mag} = $mag if $mag > $self->{shake_mag};
}

# =============================================================================
# Particle Emission (O(1) ring-buffer write into preallocated packed NV arrays)
# =============================================================================
sub emit_particle {
    my ($self, $x, $y, $vx, $vy, $life, $size, $col_start, $col_end) = @_;
    my $idx = $self->{p_cursor};
    my $cap = $self->{p_cap};
    $self->{p_cursor} = ($idx + 1 >= $cap) ? 0 : ($idx + 1);
    $self->{p_high_water} = $idx + 1 if $idx + 1 > $self->{p_high_water};

    $self->{p_px}[$idx]        = $x;
    $self->{p_py}[$idx]        = $y;
    $self->{p_vx}[$idx]        = $vx;
    $self->{p_vy}[$idx]        = $vy;
    $self->{p_life}[$idx]      = $life;
    $self->{p_max_life}[$idx]  = $life;
    $self->{p_size}[$idx]      = $size;
    $self->{p_col_start}[$idx] = $col_start;
    $self->{p_col_end}[$idx]   = defined($col_end) ? $col_end : $col_start;
    return;
}

sub emit_burst {
    my ($self, $x, $y, $count, $speed_min, $speed_max, $life_min, $life_max, $size_min, $size_max, $col_start, $col_end) = @_;
    for (my $i = 0; $i < $count; $i++) {
        my $ang = $self->_rand() * $TWO_PI;
        my $spd = $speed_min + ($speed_max - $speed_min) * $self->_rand();
        my $lf  = $life_min  + ($life_max  - $life_min)  * $self->_rand();
        my $sz  = $size_min  + ($size_max  - $size_min)  * $self->_rand();
        $self->emit_particle(
            $x, $y,
            cos($ang) * $spd, sin($ang) * $spd,
            $lf, $sz, $col_start, $col_end
        );
    }
}

# =============================================================================
# Tower Placement, Upgrade, Sell
# =============================================================================
sub tower_at {
    my ($self, $col, $row) = @_;
    return $self->{tower_grid}{"$col,$row"};
}

sub can_build {
    my ($self, $col, $row, $type) = @_;
    return (0, 'Out of bounds') unless NeonBastion::Config::in_bounds_tile($col, $row);
    return (0, 'On enemy path') if NeonBastion::Config::is_path_tile($col, $row);
    return (0, 'Occupied')      if exists $self->{tower_grid}{"$col,$row"};
    my $spec = $NeonBastion::Config::TOWERS{$type};
    return (0, 'Unknown tower') unless $spec;
    return (0, 'Insufficient credits') if $self->{credits} < $spec->{cost};
    return (1, 'OK');
}

sub build_tower {
    my ($self, $col, $row, $type) = @_;
    my ($ok, $reason) = $self->can_build($col, $row, $type);
    return undef unless $ok;

    my $spec = $NeonBastion::Config::TOWERS{$type};
    my ($x, $y) = NeonBastion::Config::tile_center($col, $row);

    $self->{credits} -= $spec->{cost};
    $self->{towers_built}++;

    my $tower = {
        id           => $self->{next_id}++,
        col          => $col,
        row          => $row,
        x            => $x,
        y            => $y,
        type         => $type,
        level        => 1,
        invested     => $spec->{cost},
        angle        => 0.0,
        cooldown     => 0.0,
        muzzle_flash => 0.0,
        recoil       => 0.0,
        kills        => 0,
    };
    push @{ $self->{towers} }, $tower;
    $self->{tower_grid}{"$col,$row"} = $tower;

    # Build burst VFX
    $self->emit_burst(
        $x, $y, 24, 35, 140, 0.25, 0.55, 1.8, 3.8,
        $spec->{p_rgba_hi}, $spec->{p_rgba}
    );
    return $tower;
}

sub upgrade_cost {
    my ($self, $tower) = @_;
    return undef unless $tower && $tower->{level} < 3;
    my $spec = $NeonBastion::Config::TOWERS{ $tower->{type} };
    return $spec->{upgrade_costs}[ $tower->{level} ];
}

sub upgrade_tower {
    my ($self, $tower) = @_;
    my $cost = $self->upgrade_cost($tower);
    return 0 unless defined $cost && $self->{credits} >= $cost;

    $self->{credits}   -= $cost;
    $tower->{invested} += $cost;
    $tower->{level}++;

    my $spec = $NeonBastion::Config::TOWERS{ $tower->{type} };
    $self->emit_burst(
        $tower->{x}, $tower->{y}, 36, 45, 180, 0.30, 0.65, 2.0, 4.5,
        $NeonBastion::Config::PARTICLE_RGBA{white}, $spec->{p_rgba}
    );
    return 1;
}

sub sell_tower {
    my ($self, $tower) = @_;
    return 0 unless $tower;
    my $key = "$tower->{col},$tower->{row}";
    return 0 unless exists $self->{tower_grid}{$key};

    my $refund = int($tower->{invested} * $NeonBastion::Config::SELL_REFUND + 0.5);
    $self->{credits} += $refund;
    delete $self->{tower_grid}{$key};
    $self->{towers} = [ grep { $_->{id} != $tower->{id} } @{ $self->{towers} } ];

    $self->emit_burst(
        $tower->{x}, $tower->{y}, 22, 25, 120, 0.20, 0.50, 1.6, 3.5,
        $NeonBastion::Config::PARTICLE_RGBA{gold}, $NeonBastion::Config::PARTICLE_RGBA{cyan}
    );
    return $refund;
}

# =============================================================================
# Wave Management
# =============================================================================
sub start_next_wave {
    my ($self) = @_;
    return 0 if $self->{game_over};
    return 0 if $self->{wave_active};

    $self->{wave}++;
    $self->{endless_mode} = 1 if $self->{wave} > scalar(@NeonBastion::Config::WAVES);

    my ($groups, $hp_scale) = NeonBastion::Config::get_wave_spec($self->{wave});
    my @queue;
    for my $g (@$groups) {
        my $t = $self->{sim_time} + ($g->{delay} || 0.0);
        for (my $i = 0; $i < $g->{count}; $i++) {
            push @queue, {
                time     => $t + $i * $g->{interval},
                type     => $g->{type},
                hp_scale => $hp_scale,
            };
        }
    }
    @queue = sort { $a->{time} <=> $b->{time} } @queue;
    $self->{spawn_queue}   = \@queue;
    $self->{wave_active}   = 1;
    $self->{wave_banner}   = ($self->{wave} % 5 == 0)
        ? sprintf('WARNING: WAVE %d — DREADNOUGHT DETECTED', $self->{wave})
        : ($self->{endless_mode}
            ? sprintf('ENDLESS WAVE %d', $self->{wave})
            : sprintf('WAVE %d / %d', $self->{wave}, scalar(@NeonBastion::Config::WAVES)));
    $self->{wave_banner_t} = 2.4;
    return 1;
}

sub _spawn_enemy {
    my ($self, $type, $hp_scale) = @_;
    my $spec = $NeonBastion::Config::ENEMIES{$type} || $NeonBastion::Config::ENEMIES{swarm};
    my ($x, $y, $ang) = NeonBastion::Config::path_pos_at(0.0);
    my $max_hp = int($spec->{hp} * $hp_scale + 0.5);
    $max_hp = 1 if $max_hp < 1;

    my $e = {
        id          => $self->{next_id}++,
        type        => $type,
        dist        => 0.0,
        x           => $x,
        y           => $y,
        angle       => $ang,
        hp          => $max_hp,
        max_hp      => $max_hp,
        speed       => $spec->{speed},
        bounty      => $spec->{bounty},
        score       => $spec->{score},
        core_dmg    => $spec->{core_dmg},
        radius      => $spec->{radius},
        slow_timer  => 0.0,
        slow_factor => 1.0,
        hit_flash   => 0.0,
        alive       => 1,
        pulse_phase => $self->_rand() * $TWO_PI,
    };
    push @{ $self->{enemies} }, $e;
    $self->{enemies_spawned}++;

    # Portal spawn burst
    $self->emit_burst(
        $x, $y, ($type eq 'boss' ? 45 : 10), 25, 110, 0.20, 0.45, 1.5, 3.2,
        $spec->{p_rgba}, $NeonBastion::Config::PARTICLE_RGBA{portal}
    );
}

# =============================================================================
# Auto-Play AI (for --demo and Auto-Play toggle)
# =============================================================================
sub _run_ai_decisions {
    my ($self) = @_;
    return if $self->{game_over};

    my $plan = \@NeonBastion::Config::AI_BUILD_PLAN;

    # Build up to 3 affordable towers from the build plan per tick
    my $built_now = 0;
    while ($self->{ai_plan_idx} < @$plan && $built_now < 3) {
        my $slot = $plan->[ $self->{ai_plan_idx} ];
        if (exists $self->{tower_grid}{"$slot->{col},$slot->{row}"}) {
            $self->{ai_plan_idx}++;
            next;
        }
        my ($ok) = $self->can_build($slot->{col}, $slot->{row}, $slot->{type});
        if ($ok) {
            $self->build_tower($slot->{col}, $slot->{row}, $slot->{type});
            $self->{ai_plan_idx}++;
            $built_now++;
        }
        else {
            last;
        }
    }

    # Upgrade existing towers once at least 4 are placed
    if (@{ $self->{towers} } >= 4) {
        for my $t (@{ $self->{towers} }) {
            my $ucost = $self->upgrade_cost($t);
            if (defined $ucost && $self->{credits} >= $ucost + 40) {
                $self->upgrade_tower($t);
                last;
            }
        }
    }
}

# =============================================================================
# Main Simulation Step
# =============================================================================
sub step {
    my ($self, $raw_dt) = @_;
    $raw_dt = 1.0 / 60.0 unless defined $raw_dt && $raw_dt > 0;
    $raw_dt = 0.05 if $raw_dt > 0.05;    # clamp dt spike

    my $dt = $raw_dt * ($self->{speed_mult} || 1);
    $self->{sim_time} += $dt;
    $self->{frame_num}++;

    if ($self->{wave_banner_t} > 0.0) {
        $self->{wave_banner_t} -= $raw_dt;
        $self->{wave_banner_t} = 0.0 if $self->{wave_banner_t} < 0.0;
    }

    # Update screen shake
    if ($self->{shake_mag} > 0.05) {
        $self->{shake_x} = ($self->_rand() * 2.0 - 1.0) * $self->{shake_mag};
        $self->{shake_y} = ($self->_rand() * 2.0 - 1.0) * $self->{shake_mag};
        $self->{shake_mag} *= (0.86 ** ($raw_dt * 60.0));
    }
    else {
        $self->{shake_mag} = 0.0;
        $self->{shake_x}   = 0.0;
        $self->{shake_y}   = 0.0;
    }

    # Ambient portal & bastion core sparkles
    if (($self->{frame_num} & 1) == 0) {
        my ($sx, $sy) = @{ $NeonBastion::Config::PATH_WAYPOINTS[0] };
        my ($bx, $by) = @{ $NeonBastion::Config::PATH_WAYPOINTS[-1] };
        my $a1 = $self->_rand() * $TWO_PI;
        $self->emit_particle(
            $sx + cos($a1) * 14, $sy + sin($a1) * 14,
            cos($a1) * 28, sin($a1) * 28,
            0.45, 2.2, $NeonBastion::Config::PARTICLE_RGBA{crimson}, $NeonBastion::Config::PARTICLE_RGBA{portal}
        );
        my $a2 = $self->_rand() * $TWO_PI;
        $self->emit_particle(
            $bx + cos($a2) * 16, $by + sin($a2) * 16,
            -cos($a2) * 20, -sin($a2) * 20,
            0.50, 2.2, $NeonBastion::Config::PARTICLE_RGBA{cyan_bright}, $NeonBastion::Config::PARTICLE_RGBA{core}
        );
    }

    if (!$self->{game_over}) {
        # Auto-Play AI tick
        if ($self->{auto_play}) {
            $self->{ai_timer} -= $dt;
            if ($self->{ai_timer} <= 0.0) {
                $self->{ai_timer} = 0.22;
                $self->_run_ai_decisions();
            }
            if (!$self->{wave_active}) {
                $self->{wave_inter_t} -= $dt;
                if ($self->{wave_inter_t} <= 0.0) {
                    $self->start_next_wave();
                }
            }
        }

        # 1. Spawn queued enemies
        my $sq = $self->{spawn_queue};
        while (@$sq && $sq->[0]{time} <= $self->{sim_time}) {
            my $ev = shift @$sq;
            $self->_spawn_enemy($ev->{type}, $ev->{hp_scale});
        }

        # 2. Advance enemies along S-curve path
        my $total_len = $NeonBastion::Config::PATH_TOTAL_LEN;
        my $alive_enemies = [];
        for my $e (@{ $self->{enemies} }) {
            next unless $e->{alive};

            if ($e->{slow_timer} > 0.0) {
                $e->{slow_timer} -= $dt;
                if ($e->{slow_timer} <= 0.0) {
                    $e->{slow_timer}  = 0.0;
                    $e->{slow_factor} = 1.0;
                }
            }
            if ($e->{hit_flash} > 0.0) {
                $e->{hit_flash} -= $dt;
                $e->{hit_flash} = 0.0 if $e->{hit_flash} < 0.0;
            }

            my $spd = $e->{speed} * $e->{slow_factor};
            $e->{dist} += $spd * $dt;
            $e->{pulse_phase} += $dt * 4.5;

            if ($e->{dist} >= $total_len) {
                # Enemy reached Bastion Core
                $e->{alive} = 0;
                $self->{core_hp} -= $e->{core_dmg};
                $self->{core_hp} = 0 if $self->{core_hp} < 0;
                $self->add_shake($e->{type} eq 'boss' ? 16.0 : 9.0);
                my ($bx, $by) = @{ $NeonBastion::Config::PATH_WAYPOINTS[-1] };
                $self->emit_burst(
                    $bx, $by, 48, 40, 210, 0.30, 0.70, 2.2, 4.8,
                    $NeonBastion::Config::PARTICLE_RGBA{crimson},
                    $NeonBastion::Config::PARTICLE_RGBA{gold}
                );
                if ($self->{core_hp} <= 0) {
                    $self->{game_over}     = 1;
                    $self->{wave_banner}   = 'BASTION CORE BREACHED — SYSTEM OFFLINE';
                    $self->{wave_banner_t} = 999.0;
                }
                next;
            }

            my ($nx, $ny, $ang) = NeonBastion::Config::path_pos_at($e->{dist});
            $e->{x}     = $nx;
            $e->{y}     = $ny;
            $e->{angle} = $ang;

            # Subtle movement trail sparks
            if ($e->{type} eq 'boss' || $e->{type} eq 'phantom' || (($self->{frame_num} + $e->{id}) & 3) == 0) {
                my $spec = $NeonBastion::Config::ENEMIES{ $e->{type} };
                my $col  = $e->{slow_timer} > 0 ? $NeonBastion::Config::PARTICLE_RGBA{ice} : $spec->{p_rgba};
                $self->emit_particle(
                    $nx - cos($ang) * ($e->{radius} * 0.6),
                    $ny - sin($ang) * ($e->{radius} * 0.6),
                    -cos($ang) * 22 + ($self->_rand() - 0.5) * 18,
                    -sin($ang) * 22 + ($self->_rand() - 0.5) * 18,
                    0.26, ($e->{type} eq 'boss' ? 3.2 : 1.7),
                    $col, $col
                );
            }

            push @$alive_enemies, $e;
        }
        $self->{enemies} = $alive_enemies;

        # 3. Towers acquire targets & fire
        $self->_step_towers($dt);

        # 4. Advance Pulse plasma projectiles
        $self->_step_projectiles($dt);

        # Prune newly dead enemies
        $self->{enemies} = [ grep { $_->{alive} } @{ $self->{enemies} } ];

        # Check wave completion
        if ($self->{wave_active} && !@{ $self->{spawn_queue} } && !@{ $self->{enemies} }) {
            $self->{wave_active}  = 0;
            $self->{wave_inter_t} = 0.8;
            my $bonus = 35 + $self->{wave} * 10;
            $self->{credits} += $bonus;
            $self->{score}   += $bonus * 2;
        }
    }

    # 5. Decay transient VFX beams & cryo-novas
    my @next_beams;
    for my $b (@{ $self->{beams} }) {
        $b->{life} -= $dt;
        push @next_beams, $b if $b->{life} > 0.0;
    }
    $self->{beams} = \@next_beams;

    my @next_novas;
    for my $n (@{ $self->{novas} }) {
        $n->{life} -= $dt;
        if ($n->{life} > 0.0) {
            my $prog = 1.0 - ($n->{life} / $n->{max_life});
            $n->{radius} = 16.0 + ($n->{max_radius} - 16.0) * $prog;
            push @next_novas, $n;
        }
    }
    $self->{novas} = \@next_novas;

    # 6. Step particles via NeonBastion::SimXS (or Perl fallback)
    $self->_step_particles($dt);

    return;
}

sub _damage_enemy {
    my ($self, $e, $dmg, $tower, $hit_rgba) = @_;
    return unless $e && $e->{alive};
    $e->{hp}        -= $dmg;
    $e->{hit_flash}  = 0.09;

    if ($e->{hp} <= 0) {
        $e->{alive} = 0;
        $self->{credits} += $e->{bounty};
        $self->{score}   += $e->{score};
        $self->{kills}++;
        $tower->{kills}++ if $tower;

        my $spec = $NeonBastion::Config::ENEMIES{ $e->{type} };
        my $is_boss = ($e->{type} eq 'boss') ? 1 : 0;
        $self->emit_burst(
            $e->{x}, $e->{y},
            $spec->{death_pts},
            ($is_boss ? 45 : 35), ($is_boss ? 340 : 185),
            ($is_boss ? 0.45 : 0.25), ($is_boss ? 1.15 : 0.62),
            ($is_boss ? 2.4 : 1.8), ($is_boss ? 5.6 : 4.0),
            $NeonBastion::Config::PARTICLE_RGBA{white},
            $spec->{p_rgba}
        );
        if ($is_boss) {
            # Secondary gold ring burst and screen shake
            $self->emit_burst(
                $e->{x}, $e->{y}, 80, 90, 260, 0.35, 0.90, 2.2, 4.8,
                $NeonBastion::Config::PARTICLE_RGBA{gold_bright},
                $NeonBastion::Config::PARTICLE_RGBA{crimson}
            );
            $self->add_shake(14.0);
        }
    }
    else {
        # Hit sparks
        my $col = $hit_rgba || $NeonBastion::Config::PARTICLE_RGBA{cyan_bright};
        $self->emit_burst(
            $e->{x}, $e->{y}, 5, 30, 120, 0.14, 0.30, 1.4, 2.6,
            $NeonBastion::Config::PARTICLE_RGBA{white}, $col
        );
    }
}

sub _step_towers {
    my ($self, $dt) = @_;
    my $enemies = $self->{enemies};

    for my $t (@{ $self->{towers} }) {
        $t->{cooldown}     -= $dt if $t->{cooldown} > 0.0;
        $t->{muzzle_flash} -= $dt if $t->{muzzle_flash} > 0.0;
        $t->{recoil}       -= $dt * 18.0 if $t->{recoil} > 0.0;
        $t->{recoil}        = 0.0 if $t->{recoil} < 0.0;

        my $spec = $NeonBastion::Config::TOWERS{ $t->{type} };
        my $lvl  = $spec->{levels}[ $t->{level} - 1 ];
        my $rng  = $lvl->{range};
        my $rng2 = $rng * $rng;

        # Target enemy furthest along the path within range (First targeting)
        my $best;
        my $best_dist = -1.0;
        for my $e (@$enemies) {
            next unless $e->{alive};
            my $dx = $e->{x} - $t->{x};
            my $dy = $e->{y} - $t->{y};
            if ($dx * $dx + $dy * $dy <= $rng2 && $e->{dist} > $best_dist) {
                $best_dist = $e->{dist};
                $best      = $e;
            }
        }
        next unless $best;

        # Rotate turret toward target
        $t->{angle} = atan2($best->{y} - $t->{y}, $best->{x} - $t->{x});

        next if $t->{cooldown} > 0.0;
        $t->{cooldown}     = 1.0 / $lvl->{fire_rate};
        $t->{muzzle_flash} = 0.08;
        $t->{recoil}       = 4.5;

        if ($t->{type} eq 'pulse') {
            $self->_fire_pulse($t, $best, $spec, $lvl);
        }
        elsif ($t->{type} eq 'rail') {
            $self->_fire_rail($t, $best, $spec, $lvl);
        }
        elsif ($t->{type} eq 'frost') {
            $self->_fire_frost($t, $spec, $lvl);
        }
        elsif ($t->{type} eq 'tesla') {
            $self->_fire_tesla($t, $best, $spec, $lvl);
        }
    }
}

sub _fire_pulse {
    my ($self, $t, $target, $spec, $lvl) = @_;
    my $ang = $t->{angle};
    my $ca  = cos($ang);
    my $sa  = sin($ang);
    my $px  = -$sa * 5.0;   # twin barrel perpendicular offset
    my $py  =  $ca * 5.0;
    my $spd = $lvl->{proj_speed};

    for my $side (-1, 1) {
        my $mx = $t->{x} + $ca * 18.0 + $px * $side;
        my $my = $t->{y} + $sa * 18.0 + $py * $side;
        push @{ $self->{projectiles} }, {
            x         => $mx,
            y         => $my,
            vx        => $ca * $spd,
            vy        => $sa * $spd,
            target_id => $target->{id},
            tower     => $t,
            damage    => $lvl->{damage} * 0.5,
            color     => $spec->{color},
            glow      => $spec->{color_glow},
            p_rgba    => $spec->{p_rgba},
            life      => 0.85,
        };
        # Muzzle spark
        $self->emit_particle(
            $mx, $my,
            $ca * 130 + ($self->_rand() - 0.5) * 50,
            $sa * 130 + ($self->_rand() - 0.5) * 50,
            0.16, 2.4, $spec->{p_rgba_hi}, $spec->{p_rgba}
        );
    }
}

sub _fire_rail {
    my ($self, $t, $target, $spec, $lvl) = @_;
    my $ang  = $t->{angle};
    my $ca   = cos($ang);
    my $sa   = sin($ang);
    my $x0   = $t->{x} + $ca * 20.0;
    my $y0   = $t->{y} + $sa * 20.0;
    my $blen = $lvl->{range} + 28.0;
    my $x1   = $t->{x} + $ca * $blen;
    my $y1   = $t->{y} + $sa * $blen;

    # Hit target + pierce additional enemies along the ray
    my @hits;
    for my $e (@{ $self->{enemies} }) {
        next unless $e->{alive};
        my $ex   = $e->{x} - $t->{x};
        my $ey   = $e->{y} - $t->{y};
        my $proj = $ex * $ca + $ey * $sa;
        next if $proj < 0.0 || $proj > $blen + $e->{radius};
        my $perp = abs(-$ex * $sa + $ey * $ca);
        if ($perp <= $e->{radius} + 10.0) {
            push @hits, [ $proj, $e ];
        }
    }
    @hits = sort { $a->[0] <=> $b->[0] } @hits;

    my $pierce = $lvl->{pierce} || 2;
    my $n_hit  = 0;
    my @rings;
    for my $h (@hits) {
        last if $n_hit >= $pierce;
        my $e = $h->[1];
        $self->_damage_enemy($e, $lvl->{damage}, $t, $spec->{p_rgba});
        push @rings, [ $e->{x}, $e->{y} ];
        $n_hit++;
    }

    # Shockwave rings spaced along the rail beam
    for my $frac (0.28, 0.56, 0.84) {
        push @rings, [ $x0 + ($x1 - $x0) * $frac, $y0 + ($y1 - $y0) * $frac ];
    }

    push @{ $self->{beams} }, {
        kind       => 'rail',
        points     => [ $x0, $y0, $x1, $y1 ],
        rings      => \@rings,
        color      => $spec->{color},
        core_color => $spec->{color_glow},
        life       => 0.18,
        max_life   => 0.18,
    };

    # Railgun golden beam spark trail
    for my $s (1 .. 14) {
        my $f  = $s / 14.0;
        my $bx = $x0 + ($x1 - $x0) * $f;
        my $by = $y0 + ($y1 - $y0) * $f;
        $self->emit_particle(
            $bx, $by,
            ($self->_rand() - 0.5) * 90,
            ($self->_rand() - 0.5) * 90,
            0.24 + $self->_rand() * 0.16, 2.4,
            $spec->{p_rgba_hi}, $spec->{p_rgba}
        );
    }
}

sub _fire_frost {
    my ($self, $t, $spec, $lvl) = @_;
    my $rng  = $lvl->{range};
    my $rng2 = $rng * $rng;

    for my $e (@{ $self->{enemies} }) {
        next unless $e->{alive};
        my $dx = $e->{x} - $t->{x};
        my $dy = $e->{y} - $t->{y};
        if ($dx * $dx + $dy * $dy <= $rng2) {
            if ($lvl->{slow_factor} < $e->{slow_factor} || $e->{slow_timer} <= 0.0) {
                $e->{slow_factor} = $lvl->{slow_factor};
            }
            $e->{slow_timer} = $lvl->{slow_dur} if $lvl->{slow_dur} > $e->{slow_timer};
            $self->_damage_enemy($e, $lvl->{damage}, $t, $spec->{p_rgba});
        }
    }

    push @{ $self->{novas} }, {
        x          => $t->{x},
        y          => $t->{y},
        radius     => 16.0,
        max_radius => $rng,
        color      => $spec->{color},
        glow       => $spec->{color_glow},
        life       => 0.34,
        max_life   => 0.34,
    };

    # Radial frost mist ring
    $self->emit_burst(
        $t->{x}, $t->{y}, 28, 70, 190, 0.28, 0.55, 2.0, 3.8,
        $spec->{p_rgba_hi}, $spec->{p_rgba}
    );
}

sub _fire_tesla {
    my ($self, $t, $first_target, $spec, $lvl) = @_;
    my $max_chains = $lvl->{chains} || 3;
    my $jump_r2    = ($lvl->{jump_range} || 130) ** 2;

    my %visited;
    my @chain_targets = ($first_target);
    $visited{ $first_target->{id} } = 1;

    my $cur = $first_target;
    while (@chain_targets < $max_chains) {
        my $next_e;
        my $best_d2 = $jump_r2;
        for my $e (@{ $self->{enemies} }) {
            next unless $e->{alive};
            next if $visited{ $e->{id} };
            my $dx = $e->{x} - $cur->{x};
            my $dy = $e->{y} - $cur->{y};
            my $d2 = $dx * $dx + $dy * $dy;
            if ($d2 <= $best_d2) {
                $best_d2 = $d2;
                $next_e  = $e;
            }
        }
        last unless $next_e;
        $visited{ $next_e->{id} } = 1;
        push @chain_targets, $next_e;
        $cur = $next_e;
    }

    # Build procedural jagged lightning polyline segments
    my @nodes = ([ $t->{x}, $t->{y} ]);
    my $dmg_mult = 1.0;
    for my $e (@chain_targets) {
        push @nodes, [ $e->{x}, $e->{y} ];
        $self->_damage_enemy($e, $lvl->{damage} * $dmg_mult, $t, $spec->{p_rgba});
        $dmg_mult *= 0.85;
        $self->emit_burst(
            $e->{x}, $e->{y}, 10, 40, 160, 0.16, 0.34, 1.6, 3.2,
            $spec->{p_rgba_hi}, $spec->{p_rgba}
        );
    }

    my @jagged;
    for my $i (0 .. $#nodes - 1) {
        my ($x0, $y0) = @{ $nodes[$i] };
        my ($x1, $y1) = @{ $nodes[$i + 1] };
        my $dx = $x1 - $x0;
        my $dy = $y1 - $y0;
        my $len = sqrt($dx * $dx + $dy * $dy) || 1.0;
        my $nx = -$dy / $len;
        my $ny =  $dx / $len;

        push @jagged, $x0, $y0 if $i == 0;
        my $segs = 5;
        for my $s (1 .. $segs - 1) {
            my $f   = $s / $segs;
            my $jit = ($self->_rand() * 2.0 - 1.0) * 14.0;
            push @jagged, ($x0 + $dx * $f + $nx * $jit), ($y0 + $dy * $f + $ny * $jit);
        }
        push @jagged, $x1, $y1;
    }

    push @{ $self->{beams} }, {
        kind       => 'tesla',
        points     => \@jagged,
        color      => $spec->{color},
        core_color => $spec->{color_glow},
        life       => 0.15,
        max_life   => 0.15,
    };
}

sub _step_projectiles {
    my ($self, $dt) = @_;
    my %enemy_by_id = map { $_->{id} => $_ } grep { $_->{alive} } @{ $self->{enemies} };
    my @next;

    for my $p (@{ $self->{projectiles} }) {
        $p->{life} -= $dt;
        next if $p->{life} <= 0.0;

        # Soft homing toward live target
        my $tgt = $enemy_by_id{ $p->{target_id} };
        if ($tgt && $tgt->{alive}) {
            my $dx  = $tgt->{x} - $p->{x};
            my $dy  = $tgt->{y} - $p->{y};
            my $d   = sqrt($dx * $dx + $dy * $dy) || 1.0;
            my $spd = sqrt($p->{vx} * $p->{vx} + $p->{vy} * $p->{vy}) || 580.0;
            $p->{vx} = ($dx / $d) * $spd;
            $p->{vy} = ($dy / $d) * $spd;
        }

        $p->{x} += $p->{vx} * $dt;
        $p->{y} += $p->{vy} * $dt;

        # Check collision with target (or any close enemy)
        my $hit;
        if ($tgt && $tgt->{alive}) {
            my $dx = $tgt->{x} - $p->{x};
            my $dy = $tgt->{y} - $p->{y};
            my $r  = $tgt->{radius} + 8.0;
            $hit = $tgt if ($dx * $dx + $dy * $dy) <= $r * $r;
        }
        if (!$hit) {
            for my $e (@{ $self->{enemies} }) {
                next unless $e->{alive};
                my $dx = $e->{x} - $p->{x};
                my $dy = $e->{y} - $p->{y};
                my $r  = $e->{radius} + 6.0;
                if ($dx * $dx + $dy * $dy <= $r * $r) {
                    $hit = $e;
                    last;
                }
            }
        }

        if ($hit) {
            $self->_damage_enemy($hit, $p->{damage}, $p->{tower}, $p->{p_rgba});
        }
        else {
            push @next, $p;
        }
    }

    $self->{projectiles} = \@next;
}

sub _step_particles {
    my ($self, $dt) = @_;
    my $n = $self->{p_high_water};
    if ($n <= 0) {
        $self->{p_live}       = 0;
        $self->{p_inst_count} = 0;
        return;
    }

    if ($HAS_TD_STEP) {
        my $num_inst = NeonBastion::SimXS::step_particles(
            $self->{p_px},
            $self->{p_py},
            $self->{p_vx},
            $self->{p_vy},
            $self->{p_life},
            $self->{p_max_life},
            $self->{p_size},
            $self->{p_col_start},
            $self->{p_col_end},
            $self->{p_inst_out},
            $n,
            $dt,
            2.6,    # air drag
            0,      # auto worker count
        );
        $self->{p_inst_count} = $num_inst;
        my $live = int($num_inst / 2);
        $self->{p_live} = $live;
        $self->{peak_particles} = $live if $live > $self->{peak_particles};
        return;
    }

    # Pure-Perl fallback if td_step_particles is unavailable
    my $drag = exp(-2.6 * $dt);
    my $out  = $self->{p_inst_out};
    my $oi   = 0;
    my $live = 0;
    for (my $i = 0; $i < $n; $i++) {
        my $lf = $self->{p_life}[$i];
        next if $lf <= 0.0;
        $lf -= $dt;
        if ($lf <= 0.0) {
            $self->{p_life}[$i] = 0.0;
            next;
        }
        $self->{p_life}[$i] = $lf;
        my $vx = $self->{p_vx}[$i] * $drag;
        my $vy = $self->{p_vy}[$i] * $drag;
        my $x  = $self->{p_px}[$i] + $vx * $dt;
        my $y  = $self->{p_py}[$i] + $vy * $dt;
        $self->{p_vx}[$i] = $vx;
        $self->{p_vy}[$i] = $vy;
        $self->{p_px}[$i] = $x;
        $self->{p_py}[$i] = $y;

        my $sz  = $self->{p_size}[$i];
        my $col = $self->{p_col_start}[$i];
        $out->[$oi++] = $x;
        $out->[$oi++] = $y;
        $out->[$oi++] = $col;
        $out->[$oi++] = $sz;
        $live++;
    }
    my $prev_end = $self->{p_inst_count} * 4;
    while ($oi < $prev_end) {
        $out->[$oi++] = 0.0;
    }
    $self->{p_inst_count} = $live;
    $self->{p_live}       = $live;
    $self->{peak_particles} = $live if $live > $self->{peak_particles};
}

1;

__END__

=head1 NAME

NeonBastion::Sim - Tower defense game simulation and particle buffer manager

=head1 DESCRIPTION

Runs the fixed-timestep game loop in Perl (wave spawning, enemy movement,
tower targeting, projectiles, beams, and Auto-Play) while maintaining a
preallocated ring buffer of packed C<NV> arrays stepped by
L<NeonBastion::SimXS/step_particles> (with a pure-Perl fallback if the XS
helper is not loaded).

=cut
