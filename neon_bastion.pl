#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Spec;
use Getopt::Long qw(GetOptions);
use Time::HiRes  qw(time);

BEGIN {
    my $root = File::Spec->rel2abs($FindBin::Bin);
    # Local NeonBastion modules (prefer built blib for NeonBastion::SimXS)
    my @local_inc = (
        File::Spec->catdir($root, 'blib', 'lib'),
        File::Spec->catdir($root, 'blib', 'arch'),
        File::Spec->catdir($root, 'lib'),
    );
    unshift @INC, grep { -d $_ } @local_inc;

    # Resolve Tcl::Tk::MT from @INC first; fall back to $ENV{TCL_TK_MT_DIR}
    # or side-by-side ../tcl-tk-mt checkout
    if (!$ENV{TCL_TK_MT_NO_REPO_BLIB}) {
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
}

use NeonBastion::Config ();
use NeonBastion::Sim ();
use NeonBastion::Renderer ();

my $opt_headless     = 0;
my $opt_demo         = 0;
my $opt_frames       = 120;
my $opt_json         = 0;
my $opt_snapshot     = '';
my $opt_backend      = '';
my $opt_auto_exit_ms = 0;
my $opt_help         = 0;

GetOptions(
    'headless!'      => \$opt_headless,
    'demo!'          => \$opt_demo,
    'frames=i'       => \$opt_frames,
    'json!'          => \$opt_json,
    'snapshot=s'     => \$opt_snapshot,
    'backend=s'      => \$opt_backend,
    'auto-exit-ms=i' => \$opt_auto_exit_ms,
    'help|h!'        => \$opt_help,
) or die "Run with --help for usage.\n";

if ($opt_help) {
    print <<'USAGE';
NEON BASTION - Tower Defense Demo for perl5-mt + Tcl::Tk::MT

Usage:
  perl neon_bastion.pl [options]

Options:
  --demo                 Enable hands-free Auto-Play AI
  --headless             Run offscreen simulation & GPU render benchmark
  --frames=N             Number of fixed-dt frames in headless mode (default: 120)
  --json                 Output structured JSON metrics in headless mode
  --snapshot=PATH        Write final frame as binary PPM (P6) in headless mode
  --backend=NAME         Override gfx backend (auto|metal|vulkan|software)
  --auto-exit-ms=N       Auto-close interactive GUI after N ms (smoke testing)
  --help                 Show this help message
USAGE
    exit 0;
}

sub resolve_backend {
    my ($explicit) = @_;
    require Tcl::Tk::MT::Gfx;
    Tcl::Tk::MT::Gfx::init();

    if (defined $explicit && length $explicit && lc($explicit) ne 'auto') {
        return lc($explicit);
    }
    my $env = defined($ENV{TCL_TK_MT_ACCEL}) ? lc($ENV{TCL_TK_MT_ACCEL}) : '';
    if ($env eq 'metal' || $env eq 'vulkan' || $env eq 'software') {
        return $env if eval { Tcl::Tk::MT::Gfx::backend_available($env) };
    }
    return 'metal'  if eval { Tcl::Tk::MT::Gfx::backend_available('metal') };
    return 'vulkan' if eval { Tcl::Tk::MT::Gfx::backend_available('vulkan') };
    return 'software';
}

sub mean {
    my ($vals) = @_;
    return 0.0 unless $vals && @$vals;
    my $s = 0.0;
    $s += $_ for @$vals;
    return $s / scalar(@$vals);
}

sub percentile {
    my ($vals, $p) = @_;
    return 0.0 unless $vals && @$vals;
    my @s = sort { $a <=> $b } @$vals;
    my $n = scalar @s;
    return $s[0] if $n == 1;
    my $idx = ($p / 100.0) * ($n - 1);
    my $lo  = int($idx);
    my $hi  = $lo + 1;
    $hi = $n - 1 if $hi >= $n;
    return $s[$lo] + ($s[$hi] - $s[$lo]) * ($idx - $lo);
}

sub write_ppm {
    my ($path, $rgba, $w, $h) = @_;
    open my $fh, '>', $path or die "Cannot write PPM '$path': $!";
    binmode $fh;
    print {$fh} "P6\n$w $h\n255\n";
    my $n = $w * $h;
    my $rgb = '';
    my $chunk = 4096;
    for (my $i = 0; $i < $n; $i += $chunk) {
        my $cnt = ($i + $chunk <= $n) ? $chunk : ($n - $i);
        my $sub = substr($rgba, $i * 4, $cnt * 4);
        # Strip every 4th byte (alpha)
        $sub =~ s/(...)[\x00-\xFF]/$1/gs;
        print {$fh} $sub;
    }
    close $fh or die "Cannot close PPM '$path': $!";
}

sub count_nonblank_pixels {
    my ($rgba) = @_;
    my $len = length($rgba);
    my $nonblank = 0;
    for (my $off = 0; $off + 3 < $len; $off += 4) {
        my ($r, $g, $b) = unpack('CCC', substr($rgba, $off, 3));
        $nonblank++ if ($r > 12 || $g > 14 || $b > 26);
    }
    return $nonblank;
}

sub json_escape {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    return '"' . $s . '"';
}

sub encode_json_obj {
    my ($h) = @_;
    my @keys = sort keys %$h;
    my @pairs;
    for my $k (@keys) {
        my $v = $h->{$k};
        my $enc;
        if (!defined $v) {
            $enc = 'null';
        }
        elsif ($v =~ /\A-?(?:0|[1-9]\d*)(?:\.\d+)?\z/) {
            $enc = $v;
        }
        else {
            $enc = json_escape("$v");
        }
        push @pairs, sprintf('  %s: %s', json_escape($k), $enc);
    }
    return "{\n" . join(",\n", @pairs) . "\n}\n";
}

my $backend = resolve_backend($opt_backend);

if ($opt_headless) {
    run_headless();
}
else {
    run_interactive();
}
exit 0;

# =============================================================================
# Headless Benchmark / CI Mode
# =============================================================================
sub run_headless {
    require Tcl::Tk::MT::Canvas;

    my $w = $NeonBastion::Config::ARENA_W;
    my $h = $NeonBastion::Config::ARENA_H;

    my $canvas = Tcl::Tk::MT::Canvas->new(undef,
        -width    => $w,
        -height   => $h,
        -bg       => $NeonBastion::Config::THEME{bg_void},
        -backend  => $backend,
        -headless => 1,
    );

    my $sim = NeonBastion::Sim->new(demo => ($opt_demo ? 1 : 0));
    my $ren = NeonBastion::Renderer->new(canvas => $canvas, width => $w, height => $h);

    # Warmup frame (pipeline / texture init)
    $sim->step(1.0 / 60.0);
    $ren->render_frame($sim);

    my $frames = $opt_frames > 0 ? $opt_frames : 1;
    my $dt     = 1.0 / 60.0;
    my (@frame_ms, @sim_ms, @ren_ms);

    my $t_all0 = time();
    for (my $f = 1; $f <= $frames; $f++) {
        my $tf0 = time();
        my $ts0 = time();
        $sim->step($dt);
        my $sm = (time() - $ts0) * 1000.0;

        my $rm = $ren->render_frame($sim);
        my $fm = (time() - $tf0) * 1000.0;

        push @sim_ms,   $sm;
        push @ren_ms,   $rm;
        push @frame_ms, $fm;
    }
    my $total_ms = (time() - $t_all0) * 1000.0;

    my $rgba     = $canvas->readback_rgba();
    my $nonblank = count_nonblank_pixels($rgba);

    if (length $opt_snapshot) {
        write_ppm($opt_snapshot, $rgba, $w, $h);
    }

    my $fps    = $total_ms > 0 ? ($frames / ($total_ms / 1000.0)) : 0.0;
    my $result = {
        game            => 'neon_bastion',
        backend         => $canvas->backend_name(),
        width           => $w,
        height          => $h,
        frames          => $frames,
        demo            => $opt_demo ? 1 : 0,
        fps             => sprintf('%.3f', $fps) + 0,
        total_ms        => sprintf('%.3f', $total_ms) + 0,
        p50_ms          => sprintf('%.3f', percentile(\@frame_ms, 50)) + 0,
        p95_ms          => sprintf('%.3f', percentile(\@frame_ms, 95)) + 0,
        sim_ms          => sprintf('%.3f', mean(\@sim_ms)) + 0,
        render_ms       => sprintf('%.3f', mean(\@ren_ms)) + 0,
        wave            => $sim->{wave} + 0,
        score           => $sim->{score} + 0,
        credits         => $sim->{credits} + 0,
        core_hp         => $sim->{core_hp} + 0,
        towers_built    => $sim->{towers_built} + 0,
        enemies_spawned => $sim->{enemies_spawned} + 0,
        enemies_killed  => $sim->{kills} + 0,
        peak_particles  => $sim->{peak_particles} + 0,
        nonblank_pixels => $nonblank + 0,
        snapshot        => length($opt_snapshot) ? $opt_snapshot : undef,
    };

    if ($opt_json) {
        print encode_json_obj($result);
    }
    else {
        printf "=== NEON BASTION Headless Benchmark ===\n";
        printf "Backend: %s | Frames: %d (%dx%d) | Demo AI: %s\n",
            $result->{backend}, $frames, $w, $h, ($opt_demo ? 'ON' : 'OFF');
        printf "FPS: %.2f | p50: %.2f ms | p95: %.2f ms | sim: %.2f ms | render: %.2f ms\n",
            $result->{fps}, $result->{p50_ms}, $result->{p95_ms}, $result->{sim_ms}, $result->{render_ms};
        printf "Wave: %d | Towers: %d | Spawned: %d | Killed: %d | Peak Particles: %d | NonBlank: %d\n",
            $result->{wave}, $result->{towers_built}, $result->{enemies_spawned},
            $result->{enemies_killed}, $result->{peak_particles}, $result->{nonblank_pixels};
    }
}

# =============================================================================
# Interactive Desktop GUI Mode
# =============================================================================
sub run_interactive {
    require Tcl::Tk::MT;

    my $w = $NeonBastion::Config::ARENA_W;
    my $h = $NeonBastion::Config::ARENA_H;
    my $T = \%NeonBastion::Config::THEME;

    my $mw = Tcl::Tk::MT::MainWindow->new(
        -title => "NEON BASTION [$backend]",
    );
    $mw->configure(-bg => $T->{bg_void});
    eval { $mw->resizable(0, 0) };

    # Dark ttk theme
    if ($mw->can('interp')) {
        eval {
            $mw->interp->Eval(<<'TCL');
catch { ttk::style theme use clam }
ttk::style configure TFrame -background #0d1322
ttk::style configure TLabel -background #0d1322 -foreground #e6f1ff
ttk::style configure TButton -background #131c31 -foreground #e6f1ff -borderwidth 1 -padding {5 3}
ttk::style map TButton -background {active #1c2a46 pressed #243554} -foreground {active #00f0ff}
ttk::style configure Accent.TButton -background #0e3a52 -foreground #00f0ff -borderwidth 1 -padding {6 3}
ttk::style map Accent.TButton -background {active #155e75}
TCL
        };
    }

    # --- Top HUD Bar ---
    my $top = $mw->ttkFrame(-height => 30)
                 ->pack(-side => 'top', -fill => 'x', -padx => 6, -pady => 4);

    $top->ttkLabel(
        -text       => 'NEON BASTION',
        -font       => 'Helvetica 13 bold',
        -foreground => $T->{cyan},
    )->pack(-side => 'left', -padx => 6);

    my $hud_stats_fmt = 'CREDITS:$%6d | CORE:%2d/%-2d | WAVE:%3d%1s | SCORE:%7d | KILLS:%5d | PTS:%5d';
    my $hud_stats = $top->ttkLabel(
        -text       => sprintf($hud_stats_fmt, 250, 25, 25, 0, ' ', 0, 0, 0),
        -width      => 80,
        -anchor     => 'w',
        -font       => 'TkFixedFont',
        -foreground => $T->{text_pri},
    )->pack(-side => 'left', -padx => 6);

    my $is_mt = eval { Tcl::Tk::MT::Gfx::is_perl5_mt() } ? 'perl5-mt' : 'perl5';
    my $hud_perf_fmt = 'FPS:%6.1f | %5.1fms | [%s/%s]';
    my $hud_perf = $top->ttkLabel(
        -text       => sprintf('FPS:  --.- |  --.-ms | [%s/%s]', uc($backend), $is_mt),
        -width      => 44,
        -anchor     => 'e',
        -font       => 'TkFixedFont',
        -foreground => $T->{green},
    )->pack(-side => 'right', -padx => 6);

    # --- Center 960x600 GPU Arena Canvas ---
    my $arena_frame = $mw->Frame(-bg => $T->{border}, -padx => 2, -pady => 2)
                         ->pack(-side => 'top', -padx => 6, -pady => 2);

    my $canvas = $arena_frame->Canvas(
        -width   => $w,
        -height  => $h,
        -bg      => $T->{bg_void},
        -backend => $backend,
    )->pack();

    my $sim = NeonBastion::Sim->new(demo => ($opt_demo ? 1 : 0));
    my $ren = NeonBastion::Renderer->new(canvas => $canvas, width => $w, height => $h);

    # --- Bottom Tower Build & Command Bar ---
    my $bot = $mw->ttkFrame()->pack(-side => 'bottom', -fill => 'x', -padx => 6, -pady => 5);

    my $build_type     = 'pulse';
    my $selected_tower = undef;
    my $status_lbl;
    my ($btn_upgrade, $btn_sell, $btn_speed, $btn_auto);

    my $update_action_labels = sub {
        if ($selected_tower && $sim->tower_at($selected_tower->{col}, $selected_tower->{row})) {
            my $ucost  = $sim->upgrade_cost($selected_tower);
            my $refund = int($selected_tower->{invested} * $NeonBastion::Config::SELL_REFUND + 0.5);
            my $spec   = $NeonBastion::Config::TOWERS{ $selected_tower->{type} };
            $btn_upgrade->configure(-text => defined($ucost) ? sprintf('Upgrade (U) $%d', $ucost) : 'MAX LVL');
            $btn_sell->configure(-text => sprintf('Sell (S) +$%d', $refund));
            $status_lbl->configure(-text => sprintf(
                'Selected: %-12s Lv%d (Kills: %5d)', $spec->{name}, $selected_tower->{level}, $selected_tower->{kills}
            ));
        }
        else {
            $selected_tower = undef;
            $ren->set_selected_tower(undef);
            my $spec = $NeonBastion::Config::TOWERS{$build_type};
            $btn_upgrade->configure(-text => 'Upgrade (U)');
            $btn_sell->configure(-text => 'Sell (S)');
            $status_lbl->configure(-text => sprintf(
                'Build: [%s] %s ($%d) — %s', $spec->{hotkey}, $spec->{name}, $spec->{cost}, $spec->{desc}
            ));
        }
    };

    my $select_build = sub {
        my ($type) = @_;
        $build_type     = $type;
        $selected_tower = undef;
        $ren->set_build_type($type);
        $ren->set_selected_tower(undef);
        $update_action_labels->();
    };

    for my $tid (@NeonBastion::Config::TOWER_ORDER) {
        my $sp = $NeonBastion::Config::TOWERS{$tid};
        $bot->ttkButton(
            -text    => sprintf('[%s] %s $%d', $sp->{hotkey}, $sp->{name}, $sp->{cost}),
            -command => sub { $select_build->($tid) },
        )->pack(-side => 'left', -padx => 3);
    }

    my $do_upgrade = sub {
        return unless $selected_tower;
        $sim->upgrade_tower($selected_tower);
        $update_action_labels->();
    };

    my $do_sell = sub {
        return unless $selected_tower;
        $sim->sell_tower($selected_tower);
        $selected_tower = undef;
        $ren->set_selected_tower(undef);
        $update_action_labels->();
    };

    my $do_next_wave = sub {
        $sim->start_next_wave();
    };

    my $do_toggle_speed = sub {
        my $spd = $sim->toggle_speed();
        $btn_speed->configure(-text => "Speed ${spd}x (F)");
    };

    my $do_toggle_auto = sub {
        $sim->set_auto_play(!$sim->{auto_play});
        $btn_auto->configure(-text => $sim->{auto_play} ? 'Auto-Play: ON (A)' : 'Auto-Play: OFF (A)');
    };

    my $do_restart = sub {
        $sim            = NeonBastion::Sim->new(demo => $sim->{auto_play});
        $selected_tower = undef;
        $ren->set_selected_tower(undef);
        $update_action_labels->();
    };

    $btn_upgrade = $bot->ttkButton(-text => 'Upgrade (U)', -width => 15, -command => $do_upgrade)->pack(-side => 'left', -padx => 3);
    $btn_sell    = $bot->ttkButton(-text => 'Sell (S)',    -width => 13, -command => $do_sell)->pack(-side => 'left', -padx => 2);

    $bot->ttkButton(-text => 'Restart (R)', -command => $do_restart)->pack(-side => 'right', -padx => 2);
    $btn_auto  = $bot->ttkButton(
        -text    => $sim->{auto_play} ? 'Auto-Play: ON (A)' : 'Auto-Play: OFF (A)',
        -width   => 16,
        -command => $do_toggle_auto,
    )->pack(-side => 'right', -padx => 2);
    $btn_speed = $bot->ttkButton(-text => 'Speed 1x (F)', -width => 11, -command => $do_toggle_speed)->pack(-side => 'right', -padx => 2);
    $bot->ttkButton(-text => 'Next Wave (Space)', -style => 'Accent.TButton', -command => $do_next_wave)
        ->pack(-side => 'right', -padx => 3);

    my $stat_bar = $mw->ttkFrame(-width => $w, -height => 22)
                      ->pack(-side => 'bottom', -fill => 'x', -padx => 8, -pady => 2);
    eval { $mw->interp->call('pack', 'propagate', $stat_bar->path, 0) } if $mw->can('interp');
    $status_lbl = $stat_bar->ttkLabel(
        -text       => '',
        -width      => 96,
        -anchor     => 'w',
        -font       => 'TkFixedFont',
        -foreground => $T->{text_sec},
    )->pack(-side => 'left', -fill => 'x', -expand => 1);
    $update_action_labels->();

    # Lock bar and window geometry after initial layout to prevent resize jitter
    if ($mw->can('interp')) {
        eval {
            my $interp = $mw->interp;
            $interp->call('update', 'idletasks');
            for my $bar ($top, $bot, $stat_bar) {
                my $bw = $interp->call('winfo', 'reqwidth',  $bar->path);
                my $bh = $interp->call('winfo', 'reqheight', $bar->path);
                $bar->configure(-width => $bw, -height => $bh);
                $interp->call('pack', 'propagate', $bar->path, 0);
            }
            $interp->call('update', 'idletasks');
            my $mw_w = $interp->call('winfo', 'reqwidth',  $mw->path);
            my $mw_h = $interp->call('winfo', 'reqheight', $mw->path);
            $interp->call('wm', 'geometry', $mw->path, "${mw_w}x${mw_h}");
            $interp->call('wm', 'minsize',  $mw->path, $mw_w, $mw_h);
            $interp->call('wm', 'maxsize',  $mw->path, $mw_w, $mw_h);
        };
    }

    # --- Mouse & Keyboard Bindings ---
    $canvas->bind('<Motion>', [ sub {
        my ($c, $x, $y) = @_;
        my $col = int($x / $NeonBastion::Config::TILE_SIZE);
        my $row = int($y / $NeonBastion::Config::TILE_SIZE);
        $ren->set_hover($col, $row);
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $canvas->bind('<Leave>', sub {
        $ren->set_hover(-1, -1);
    });

    $canvas->bind('<Button-1>', [ sub {
        my ($c, $x, $y) = @_;
        my $col = int($x / $NeonBastion::Config::TILE_SIZE);
        my $row = int($y / $NeonBastion::Config::TILE_SIZE);
        my $existing = $sim->tower_at($col, $row);
        if ($existing) {
            $selected_tower = $existing;
            $ren->set_selected_tower($existing);
            $update_action_labels->();
            return;
        }
        my $built = $sim->build_tower($col, $row, $build_type);
        if ($built) {
            $selected_tower = $built;
            $ren->set_selected_tower($built);
            $update_action_labels->();
        }
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $canvas->bind('<Button-3>', sub {
        $selected_tower = undef;
        $ren->set_selected_tower(undef);
        $update_action_labels->();
    });

    $mw->bind('<Key-1>',      sub { $select_build->('pulse') });
    $mw->bind('<Key-2>',      sub { $select_build->('rail')  });
    $mw->bind('<Key-3>',      sub { $select_build->('frost') });
    $mw->bind('<Key-4>',      sub { $select_build->('tesla') });
    $mw->bind('<Key-u>',      $do_upgrade);
    $mw->bind('<Key-U>',      $do_upgrade);
    $mw->bind('<Key-s>',      $do_sell);
    $mw->bind('<Key-S>',      $do_sell);
    $mw->bind('<Key-space>',  $do_next_wave);
    $mw->bind('<Key-f>',      $do_toggle_speed);
    $mw->bind('<Key-F>',      $do_toggle_speed);
    $mw->bind('<Key-a>',      $do_toggle_auto);
    $mw->bind('<Key-A>',      $do_toggle_auto);
    $mw->bind('<Key-r>',      $do_restart);
    $mw->bind('<Key-R>',      $do_restart);
    $mw->bind('<Key-Escape>', sub {
        $selected_tower = undef;
        $ren->set_selected_tower(undef);
        $update_action_labels->();
    });

    # --- Frame Loop ---
    my $last_t = time();
    my @win_ms;
    my $hud_div = 0;

    my $tick_cb;
    $tick_cb = sub {
        return unless Tcl::Tk::MT::Exists($mw);

        my $now = time();
        my $dt  = $now - $last_t;
        $last_t = $now;
        $dt = 1.0 / 60.0 if $dt <= 0.0 || $dt > 0.1;

        my $tf0 = time();
        $sim->step($dt);
        $ren->render_frame($sim);
        my $fm = (time() - $tf0) * 1000.0;

        push @win_ms, $fm;
        shift @win_ms if @win_ms > 30;

        if (++$hud_div >= 4) {
            $hud_div = 0;
            my $avg = mean(\@win_ms);
            my $fps = $avg > 0 ? (1000.0 / $avg) : 0.0;
            $hud_stats->configure(-text => sprintf(
                $hud_stats_fmt,
                $sim->{credits}, $sim->{core_hp}, $sim->{max_core_hp},
                $sim->{wave}, ($sim->{endless_mode} ? '+' : ' '),
                $sim->{score}, $sim->{kills}, $sim->{p_live}
            ));
            $hud_perf->configure(-text => sprintf(
                $hud_perf_fmt,
                $fps, $avg, uc($canvas->backend_name()), $is_mt
            ));
        }

        $mw->after(16, $tick_cb);
    };

    $mw->after(20, $tick_cb);

    if ($opt_auto_exit_ms > 0) {
        $mw->after($opt_auto_exit_ms, sub {
            eval { $mw->destroy() } if Tcl::Tk::MT::Exists($mw);
        });
    }

    Tcl::Tk::MT::MainLoop($mw);
}
