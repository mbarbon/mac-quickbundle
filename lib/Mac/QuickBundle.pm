package Mac::QuickBundle;

=head1 NAME

Mac::QuickBundle - build Mac OS X bundles for Perl scripts

=cut

use strict;
use warnings;

use Exporter 'import';

our $VERSION = '0.01';
our @EXPORT_OK = qw(scan_dependencies_from_section copy_scripts
                    scan_dependencies load_dependencies merge_dependencies
                    find_shared_dependencies find_all_shared_dependencies
                    scan_dependencies_from_config copy_libraries
                    fix_libraries create_bundle create_pkginfo
                    create_info_plist build_perlwrapper build_application);

=head1 SYNOPSIS

Either use F<quickbundle.pl>, or

    my $cfg = Config::IniFiles->new( -file => 'file.ini' );

    build_application( $cfg );

See L</CONFIGURATION> for a description of the configuration file.

    [application]
    name=MyFilms
    dependencies=myfilms_dependencies
    main=bin/myfilms

    [myfilms_dependencies]
    scandeps=myfilms_scandeps

    [myfilms_scandeps]
    script=bin/myfilms
    inc=lib
    cache=myfilms.cache

=cut

our $INFO_PLIST = <<EOT;
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>English</string>
        <key>CFBundleExecutable</key>
        <string>MyFilms</string>
        <key>CFBundleIconFile</key>
        <string>MyFilms.icns</string>
        <key>CFBundleIdentifier</key>
        <string>org.mbarbon.MyFilms</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleSignature</key>
        <string>????</string>
        <key>CFBundleVersion</key>
        <string>1.02</string>
        <key>CSResourcesFileMapped</key>
        <true/>
</dict>
</plist>
EOT

sub _find_in_inc {
    my( $file, $inc ) = @_;

    for my $path ( @$inc ) {
        return $file if $file =~ s{^$path(?:/)?}{};
    }

    die "Can't find '$file' in \@INC: @$inc"
}

sub scan_dependencies {
    my( $scripts, $scandeps, $inc ) = @_;

    require Module::ScanDeps;

    local @Module::ScanDeps::IncludeLibs = @$inc;
    my $deps = Module::ScanDeps::scan_deps( %$scandeps );

    my( %inchash, %dl_shared_objects );
    foreach my $file ( values %$deps ) {
        next if grep $file->{file} eq $_, @$scripts;

        my $dest;
        if( $file->{type} eq 'shared' ) {
            $dl_shared_objects{$file->{key}} = $file->{file};
        } else {
            $inchash{$file->{key}} = $file->{file};
        }
    }

    return ( { %inchash }, { %dl_shared_objects } );
}

sub load_dependencies {
    my( $dump ) = @_;
    our( %inchash, @incarray, @dl_shared_objects );
    local( %inchash, @incarray, @dl_shared_objects );

    do $dump;

    my %dl_shared_objects;
    foreach my $file ( @dl_shared_objects ) {
        my $key = _find_in_inc( $file, \@incarray );

        $dl_shared_objects{$key} = $file;
    }

    my %files;
    foreach my $key ( keys %inchash ) {
        if( $key =~ m{^/} ) {
            my $k = _find_in_inc( $key, \@incarray );

            $files{$k} = $inchash{$key};
        } else {
            $files{$key} = $inchash{$key};
        }
    }

    return ( \%files, \%dl_shared_objects );
}

sub merge_dependencies {
    my( %files, %shared );
    while( @_ ) {
        my( $files, $shared ) = splice @_, 0, 2;

        %files = ( %files, %$files );
        %shared = ( %shared, %$shared );
    }

    return \%files, \%shared;
}

sub find_shared_dependencies {
    my( $bundle ) = @_;
    my @lines = readpipe( "otool -L '$bundle'" );
    my @libs;

    for( my $i = 1; $i <= $#lines; ++$i ) {
        ( my $line = $lines[$i] ) =~ s{^\s+}{};

        next if $line =~ m{^(?:/System/|^/usr/lib/)};
        next unless $line =~ m{^(.*?)\s+\(};

        push @libs, $1;
    }

    return @libs;
}

sub find_all_shared_dependencies {
    my( $libs ) = @_;
    my %libs;

    foreach my $bundle ( values %$libs ) {
        my @libs = find_shared_dependencies( $bundle );

        @libs{@libs} = @libs;
    }

    return [ keys %libs ];
}

sub _make_absolute($$) {
    my( $path, $base ) = @_;

    require File::Spec;

    return $path if File::Spec->file_name_is_absolute( $path );
    return File::Spec->rel2abs( $path, $base );
}

sub scan_dependencies_from_section {
    my( $cfg, $base_path, $deps_section ) = @_;

    my @dumps = $cfg->val( $deps_section, 'dump' );
    my @scandeps_sections = $cfg->val( $deps_section, 'scandeps' );
    my @deps;

    for my $dump ( @dumps ) {
        push @deps, load_dependencies( _make_absolute( $dump, $base_path ) );
    }

    for my $scandeps ( @scandeps_sections ) {
        my $cache_file = _make_absolute( $cfg->val( $scandeps, 'cache' ), $base_path );
        my @scripts = map _make_absolute( $_, $base_path ),
                          $cfg->val( $scandeps, 'script' );
        my %args = ( files      => \@scripts,
                     cache_file => $cache_file,
                     recurse    => 1,
                     );
        my @inc = map _make_absolute( $_, $base_path ),
                      $cfg->val( $scandeps, 'inc' );

        push @deps, scan_dependencies( \@scripts, \%args, \@inc );
    }

    return @deps;
}

sub scan_dependencies_from_config {
    my( $cfg, $base_path ) = @_;
    my @deps_sections = $cfg->val( 'application', 'dependencies' );
    my @deps = map scan_dependencies_from_section( $cfg, $base_path, $_ ),
                   @deps_sections;

    return merge_dependencies( @deps );
}

sub copy_libraries {
    my( $bundle_dir, $modules, $shared, $libs ) = @_;

    require File::Path;
    require File::Copy;

    foreach my $key ( keys %$modules ) {
        my $dest = "$bundle_dir/Contents/Resources/Perl-Libraries/$key";

        File::Path::mkpath( File::Basename::dirname( $dest ) );
        File::Copy::copy( $modules->{$key}, $dest );
    }

    foreach my $key ( keys %$shared ) {
        my $dest = "$bundle_dir/Contents/Resources/Perl-Libraries/$key";

        File::Path::mkpath( File::Basename::dirname( $dest ) );
        File::Copy::copy( $shared->{$key}, $dest );
    }

    foreach my $lib ( @$libs ) {
        my $libfile = File::Basename::basename( $lib );

        File::Copy::copy( $lib, "$bundle_dir/Contents/Resources/Libraries/$libfile" );
    }
}

sub create_bundle {
    my( $bundle_dir ) = @_;

    require File::Path;

    File::Path::mkpath( "$bundle_dir/Contents/MacOS" );
    File::Path::mkpath( "$bundle_dir/Contents/Resources" );
    File::Path::mkpath( "$bundle_dir/Contents/Resources/Libraries" );
    File::Path::mkpath( "$bundle_dir/Contents/Resources/Perl-Libraries" );
    File::Path::mkpath( "$bundle_dir/Contents/Resources/Perl-Source" );
}

sub create_pkginfo {
    my( $bundle_dir ) = @_;

    require File::Slurp;

    File::Slurp::write_file( "$bundle_dir/Contents/PkgInfo", 'APPL????' );
}

sub create_info_plist {
    my( $bundle_dir ) = @_;

    require File::Slurp;

    File::Slurp::write_file( "$bundle_dir/Contents/Info.plist", $INFO_PLIST );
}

sub create_icon {
    my( $bundle_dir, $icon, $icon_name ) = @_;

    require File::Copy;

    File::Copy::copy( $icon, "$bundle_dir/Contents/Resources/$icon_name" );
}

sub fix_libraries {
    my( $perlwrapper, $bundle_dir ) = @_;

    require Cwd;

    my $dir = Cwd::cwd();
    chdir "$bundle_dir/Contents/Resources/Perl-Source";
    system( "$perlwrapper/Tools/update_dylib_references.pl" );
    chdir $dir;
}

sub build_perlwrapper {
    my( $perlwrapper, $bundle_dir, $executable_name ) = @_;

    require Config;
    require ExtUtils::Embed;
    require File::Copy;

    my $ccopts = ExtUtils::Embed::ccopts();
    my $ldopts = ExtUtils::Embed::ldopts();

    $ccopts =~ s/(?:^|\s)-arch\s+\S+/ /g;
    $ldopts =~ s/(?:^|\s)-arch\s+\S+/ /g;
    $ldopts =~ s/(?:^|\s)-lutil(?=\s|$)/ /g;

    system( join ' ', "$Config::Config{cc} $ccopts",
                      "$perlwrapper/Source/PerlInterpreter.c",
                      "$perlwrapper/Source/main.c -I'$perlwrapper/Source'",
                      "-Wall -o $bundle_dir/Contents/MacOS/$executable_name",
                      "-framework CoreFoundation -framework CoreServices",
                      $ldopts
            );
    File::Copy::copy( "$bundle_dir/Contents/MacOS/$executable_name",
                      "$bundle_dir/Contents/MacOS/perl" );
    chmod( 0777, "$bundle_dir/Contents/MacOS/perl" );
}

sub copy_scripts {
    my( $cfg, $base_path, $bundle_dir ) = @_;

    require File::Copy;
    require File::Basename;

    File::Copy::copy( _make_absolute( $cfg->val( 'application', 'main' ),
                                      $base_path ),
                      "$bundle_dir/Contents/Resources/Perl-Source/main.pl" );
    foreach my $script ( $cfg->val( 'application', 'script' ) ) {
        my $name = File::Basename::basename( $script );

        File::Copy::copy( _make_absolute( $script, $base_path ),
                          "$bundle_dir/Contents/Resources/Perl-Source/$name" );
    }
}

sub bundled_perlwrapper {
    my $mydir = $INC{'Mac/QuickBundle.pm'};
    ( my $perlwrapper = $mydir ) =~ s{\.pm$}{/PerlWrapper}i;

    return $perlwrapper;
}

sub build_application {
    my( $cfg ) = @_;

    require Cwd;

    my( $modules, $libs ) = scan_dependencies_from_config( $cfg, Cwd::cwd() );

    my $output = $cfg->val( 'application', 'name' );
    my $version = scalar $cfg->val( 'application', 'version' );
    my $bundle_dir = _make_absolute( "$output.app", Cwd::cwd() );
    my $perlwrapper = $cfg->val( 'application', 'perlwrapper',
                                 bundled_perlwrapper() );
    my $icon = $cfg->val( 'application', 'icon',
                          "$perlwrapper/Resources/PerlWrapperApp.icns" );

    create_bundle( $bundle_dir );
    create_pkginfo( $bundle_dir );
    create_info_plist( $bundle_dir );
    create_icon( $bundle_dir, $icon, $output . '.icns' );
    copy_libraries( $bundle_dir, $modules, $libs,
                    find_all_shared_dependencies( $libs ) );
    copy_scripts( $cfg, Cwd::cwd(), $bundle_dir );
    fix_libraries( $perlwrapper, $bundle_dir );
    build_perlwrapper( $perlwrapper, $bundle_dir, $output );
}

1;

__END__

=head1 CONFIGURATION

=head2 application

Contains some meta-information about the bundle, and pointers to other
sections.

=over 4

=item name

The name of the application bundle.

=item version

Application version.

=item icon

Application icon (in .icns format).

=item main

The file name of the main script, copied to
F<Contents/Resources/Perl-Scripts/main.pl>.

=item script

Additional script files, copied to
F<Contents/Resources/Perl-Scripts/E<lt>scriptnameE<gt>>.

=item dependencies

List of sections containing dependency information, see L</dependencies>.

=item perlwrapper

Path to PerlWrapper sources, defaults to the PerlWrapper bundled with
L<Mac::QuickBundle>.

=back

=head2 dependencies

=over 4

=item dump

B<INTERNAL, DO NOT USE>

List of dump files, in the format used by L<Module::ScanDeps> and
created by L<Module::ScanDeps::DataFeed>.

    perl -MModule::ScanDeps::DataFeed=my.dump <program>

=item scandeps

List of sections containing configuration for L<Module::ScanDeps>, see
L</scandeps>.

=back

=head2 scandeps

=over 4

=item script

Path to the script file.

=item inc

Additional directories to scan.

=item cache

L<Module::ScanDeps> cache file path.

=back

=head1 SEE ALSO

L<Module::ScanDeps>

PerlWrapper (created by Christian Renz):

L<http://svn.scratchcomputing.com/Module-Build-Plugins-MacBundle/trunk>
L<https://github.com/mbarbon/mac-perl-wrapper>

=head1 AUTHOR

Mattia Barbon <mbarbon@cpan.org>

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
