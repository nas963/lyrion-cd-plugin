package Plugins::AudioCD::Url;

# URL omota diska: jedno mesto za Menu, State, ProtocolHandler i Web (bez LMS-a, pa se moze ucitati svuda).
# "cd." ispred discid-a drzi putanju van LMS-ovog resizera (vidi komentar u Web.pm).

use strict;
use warnings;
use utf8;

# plugins/AudioCD/cover/cd.<discid>.jpg (relativan, kako ga trazi Material)
sub cover_url { my ($discid) = @_; return "plugins/AudioCD/cover/cd.$discid.jpg" }

1;
