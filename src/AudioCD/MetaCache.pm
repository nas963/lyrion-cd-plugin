package Plugins::AudioCD::MetaCache;

# JSON kes metapodataka po disc ID-u. Cist Perl, bez Slim zavisnosti.
#   <dir>/<discid>.json         rezultat lookup-a
#   <dir>/<discid>.manual.json  rucna izmena diska (pobedjuje, kandidati ostaju)
#   <dir>/<discid>.jpg          korice (cover_path)

use strict;
use warnings;
use utf8;

use File::Path ();
use JSON::PP ();

sub new {
	my ($class, %a) = @_;
	die "dir je obavezan\n" unless defined $a{dir} && length $a{dir};
	return bless { dir => $a{dir} }, $class;
}

sub valid_id {
	my ($id) = @_;
	return (defined $id && !ref $id && $id =~ /^[A-Za-z0-9._-]{28}\z/) ? 1 : 0;
}

sub _check { my ($id) = @_; die "neispravan disc ID\n" unless valid_id($id); return $id }

sub _read {
	my ($path) = @_;
	return undef unless -f $path;
	open my $fh, '<:raw', $path or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	my $data = eval { JSON::PP->new->utf8->decode($text) };
	return ref $data eq 'HASH' ? $data : undef;
}

sub _write {
	my ($self, $path, $data) = @_;
	File::Path::make_path($self->{dir}, { mode => 0755 }) unless -d $self->{dir};
	my $tmp = "$path.tmp$$";
	open my $fh, '>:raw', $tmp or die "ne mogu da pisem $tmp: $!\n";
	print {$fh} JSON::PP->new->utf8->canonical->encode($data);
	close $fh or die "ne mogu da zatvorim $tmp: $!\n";
	chmod 0644, $tmp;
	rename $tmp, $path or die "rename: $!\n";
	return 1;
}

sub cover_path {
	my ($self, $id) = @_;
	return "$self->{dir}/" . _check($id) . '.jpg';
}

sub put {
	my ($self, $id, $result) = @_;
	_check($id);
	return $self->_write("$self->{dir}/$id.json", $result);
}

sub put_manual {
	my ($self, $id, $disc) = @_;
	_check($id);
	return $self->_write("$self->{dir}/$id.manual.json", $disc);
}

sub get {
	my ($self, $id) = @_;
	return undef unless valid_id($id);
	my $result = _read("$self->{dir}/$id.json");
	my $manual = _read("$self->{dir}/$id.manual.json");
	if ($manual) {
		$result ||= { discid => $id, cddbid => $manual->{cddbid}, candidates => [], selected => 0, cover_urls => [] };
		$result->{disc} = { %$manual, source => 'manual' };
	}
	return $result;
}

1;
