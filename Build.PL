#!/usr/bin/perl -w

use strict;
use warnings;

use Module::Build;

my $CODE = <<'EOT';
sub ACTION_build {
    my( $self ) = @_;

    $self->SUPER::ACTION_build;

    my $pw_src = 'PerlWrapper';
    my $pw_dst = 'blib/lib/Mac/QuickBundle/PerlWrapper';

    for my $file ( qw(Source/PerlInterpreter.c Source/PerlInterpreter.h
                      Source/main.c Tools/update_dylib_references.pl) ) {
        $self->copy_if_modified( from => "$pw_src/$file",
                                 to   => "$pw_dst/$file" );
    }
}
EOT

my $class = Module::Build->subclass
  ( class           => 'My::Build',
    code            => $CODE,
    );

my $build = $class->new
  ( module_name     => 'Mac::QuickBundle',
    license         => 'perl',
    requires =>
        { 'Config::IniFiles'     => 0,
          'Module::ScanDeps'     => 0,
          'File::Slurp'          => 0,
          'Module::Build'        => 0.28,
           },
    meta_merge =>
        { resources => { 'license'       => 'http://dev.perl.org/licenses/',
                         'repository'    => 'http://github.com/mbarbon/mac-quickbundle',
                         },
          },
    );
$build->create_build_script;
