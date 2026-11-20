use strict;
use warnings;
use Config;
use ExtUtils::MakeMaker;

my $is_win32 = ($^O eq 'MSWin32');
my $cfg_cc   = $Config{cc} || 'cc';
my $is_msvc  = ($is_win32 && $cfg_cc =~ /(?:^|[\\\/])cl(?:\.exe)?$/i) ? 1 : 0;

my $ccflags = $Config{ccflags} || '';
my $libs    = '';

if ($is_msvc) {
    $ccflags .= ' /std:c11 /O2';
} else {
    $ccflags .= ' -std=c11 -O3';
    if (!$is_win32) {
        $ccflags .= ' -pthread';
        $libs = '-lm -lpthread';
    }
}

WriteMakefile(
    NAME          => 'NeonBastion::SimXS',
    VERSION_FROM  => 'lib/NeonBastion/SimXS.pm',
    ABSTRACT      => 'C11 particle and backdrop XS helper for NEON BASTION',
    XS            => { 'SimXS.xs' => 'SimXS.c' },
    OBJECT        => "SimXS\$(OBJ_EXT) c/td_sim\$(OBJ_EXT)",
    PM            => {
        'lib/NeonBastion/SimXS.pm'    => '$(INST_LIBDIR)/SimXS.pm',
        'lib/NeonBastion/Config.pm'   => '$(INST_LIBDIR)/Config.pm',
        'lib/NeonBastion/Sim.pm'      => '$(INST_LIBDIR)/Sim.pm',
        'lib/NeonBastion/Renderer.pm' => '$(INST_LIBDIR)/Renderer.pm',
    },
    PL_FILES      => {},
    EXE_FILES     => ['neon_bastion.pl'],
    INC           => '-I. -Ic',
    DEFINE        => '-DPERL_XS_THREADSAFE=1',
    CCFLAGS       => $ccflags,
    LIBS          => [$libs],
    clean         => { FILES => "SimXS.c SimXS.bs c/td_sim\$(OBJ_EXT)" },
);

sub MY::postamble {
    my $obj_out = $is_msvc ? '/Fo$@' : '-o $@';
    return <<"MAKE_FRAG";
c/td_sim\$(OBJ_EXT) : c/td_sim.c c/td_sim.h c/tkmt_thread.h
\t\$(CCCMD) \$(CCCDLFLAGS) "-I\$(PERL_INC)" \$(PASTHRU_DEFINE) \$(DEFINE) $obj_out c/td_sim.c
MAKE_FRAG
}
