use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'ZConf',
    AUTHOR              => 'Zane C. Bowers <vvelox@vvelox.net>',
    VERSION_FROM        => 'lib/ZConf.pm',
    ABSTRACT_FROM       => 'lib/ZConf.pm',
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
        'Net::LDAP' => 1,
        'Net::LDAP::Express' => 1,
        'Net::LDAP::LDAPhash' => 1,
        'Net::LDAP::Makepath' => 1,
        'File::Path' => 1,
        'File::BaseDir' => 1,
        'Chooser' => 1,
        'ZML' => 1
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'ZConf-*' },
);
