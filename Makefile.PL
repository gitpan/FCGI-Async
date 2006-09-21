use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'FCGI::Async',
    AUTHOR              => 'Paul Evans <leonerd@leonerd.org.uk>',
    VERSION_FROM        => 'lib/FCGI/Async.pm',
    ABSTRACT_FROM       => 'lib/FCGI/Async.pm',
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'FCGI-Async-*' },
);

