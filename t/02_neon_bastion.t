#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempfile);
use FindBin;
use JSON::PP   qw(decode_json);
use POSIX      ();

my $repo_root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
my $game_pl   = File::Spec->catfile($repo_root, 'neon_bastion.pl');

ok(-f $game_pl, 'neon_bastion.pl exists')
    or BAIL_OUT("Missing $game_pl");

# Preserve caller @INC (e.g. prove -b, perl5-mt/lib)
my @inc_flags = map { "-I$_" } grep { defined && !ref($_) && -d $_ } @INC;

my @cmd = (
    $^X,
    @inc_flags,
    $game_pl,
    '--headless',
    '--demo',
    '--frames=90',
    '--json',
);

my ($ok, $stdout, $stderr, $rc) = run_capture(\@cmd, {});

ok($ok, "neon_bastion.pl --headless --demo --frames=90 --json exited cleanly (rc=$rc)")
    or diag("CMD: @cmd\nSTDERR:\n$stderr\nSTDOUT:\n$stdout");

my $data = eval { decode_json($stdout) };
ok($data && ref($data) eq 'HASH', 'emitted valid JSON')
    or BAIL_OUT("JSON parse error: $@\nSTDOUT:\n$stdout\nSTDERR:\n$stderr");

cmp_ok($data->{frames}          // 0, '==', 90, 'rendered 90 frames');
cmp_ok($data->{towers_built}    // 0, '>',  0,  'towers_built > 0 ('    . ($data->{towers_built}    // 0) . ')');
cmp_ok($data->{enemies_spawned} // 0, '>',  0,  'enemies_spawned > 0 (' . ($data->{enemies_spawned} // 0) . ')');
cmp_ok($data->{enemies_killed}  // 0, '>',  0,  'enemies_killed > 0 ('  . ($data->{enemies_killed}  // 0) . ')');
cmp_ok($data->{peak_particles}  // 0, '>',  0,  'peak_particles > 0 ('  . ($data->{peak_particles}  // 0) . ')');
cmp_ok($data->{nonblank_pixels} // 0, '>',  0,  'nonblank_pixels > 0 (' . ($data->{nonblank_pixels} // 0) . ')');
cmp_ok($data->{fps}             // 0, '>',  0,  'fps > 0 ('             . ($data->{fps}             // 0) . ')');

ok(defined $data->{backend} && length($data->{backend}), 'reported backend (' . ($data->{backend} // '') . ')');
ok(defined $data->{p50_ms}    && $data->{p50_ms}    >= 0, 'reported p50_ms');
ok(defined $data->{p95_ms}    && $data->{p95_ms}    >= 0, 'reported p95_ms');
ok(defined $data->{sim_ms}    && $data->{sim_ms}    >= 0, 'reported sim_ms');
ok(defined $data->{render_ms} && $data->{render_ms} >= 0, 'reported render_ms');

done_testing();

sub run_capture {
    my ($cmd_ref, $env_ref) = @_;

    my ($err_fh, $err_file) = tempfile(UNLINK => 1);
    close $err_fh;

    my %saved_env;
    for my $k (keys %$env_ref) {
        $saved_env{$k} = exists $ENV{$k} ? $ENV{$k} : undef;
        $ENV{$k} = $env_ref->{$k};
    }

    my $pid = open(my $out_fh, '-|');
    if (!defined $pid) {
        restore_env(\%saved_env);
        return (0, '', "fork failed: $!", -1);
    }

    if ($pid == 0) {
        open STDERR, '>', $err_file or POSIX::_exit(126);
        { exec(@$cmd_ref); }
        print STDERR "exec failed for $cmd_ref->[0]: $!\n";
        POSIX::_exit(127);
    }

    local $/;
    my $stdout = <$out_fh>;
    $stdout = '' unless defined $stdout;
    close $out_fh;
    my $status = $?;

    restore_env(\%saved_env);

    my $stderr = '';
    if (open my $rfh, '<', $err_file) {
        $stderr = <$rfh>;
        $stderr = '' unless defined $stderr;
        close $rfh;
    }

    my $rc = ($status == -1) ? -1 : ($status >> 8);
    return ($status == 0 ? 1 : 0, $stdout, $stderr, $rc);
}

sub restore_env {
    my ($saved) = @_;
    for my $k (keys %$saved) {
        if (defined $saved->{$k}) {
            $ENV{$k} = $saved->{$k};
        } else {
            delete $ENV{$k};
        }
    }
}
