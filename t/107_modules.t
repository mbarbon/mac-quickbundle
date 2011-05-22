#!/usr/bin/perl -w

use t::lib::QuickBundle::Test tests => 2;
use Capture::Tiny qw(capture);

create_bundle( <<EOI );
[application]
name=ExtraModules
version=0.01
dependencies=basic_dependencies
main=t/bin/foo.pl

[basic_dependencies]
scandeps=basic_scandeps

[basic_scandeps]
script=t/bin/foo.pl
inc=t/inc
modules=<<EOT
Bar
EOT
EOI

ok( -f 't/outdir/ExtraModules.app/Contents/Resources/Perl-Libraries/Foo.pm' );
ok( -f 't/outdir/ExtraModules.app/Contents/Resources/Perl-Libraries/Bar.pm' );
