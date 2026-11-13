use strict;
use warnings;
use utf8;
use Test::More;

binmode(Test::More->builder->$_, ":encoding(UTF-8)") for qw(output failure_output todo_output);

use Plugins::AudioCD::Menu;

my $id = 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-';
my $disc = {
	artist => 'Pink Floyd', album => 'The Wall',
	tracks => [
		{ n => 1, title => 'In the Flesh?', artist => 'Pink Floyd', length => 199 },
		{ n => 2, title => 'The Thin Ice',  artist => undef,        length => 148 },
		{ n => 4, title => 'Another Brick', artist => 'Gilmour',    length => 191 },
	],
};
# pesma 3 je data pesma (enhanced CD) i ne ulazi u meni
my $toc = { tracks => [ { n => 1 }, { n => 2 }, { n => 3, data => 1 }, { n => 4 } ] };

my $ready = { status => 'ready', discid => $id, metadata => $disc, toc => $toc, cover => 1,
	cover_url => "/plugins/AudioCD/cover/cd.$id.jpg", drive_busy => 'none', rip => {}, missing_tools => [] };

my @ran;
my %opts = (
	string  => sub { my ($tok, @a) = @_; return @a ? "$tok(" . join(',', @a) . ')' : $tok },
	profile => 'secure',
	run     => sub { my ($client, $cmd) = @_; push @ran, [@$cmd]; return (1, undef) },
);

sub feed {
	my ($snap, %o) = @_;
	my $res;
	Plugins::AudioCD::Menu::feed('CLIENT', sub { $res = shift }, {}, $snap, { %opts, %o });
	return $res;
}
sub names { return [ map { $_->{name} } @{ $_[0]{items} } ] }

# ---------- nema diska ----------
for my $st ('empty', 'error') {
	my $r = feed({ status => $st, discid => undef, metadata => undef });
	is_deeply names($r), [ 'PLUGIN_AUDIOCD_UI_NO_DISC', 'PLUGIN_AUDIOCD_UI_LOAD_CD' ], "$st: 'Nema diska' + 'Ucitaj CD'";
	is $r->{items}[0]{type}, 'text', "$st: prva stavka je tekst";
}
{
	@ran = ();
	my $r = feed({ status => 'empty' });
	my $load = $r->{items}[1];
	is ref $load->{url}, 'CODE', 'Ucitaj CD je link sa akcijom';
	my $sub;
	$load->{url}->('CLIENT', sub { $sub = shift }, {});
	is_deeply \@ran, [ [ 'audiocd', 'load' ] ], 'Ucitaj CD salje audiocd load';
	is $sub->{items}[0]{type}, 'text', 'odgovor je tekst';
}
is_deeply names(feed({ status => 'reading' })), ['PLUGIN_AUDIOCD_UI_READING'], 'reading: samo poruka o citanju';
is_deeply names(feed(undef)), [ 'PLUGIN_AUDIOCD_UI_NO_DISC', 'PLUGIN_AUDIOCD_UI_LOAD_CD' ], 'bez snapshot-a: kao prazno';

# ---------- ima disk ----------
{
	my $r = feed($ready);
	is $r->{name}, 'PLUGIN_AUDIOCD', 'naslov korena: Audio CD';
	my @it = @{ $r->{items} };
	is scalar(@it), 3, 'disk + rip + izbaci (nema "Pusti sve")';
	my $d = $it[0];
	is $d->{name}, 'Pink Floyd – The Wall', 'disk: Izvodjac - Album';
	is $d->{type}, 'playlist', 'disk je playlist stavka (Material: zaglavlje dobija Play/Add)';
	is $d->{line2}, 'PLUGIN_AUDIOCD_MENU_TRACKS(3)', 'podnaslov: broj pesama';
	is $d->{image}, "plugins/AudioCD/cover/cd.$id.jpg", 'omot diska preko rute plugina';
	is_deeply $d->{itemActions}{play}{command}, [ 'audiocd', 'play' ], 'Play diska ide preko audiocd play (kes)';
	is_deeply $d->{itemActions}{play}{fixedParams}, { track => 1 }, 'Play diska od prve pesme';
	is_deeply $d->{itemActions}{items}{command}, [ 'browselibrary', 'items' ], 'otvaranje diska: browselibrary items';
	is_deeply $d->{itemActions}{items}{fixedParams}, { mode => 'audiocd', item_id => '0' }, 'otvaranje diska: prva stavka korena';
	ok !exists $d->{itemActions}{add}, 'Add je podrazumevani (playlist add svih pesama stavke)';
	ok !exists $d->{url}, 'disk nema url (ne dodaje se kao jedna pesma)';

	my @tr = @{ $d->{items} };
	is scalar(@tr), 3, '3 audio pesme (data pesma se preskace)';
	is_deeply [ map { $_->{url} } @tr ], [ "audiocd://$id/1", "audiocd://$id/2", "audiocd://$id/4" ], 'url pesama audiocd://<discid>/<n>';
	is_deeply [ map { $_->{type} } @tr ], [ ('audio') x 3 ], 'type audio';
	is $tr[0]{name}, '1. In the Flesh?', 'naziv pesme sa rednim brojem';
	is $tr[0]{image}, "plugins/AudioCD/cover/cd.$id.jpg", 'omot pesme';
	is $tr[1]{line2}, 'Pink Floyd', 'izvodjac diska kad pesma nema svog';
	is $tr[2]{line2}, 'Gilmour', 'izvodjac pesme';
	is $tr[0]{secs}, 199, 'trajanje';
	my $pa = $tr[2]{itemActions}{play};
	is_deeply $pa->{command}, [ 'audiocd', 'play' ], 'play pesme ide preko audiocd play (kes)';
	is_deeply $pa->{fixedParams}, { track => 4 }, 'play pesme nosi redni broj';
	is scalar(grep { ref $_->{url} } @it), 2, 'korenske akcije (rip, izbaci) su link-ovi sa akcijom';

	is $it[1]{name}, 'PLUGIN_AUDIOCD_MENU_RIP(PLUGIN_AUDIOCD_UI_PROFILE_SECURE)', 'Ripuj (<profil>)';
	is $it[2]{name}, 'PLUGIN_AUDIOCD_UI_EJECT', 'Izbaci';

	@ran = ();
	my $out;
	$it[1]{url}->('CLIENT', sub { $out = shift }, {});
	is_deeply \@ran, [ [ 'audiocd', 'rip' ] ], 'Ripuj salje audiocd rip';
	is $out->{items}[0]{name}, 'PLUGIN_AUDIOCD_UI_RIP_STARTED', 'poruka o pocetku ripa';
	@ran = ();
	$it[2]{url}->('CLIENT', sub { $out = shift }, {});
	is_deeply \@ran, [ [ 'audiocd', 'eject' ] ], 'Izbaci salje audiocd eject';
	is $out->{items}[0]{name}, 'PLUGIN_AUDIOCD_UI_EJECTING', 'poruka o izbacivanju';
}

# greska akcije se prikazuje kao tekst
{
	my $r = feed($ready, run => sub { return (undef, { error => 'drive_busy' }) });
	my $out;
	$r->{items}[1]{url}->('CLIENT', sub { $out = shift }, {});
	is $out->{items}[0]{name}, 'PLUGIN_AUDIOCD_ERR_DRIVE_BUSY', 'greska -> poruka za kod';
	is $out->{items}[0]{type}, 'text', 'greska je tekst';
}

# stringovi koji ne postoje: greska -> ERR_UNKNOWN, profil -> sama vrednost
{
	my %miss = (string => sub { my ($tok, @a) = @_; return ($tok =~ /ERR_WEIRD|UI_PROFILE_/) ? undef : @a ? "$tok(" . join(",", @a) . ")" : $tok });
	my $r = feed($ready, %miss, run => sub { return (undef, { error => 'weird' }) });
	my $out;
	$r->{items}[1]{url}->('CLIENT', sub { $out = shift }, {});
	is $out->{items}[0]{name}, 'PLUGIN_AUDIOCD_ERR_UNKNOWN', 'nepoznat kod greske -> ERR_UNKNOWN';
	is $r->{items}[1]{name}, "PLUGIN_AUDIOCD_MENU_RIP(secure)", "profil bez stringa: ispisuje se sama vrednost";
}

# bez omota: genericki CD; bez izvodjaca/albuma: nepoznat album
{
	my $r = feed({ %$ready, cover => 0, cover_url => undef, metadata => { tracks => [ { n => 1, title => 'x' } ] }, toc => { tracks => [ { n => 1 } ] } });
	is $r->{items}[0]{image}, 'plugins/AudioCD/cd-generic.png', 'nema omota -> genericki CD';
	is $r->{items}[0]{items}[0]{image}, 'plugins/AudioCD/cd-generic.png', 'pesma: genericki CD';
	is $r->{items}[0]{name}, 'PLUGIN_AUDIOCD_UI_UNTITLED', 'bez metapodataka: nepoznat album';
}

# ---------- cvor za My Music ----------
{
	my $n = Plugins::AudioCD::Menu::node(sub { 'FEED' });
	is $n->{type}, 'link', 'node: link';
	is $n->{id}, 'audiocd', 'node: id';
	is $n->{name}, 'PLUGIN_AUDIOCD', 'node: name';
	is $n->{homeMenuText}, 'PLUGIN_AUDIOCD', 'node: homeMenuText';
	is $n->{icon}, 'plugins/AudioCD/cd-generic.png', 'node: icon';
	is $n->{jiveIcon}, 'plugins/AudioCD/cd-generic.png', 'node: jiveIcon';
	is $n->{weight}, 95, 'node: weight';
	is $n->{feed}->(), 'FEED', 'node: feed';
}

done_testing;
