use strict;
use warnings;
use utf8;
use Test::More;

ok $] >= 5.038, "Perl >= 5.38 (je $])";
for my $module (qw(JSON::PP Digest::SHA MIME::Base64 Encode POSIX)) {
	ok eval "require $module; 1", "$module se ucitava" or diag $@;
}
done_testing;
