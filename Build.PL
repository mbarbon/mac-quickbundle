#!/usr/bin/perl -w

use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
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
