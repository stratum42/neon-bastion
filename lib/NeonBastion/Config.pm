package NeonBastion::Config;

use strict;
use warnings;

our $VERSION = '0.01';

# =============================================================================
# Arena Geometry (960x600 = 16x10 grid of 60px tiles)
# =============================================================================
our $ARENA_W    = 960;
our $ARENA_H    = 600;
our $TILE_SIZE  = 60;
our $GRID_COLS  = 16;
our $GRID_ROWS  = 10;

# Maximum live GPU-instanced particles in preallocated packed NV buffers
our $MAX_PARTICLES = 12_000;

# Starting player resources
our $START_CREDITS = 250;
our $START_CORE_HP = 25;
our $SELL_REFUND   = 0.70;

# Tactical S-curve path waypoints in grid (col, row) coordinates
# Spawn Portal at (0, 2) -> winding S-curve -> Bastion Core at (15, 7)
our @PATH_GRID_WAYPOINTS = (
    [  0, 2 ],
    [  3, 2 ],
    [  3, 7 ],
    [  7, 7 ],
    [  7, 2 ],
    [ 11, 2 ],
    [ 11, 7 ],
    [ 15, 7 ],
);

# Convert grid cell (col, row) to arena pixel center (x, y)
sub tile_center {
    my ($col, $row) = @_;
    return ($col * $TILE_SIZE + $TILE_SIZE * 0.5, $row * $TILE_SIZE + $TILE_SIZE * 0.5);
}

# Build dense pixel waypoints and path-occupancy lookup table
our @PATH_WAYPOINTS;
our @PATH_SEG_LENS;
our $PATH_TOTAL_LEN = 0.0;
our %PATH_TILES;    # "col,row" => 1

for my $wp (@PATH_GRID_WAYPOINTS) {
    my ($x, $y) = tile_center($wp->[0], $wp->[1]);
    push @PATH_WAYPOINTS, [ $x, $y ];
}

for my $i (0 .. $#PATH_GRID_WAYPOINTS - 1) {
    my ($c0, $r0) = @{ $PATH_GRID_WAYPOINTS[$i] };
    my ($c1, $r1) = @{ $PATH_GRID_WAYPOINTS[$i + 1] };
    my $dc = $c1 <=> $c0;
    my $dr = $r1 <=> $r0;
    my ($c, $r) = ($c0, $r0);
    while (1) {
        $PATH_TILES{"$c,$r"} = 1;
        last if $c == $c1 && $r == $r1;
        $c += $dc;
        $r += $dr;
    }

    my ($x0, $y0) = @{ $PATH_WAYPOINTS[$i] };
    my ($x1, $y1) = @{ $PATH_WAYPOINTS[$i + 1] };
    my $seg_len = sqrt(($x1 - $x0) ** 2 + ($y1 - $y0) ** 2);
    push @PATH_SEG_LENS, $seg_len;
    $PATH_TOTAL_LEN += $seg_len;
}

sub is_path_tile {
    my ($col, $row) = @_;
    return $PATH_TILES{"$col,$row"} ? 1 : 0;
}

sub in_bounds_tile {
    my ($col, $row) = @_;
    return ($col >= 0 && $col < $GRID_COLS && $row >= 0 && $row < $GRID_ROWS) ? 1 : 0;
}

# Interpolate (x, y, angle_rad) along path distance d in [0, $PATH_TOTAL_LEN]
sub path_pos_at {
    my ($dist) = @_;
    if ($dist <= 0.0) {
        my ($x0, $y0) = @{ $PATH_WAYPOINTS[0] };
        my ($x1, $y1) = @{ $PATH_WAYPOINTS[1] };
        return ($x0, $y0, atan2($y1 - $y0, $x1 - $x0));
    }
    my $acc = 0.0;
    for my $i (0 .. $#PATH_SEG_LENS) {
        my $len = $PATH_SEG_LENS[$i];
        if ($dist <= $acc + $len || $i == $#PATH_SEG_LENS) {
            my $t = $len > 0 ? (($dist - $acc) / $len) : 0.0;
            $t = 1.0 if $t > 1.0;
            my ($x0, $y0) = @{ $PATH_WAYPOINTS[$i] };
            my ($x1, $y1) = @{ $PATH_WAYPOINTS[$i + 1] };
            return (
                $x0 + ($x1 - $x0) * $t,
                $y0 + ($y1 - $y0) * $t,
                atan2($y1 - $y0, $x1 - $x0),
            );
        }
        $acc += $len;
    }
    my ($xe, $ye) = @{ $PATH_WAYPOINTS[-1] };
    return ($xe, $ye, 0.0);
}

# =============================================================================
# Color Palette & Packed RGBA Helper
# =============================================================================
sub rgba_u32 {
    my ($r, $g, $b, $a) = @_;
    $a = 255 unless defined $a;
    return (($r & 0xFF) | (($g & 0xFF) << 8) | (($b & 0xFF) << 16) | (($a & 0xFF) << 24));
}

our %THEME = (
    bg_void       => '#060812',
    bg_panel      => '#0d1322',
    bg_card       => '#131c31',
    bg_hover      => '#1c2a46',
    border        => '#243554',
    text_pri      => '#e6f1ff',
    text_sec      => '#8ba3c7',
    cyan          => '#00f0ff',
    cyan_dim      => '#0e7490',
    gold          => '#fbbf24',
    gold_bright   => '#fef08a',
    ice           => '#60a5fa',
    ice_bright    => '#bae6fd',
    magenta       => '#e879f9',
    magenta_core  => '#f5d0fe',
    crimson       => '#ff2a6d',
    orange        => '#fb923c',
    violet        => '#a855f7',
    green         => '#22c55e',
    red_err       => '#ef4444',
);

# Pre-packed u32 RGBA colors for particle emission
our %PARTICLE_RGBA = (
    cyan         => rgba_u32(  0, 240, 255, 255),
    cyan_bright  => rgba_u32(165, 243, 252, 255),
    gold         => rgba_u32(251, 191,  36, 255),
    gold_bright  => rgba_u32(254, 249, 195, 255),
    ice          => rgba_u32( 96, 165, 250, 255),
    ice_bright   => rgba_u32(224, 242, 254, 255),
    magenta      => rgba_u32(232, 121, 249, 255),
    magenta_core => rgba_u32(250, 232, 255, 255),
    crimson      => rgba_u32(255,  42, 109, 255),
    orange       => rgba_u32(251, 146,  60, 255),
    violet       => rgba_u32(168,  85, 247, 255),
    green        => rgba_u32( 34, 197,  94, 255),
    white        => rgba_u32(255, 255, 255, 255),
    portal       => rgba_u32(255,  70, 140, 220),
    core         => rgba_u32( 56, 189, 248, 220),
);

# =============================================================================
# 4 Upgradeable Neon Tower Definitions (Levels 1..3)
# =============================================================================
our @TOWER_ORDER = qw(pulse rail frost tesla);

our %TOWERS = (
    pulse => {
        id            => 'pulse',
        name          => 'PULSE',
        hotkey        => '1',
        desc          => 'Twin rapid-fire cyan plasma bolts',
        cost          => 50,
        upgrade_costs => [ 0, 65, 105 ],      # index = target level - 1
        color         => '#00f0ff',
        color_dark    => '#083344',
        color_glow    => '#67e8f9',
        p_rgba        => $PARTICLE_RGBA{cyan},
        p_rgba_hi     => $PARTICLE_RGBA{cyan_bright},
        levels        => [
            { range => 155, damage => 18, fire_rate => 4.8, proj_speed => 580 },
            { range => 178, damage => 30, fire_rate => 6.0, proj_speed => 640 },
            { range => 205, damage => 46, fire_rate => 7.4, proj_speed => 700 },
        ],
    },
    rail => {
        id            => 'rail',
        name          => 'RAIL',
        hotkey        => '2',
        desc          => 'High-damage piercing gold railgun beam',
        cost          => 100,
        upgrade_costs => [ 0, 125, 185 ],
        color         => '#fbbf24',
        color_dark    => '#451a03',
        color_glow    => '#fef08a',
        p_rgba        => $PARTICLE_RGBA{gold},
        p_rgba_hi     => $PARTICLE_RGBA{gold_bright},
        levels        => [
            { range => 245, damage =>  78, fire_rate => 0.90, pierce => 2 },
            { range => 280, damage => 135, fire_rate => 1.12, pierce => 3 },
            { range => 320, damage => 225, fire_rate => 1.38, pierce => 4 },
        ],
    },
    frost => {
        id            => 'frost',
        name          => 'FROST',
        hotkey        => '3',
        desc          => 'Expanding cryo-nova rings slowing enemies',
        cost          => 80,
        upgrade_costs => [ 0, 95, 145 ],
        color         => '#60a5fa',
        color_dark    => '#172554',
        color_glow    => '#bae6fd',
        p_rgba        => $PARTICLE_RGBA{ice},
        p_rgba_hi     => $PARTICLE_RGBA{ice_bright},
        levels        => [
            { range => 145, damage => 14, fire_rate => 1.15, slow_factor => 0.50, slow_dur => 2.2 },
            { range => 170, damage => 24, fire_rate => 1.40, slow_factor => 0.42, slow_dur => 2.8 },
            { range => 195, damage => 38, fire_rate => 1.65, slow_factor => 0.34, slow_dur => 3.5 },
        ],
    },
    tesla => {
        id            => 'tesla',
        name          => 'TESLA',
        hotkey        => '4',
        desc          => 'Jagged magenta chain-lightning arcs',
        cost          => 130,
        upgrade_costs => [ 0, 160, 230 ],
        color         => '#e879f9',
        color_dark    => '#3b0764',
        color_glow    => '#f5d0fe',
        p_rgba        => $PARTICLE_RGBA{magenta},
        p_rgba_hi     => $PARTICLE_RGBA{magenta_core},
        levels        => [
            { range => 168, damage => 40, fire_rate => 1.65, chains => 3, jump_range => 130 },
            { range => 192, damage => 66, fire_rate => 2.05, chains => 4, jump_range => 150 },
            { range => 222, damage => 102, fire_rate => 2.55, chains => 5, jump_range => 170 },
        ],
    },
);

# =============================================================================
# 5 Enemy Archetypes
# =============================================================================
our %ENEMIES = (
    swarm => {
        id        => 'swarm',
        name      => 'SWARM',
        shape     => 'diamond',
        hp        => 32,
        speed     => 98,
        bounty    => 12,
        score     => 25,
        core_dmg  => 1,
        radius    => 9,
        color     => '#ff2a6d',
        outline   => '#ff8fb3',
        p_rgba    => $PARTICLE_RGBA{crimson},
        death_pts => 26,
    },
    striker => {
        id        => 'striker',
        name      => 'STRIKER',
        shape     => 'chevron',
        hp        => 76,
        speed     => 80,
        bounty    => 20,
        score     => 50,
        core_dmg  => 2,
        radius    => 12,
        color     => '#fb923c',
        outline   => '#fed7aa',
        p_rgba    => $PARTICLE_RGBA{orange},
        death_pts => 38,
    },
    tank => {
        id        => 'tank',
        name      => 'TANK',
        shape     => 'hexagon',
        hp        => 235,
        speed     => 48,
        bounty    => 42,
        score     => 110,
        core_dmg  => 3,
        radius    => 16,
        color     => '#a855f7',
        outline   => '#e9d5ff',
        p_rgba    => $PARTICLE_RGBA{violet},
        death_pts => 64,
    },
    phantom => {
        id        => 'phantom',
        name      => 'PHANTOM',
        shape     => 'triangle',
        hp        => 64,
        speed     => 134,
        bounty    => 28,
        score     => 75,
        core_dmg  => 2,
        radius    => 11,
        color     => '#22c55e',
        outline   => '#bbf7d0',
        p_rgba    => $PARTICLE_RGBA{green},
        death_pts => 40,
    },
    boss => {
        id        => 'boss',
        name      => 'DREADNOUGHT',
        shape     => 'boss',
        hp        => 1350,
        speed     => 36,
        bounty    => 220,
        score     => 750,
        core_dmg  => 10,
        radius    => 24,
        color     => '#f43f5e',
        outline   => '#fde047',
        p_rgba    => $PARTICLE_RGBA{crimson},
        death_pts => 320,
    },
);

# =============================================================================
# 10 Escalating Waves + Endless Wave Generator
# Each wave is an arrayref of spawn groups: { type, count, interval, delay }
# =============================================================================
our @WAVES = (
    # Wave 1: Fast Swarm opener
    [
        { type => 'swarm',   count => 12, interval => 0.30, delay => 0.0 },
        { type => 'striker', count =>  3, interval => 0.65, delay => 1.8 },
    ],
    # Wave 2: Swarm + Strikers
    [
        { type => 'swarm',   count => 14, interval => 0.28, delay => 0.0 },
        { type => 'striker', count =>  6, interval => 0.55, delay => 1.2 },
    ],
    # Wave 3: Enter the Tanks
    [
        { type => 'striker', count =>  8, interval => 0.50, delay => 0.0 },
        { type => 'tank',    count =>  4, interval => 1.10, delay => 1.0 },
        { type => 'swarm',   count => 10, interval => 0.25, delay => 3.0 },
    ],
    # Wave 4: Phantom Blitz
    [
        { type => 'phantom', count => 10, interval => 0.38, delay => 0.0 },
        { type => 'striker', count =>  8, interval => 0.45, delay => 1.5 },
        { type => 'tank',    count =>  3, interval => 1.00, delay => 2.5 },
    ],
    # Wave 5: BOSS WAVE #1
    [
        { type => 'swarm',   count => 12, interval => 0.22, delay => 0.0 },
        { type => 'boss',    count =>  1, interval => 1.00, delay => 1.2 },
        { type => 'tank',    count =>  4, interval => 0.90, delay => 2.0 },
        { type => 'phantom', count =>  8, interval => 0.35, delay => 3.5 },
    ],
    # Wave 6: Heavy Assault
    [
        { type => 'tank',    count =>  7, interval => 0.80, delay => 0.0 },
        { type => 'striker', count => 12, interval => 0.36, delay => 0.8 },
        { type => 'phantom', count => 10, interval => 0.32, delay => 2.4 },
    ],
    # Wave 7: Swarm Tide
    [
        { type => 'swarm',   count => 32, interval => 0.16, delay => 0.0 },
        { type => 'phantom', count => 14, interval => 0.28, delay => 1.6 },
        { type => 'tank',    count =>  6, interval => 0.75, delay => 2.8 },
    ],
    # Wave 8: Armored Vanguard
    [
        { type => 'tank',    count => 10, interval => 0.65, delay => 0.0 },
        { type => 'striker', count => 16, interval => 0.30, delay => 0.8 },
        { type => 'phantom', count => 12, interval => 0.26, delay => 2.2 },
    ],
    # Wave 9: Cyber Storm
    [
        { type => 'phantom', count => 18, interval => 0.22, delay => 0.0 },
        { type => 'swarm',   count => 26, interval => 0.14, delay => 0.6 },
        { type => 'tank',    count => 10, interval => 0.60, delay => 1.8 },
    ],
    # Wave 10: DOUBLE DREADNOUGHT FINALE
    [
        { type => 'boss',    count =>  1, interval => 1.00, delay => 0.0 },
        { type => 'tank',    count =>  8, interval => 0.65, delay => 0.8 },
        { type => 'phantom', count => 14, interval => 0.24, delay => 1.6 },
        { type => 'boss',    count =>  1, interval => 1.00, delay => 3.6 },
        { type => 'swarm',   count => 24, interval => 0.15, delay => 4.2 },
    ],
);

# Return (spawn_groups_aref, hp_scale) for wave_num (1-based; >= 11 is Endless Mode)
sub get_wave_spec {
    my ($wave_num) = @_;
    $wave_num = 1 if !defined($wave_num) || $wave_num < 1;

    if ($wave_num <= scalar(@WAVES)) {
        my $hp_scale = 1.0 + ($wave_num - 1) * 0.14;
        return ($WAVES[$wave_num - 1], $hp_scale);
    }

    # Endless Mode (Wave 11+)
    my $extra    = $wave_num - scalar(@WAVES);
    my $hp_scale = (1.0 + 9 * 0.14) * (1.22 ** $extra);
    my @groups   = (
        { type => 'swarm',   count => 18 + $extra * 3, interval => 0.15, delay => 0.0 },
        { type => 'striker', count => 10 + $extra * 2, interval => 0.28, delay => 0.6 },
        { type => 'tank',    count =>  6 + $extra,     interval => 0.55, delay => 1.4 },
        { type => 'phantom', count => 12 + $extra * 2, interval => 0.22, delay => 2.2 },
    );
    if ($wave_num % 5 == 0) {
        my $boss_count = 1 + int($extra / 5);
        push @groups, { type => 'boss', count => $boss_count, interval => 2.5, delay => 1.0 };
    }
    return (\@groups, $hp_scale);
}

# Predefined build order for Auto-Play
our @AI_BUILD_PLAN = (
    # Spawn choke
    { col =>  1, row => 1, type => 'pulse' },
    { col =>  2, row => 1, type => 'rail'  },
    { col =>  2, row => 3, type => 'pulse' },
    { col =>  4, row => 3, type => 'frost' },
    # Left bend
    { col =>  5, row => 5, type => 'tesla' },
    { col =>  4, row => 6, type => 'pulse' },
    { col =>  6, row => 4, type => 'rail'  },
    { col =>  5, row => 3, type => 'frost' },
    # Center bend
    { col =>  8, row => 3, type => 'tesla' },
    { col =>  9, row => 5, type => 'rail'  },
    { col =>  8, row => 6, type => 'frost' },
    { col => 10, row => 4, type => 'pulse' },
    # Right flank & Bastion Core defense
    { col => 10, row => 6, type => 'tesla' },
    { col => 12, row => 5, type => 'rail'  },
    { col => 13, row => 6, type => 'pulse' },
    { col => 12, row => 3, type => 'frost' },
    { col =>  6, row => 6, type => 'tesla' },
    { col =>  9, row => 3, type => 'pulse' },
    { col => 13, row => 8, type => 'rail'  },
    { col =>  4, row => 1, type => 'tesla' },
);

1;

__END__

=head1 NAME

NeonBastion::Config - Arena geometry, tower/enemy tables, waves, and palette for NEON BASTION

=head1 DESCRIPTION

Holds static configuration tables and path geometry helpers for NEON BASTION:
the 16x10 tile grid, S-curve waypoints, tower and enemy definitions, wave
schedules, and Auto-Play placement order.

=cut
