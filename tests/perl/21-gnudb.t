use strict;
use warnings;
use utf8;
use Test::More;
use File::Basename qw(dirname);
use JSON::PP ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Metadata::GnuDB') }
use Plugins::AudioCD::DiscId ();

my $G   = 'Plugins::AudioCD::Metadata::GnuDB';
my $dir = dirname($0) . '/fixtures';

# Fixture-i (gnudb.gnudb.org, proto 6, UTF-8, snimljeno curl-om):
#   gnudb-query-210.txt  pravi disk sa servera (6a0a1f09): vise tacnih pogodaka
#   gnudb-read.txt       cddb read za pravi disk (Bobby McFerrin / The Story of Jazz)
#   gnudb-read-utf8.txt  cddb read za drugi disk, sa znakom izvan ASCII (UTF-8)
#   gnudb-query-211.txt  netacno poklapanje (izmisljen TOC)
#   gnudb-query-202.txt  nema poklapanja
#   gnudb-query-200.txt  SINTETICKI: GnuDB uvek vraca 210 za jedan pogodak; 200 linija je napisana
#                        rucno po CDDB protokolu ("200 <kategorija> <id> <izvodjac / album>")
sub slurp {
	my ($name) = @_;
	open my $fh, '<:raw', "$dir/$name" or die "$name: $!";
	local $/;
	my $raw = <$fh>;
	utf8::decode($raw);
	return $raw;
}

my $real = do {
	open my $fh, '<:raw', "$dir/real-disc-toc.json" or die $!;
	local $/;
	JSON::PP::decode_json(<$fh>);
};
my $toc = $real->{toc};

# --- URL-ovi ---
my $cddbid = Plugins::AudioCD::DiscId::cddb_id($toc);
is($cddbid, '6a0a1f09', 'cddb id pravog diska');
is(
	$G->can('query_url')->($toc, $cddbid, '1.2.3'),
	'https://gnudb.gnudb.org/~cddb/cddb.cgi?cmd=cddb+query+6a0a1f09+9+150+22063+38162+57206+86997+97725+115508+133129+158574+2593'
		. '&hello=audiocd+lyrion-cd-plugin+AudioCD+1.2.3&proto=6',
	'query_url: ofseti +150, sekunde, hello bez licnih podataka'
);
is(
	$G->can('read_url')->('data', '6a0a1f86', '1.2.3'),
	'https://gnudb.gnudb.org/~cddb/cddb.cgi?cmd=cddb+read+data+6a0a1f86&hello=audiocd+lyrion-cd-plugin+AudioCD+1.2.3&proto=6',
	'read_url'
);

# --- parse_query ---
my $m = $G->can('parse_query')->(slurp('gnudb-query-210.txt'));
is(scalar(@$m), 5, '210: pet pogodaka');
is_deeply($m->[0], { category => 'data', id => '6a0a1f86', title => 'Bobby McFerrin / The Story of Jazz' }, '210: prvi');
is($m->[4]{id}, '620a1e8a', '210: poslednji (terminator . se ne cita)');

$m = $G->can('parse_query')->(slurp('gnudb-query-200.txt'));
is_deeply($m, [ { category => 'data', id => '18018f85', title => 'edad del pavo / Sigue la línea morada' } ], '200: jedan pogodak, UTF-8');

$m = $G->can('parse_query')->(slurp('gnudb-query-211.txt'));
is_deeply($m, [ { category => 'data', id => '17018d88', title => 'Ramaj Eroc / Angels (Thelonious Coltrane Remix)' },
	{ category => 'data', id => '18018f85', title => 'edad del pavo / Sigue la línea morada' } ], '211: lista netacnih');

is_deeply($G->can('parse_query')->(slurp('gnudb-query-202.txt')), [], '202: nema poklapanja');
is_deeply($G->can('parse_query')->(''), [], 'prazan odgovor');
is_deeply($G->can('parse_query')->(undef), [], 'undef odgovor');

# --- parse_read ---
my $d = $G->can('parse_read')->(slurp('gnudb-read.txt'), 9);
is($d->{source}, 'gnudb', 'source');
is($d->{artist}, 'Bobby McFerrin', 'izvodjac iz DTITLE');
is($d->{album}, 'The Story of Jazz', 'album iz DTITLE');
is($d->{year}, 2000, 'DYEAR');
is($d->{cddbid}, '6a0a1f09', 'cddbid iz DISCID');
is($d->{disc_number}, 1, 'disc_number');
is($d->{disc_total}, 1, 'disc_total');
is($d->{compilation}, 0, 'compilation');
is(scalar(@{ $d->{tracks} }), 9, '9 pesama');
is($d->{tracks}[0]{n}, 1, 'n pocinje od 1');
is($d->{tracks}[0]{title}, "Don't Worry Be Happy", 'TTITLE0');
is($d->{tracks}[8]{title}, "'Round Midnight", 'TTITLE8');
is($d->{tracks}[3]{artist}, 'Bobby McFerrin', 'izvodjac pesme = izvodjac diska');
ok(!defined $d->{tracks}[0]{length}, 'length ostaje undef (popunjava Lookup)');

# UTF-8 ostaje ispravan
$d = $G->can('parse_read')->(slurp('gnudb-read-utf8.txt'), 3);
is($d->{album}, 'Sigue la línea morada', 'UTF-8 album');
is($d->{tracks}[1]{title}, 'Sigue la línea morada - electric', 'UTF-8 pesma');
ok(!defined $d->{year}, 'prazan DYEAR -> undef');

# DTITLE bez ' / ' -> izvodjac = album
$d = $G->can('parse_read')->("DTITLE=Samo Naslov\nTTITLE0=A\n", 1);
is($d->{artist}, 'Samo Naslov', 'bez " / ": izvodjac');
is($d->{album}, 'Samo Naslov', 'bez " / ": album');

# nastavljene linije se spajaju; CRLF; nedostajuca pesma
$d = $G->can('parse_read')->(
	"# komentar\r\nDTITLE=Dugacko Ime Izvo\r\nDTITLE=djaca / Dugacak Album\r\nTTITLE0=Prvi del\r\nTTITLE0=a pesme\r\nDYEAR=1999\r\n.\r\n", 2
);
is($d->{artist}, 'Dugacko Ime Izvodjaca', 'DTITLE nastavak');
is($d->{album}, 'Dugacak Album', 'album posle nastavka');
is($d->{tracks}[0]{title}, 'Prvi dela pesme', 'TTITLE nastavak');
is($d->{tracks}[1]{title}, '', 'nedostajuca pesma -> prazan naslov');
is($d->{year}, 1999, 'DYEAR');

done_testing;
