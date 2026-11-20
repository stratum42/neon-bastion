package NeonBastion::SimXS;

use strict;
use warnings;
use Exporter 'import';
use XSLoader;

our $VERSION = '0.01';

our @EXPORT_OK = qw(
    step_particles
    render_backdrop_rgba8
    is_perl5_mt
    have_packed_av
    av_packed_type
);

XSLoader::load('NeonBastion::SimXS', $VERSION);

1;

__END__

=head1 NAME

NeonBastion::SimXS - C11 particle and backdrop XS helper for NEON BASTION

=head1 DESCRIPTION

Small C<PERL_XS_THREADSAFE> C11 helper used by NEON BASTION for particle
integration and procedural backdrop synthesis. Operates directly on
C<perl5-mt> packed arrays (C<MT::Array::packed('NV', ...)> and C<U8>) when
available, falling back to regular arrays on stock Perl 5. Setting
C<PERL_FORCE_SCALAR=1> selects the single-threaded scalar path for
bit-for-bit parity testing.

=head1 FUNCTIONS

=over 4

=item C<step_particles($px, $py, $vx, $vy, $life, $max_life, $size, $col_start, $col_end, $inst_out, $count, $dt, $drag, $workers = 0)>

Integrates C<$count> SoA particles in place and writes two compacted stride-4
instances (outer halo and inner core: C<[x, y, rgba_u32, radius]>) per
surviving particle into C<$inst_out>, zeroing any unused tail slots. Returns
the number of instances written.

=item C<render_backdrop_rgba8($rgba_out, $w, $h, $grid_cols, $grid_rows, $waypoints_nv, $time_sec = 0.0, $workers = 0)>

Renders the procedural distance-field arena backdrop (grid, path conduit,
spawn portal, and bastion core) into a C<$w * $h * 4> RGBA8888 packed C<U8>
array or writable byte string. Returns 0 on success.

=item C<is_perl5_mt()>, C<have_packed_av()>, C<av_packed_type($aref)>

Runtime feature checks for C<perl5-mt> packed-array support.

=back

=cut
