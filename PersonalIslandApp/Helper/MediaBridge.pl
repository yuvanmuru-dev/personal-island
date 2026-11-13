# Personal Island media bridge loader.
# Written for this personal project; no upstream file copied.
#
# macOS blocks ordinary apps from reading other apps' Now Playing sessions.
# Apple's own /usr/bin/perl may still read them, so Personal Island runs this
# file with that perl to load MediaBridge.dylib, whose code does the work and
# talks to the app over standard input and output. Nothing else happens here.
use strict;
use warnings;
use DynaLoader;

my $bridge = shift @ARGV or die "usage: perl MediaBridge.pl MediaBridge.dylib\n";
($ENV{PERSONAL_ISLAND_MEDIA_BRIDGE} // "") eq "1" or die "not started by Personal Island\n";
DynaLoader::dl_load_file($bridge, 0) or die "could not load the media bridge: " . DynaLoader::dl_error() . "\n";
