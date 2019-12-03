use strict;
use warnings;

use ExtUtils::MakeMaker;
use ExtUtils::CBuilder;
use Getopt::Std;
use Config;

WriteMakefile(
    ABSTRACT_FROM  => 'lib/Devel/HookRequire.pm',
    AUTHOR         => [
        "Brian Fraser (brian.fraser at booking.com)",
    ],
    CONFIGURE_REQUIRES => {
        "File::Spec" => 0,
        "ExtUtils::MakeMaker" => 0,
    },
    DISTNAME  => "Devel-HookRequire",
    EXE_FILES => [],
    LICENSE   => "perl",
    NAME      => "Devel::HookRequire",
    PREREQ_PM => {
        "Carp"          => 0,
        "XSLoader"      => 0,
        "strict"        => 0,
        "warnings"      => 0
    },
    TEST_REQUIRES => {
        "Test::More"      => 0,
        "Test::Exception" => 0,
    },
    VERSION_FROM     => 'lib/Devel/HookRequire.pm',
    test => {
        "TESTS" => "t/*.t"
    }
);



