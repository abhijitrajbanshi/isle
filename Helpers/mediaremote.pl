#!/usr/bin/perl
# Hosts Isle's MediaRemote bridge inside an Apple-signed process.
# Usage: /usr/bin/perl mediaremote.pl /path/to/libIsleMediaRemote.dylib
use strict;
use warnings;
use DynaLoader;

my $library = shift @ARGV or die "usage: mediaremote.pl <dylib>\n";
my $handle = DynaLoader::dl_load_file($library, 0) or die DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($handle, 'isle_main') or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub('main::isle_main', $symbol);
isle_main();
