package Warezomatic;
use strict;
use warnings;
use YAML;
use File::Basename qw( basename dirname );
use Warez::Identify;
use File::Find::Rule;
use LWP::Simple;
use base qw( Class::Accessor );

sub config {
    my $self = shift;
    return $self->{config} ||= YAML::LoadFile( "$ENV{HOME}/.wm.conf" );
}

sub shows {
    my $self = shift;

    my @shows = map {
        my $conf = "$_/wm.conf";
        my $data = -e $conf ? YAML::LoadFile( $conf ) : {};
        +{
            path => $_,
            show => lc basename( $_ ),
            %$data
        };
    } find directory => mindepth => 1, maxdepth => 1, in => $self->config->{archive};

    my %shows;
    # allow for aliases
    for my $extra (grep { $_->{aka} } @shows) {
        $shows{$_} = $extra for @{ $extra->{aka} };
    }
    # but the directory wins
    $shows{ $_->{show} } = $_ for @shows;
    return %shows;
}

sub command_id {
    my $self = shift;

    for my $file (@_) {
        my $guess = identify $file;
        print Dump { file => $file, guess => $guess };
    }
}

sub command_list {
    my $self = shift;
    my %shows = $self->shows;
    for my $name (sort keys %shows) {
        my $show = $shows{ $name };
        next unless $show->{show} eq $name;
        print $show->{show};
        if ($show->{aka}) {
            print "\t(aka: ", join(', ', @{ $show->{aka} } ), ")"
        }
        print "\n";
    }
    #print Dump \%shows;
}

sub command_store {
    my $self = shift;

    my %shows = $self->shows;
    #print Dump \%shows;

    for my $file (@_) {
        my $episode = identify $file
          or do { print "Couldn't identify $file\n"; next; };
        my $show = $shows{ $episode->{show} }
          or do { print "I don't seem to track $episode->{show}\n"; next; };

        my $name = sprintf( "%s.s%02de%02d%s",
                            $show->{show}, $episode->{season},
                            $episode->{episode}, $episode->{extra} );
        $name =~ s{ }{.}g; # spaces to dots
        $name = sprintf "%s/season_%02d/%s", $show->{path}, $episode->{season}, $name;

        print "$file -> $name\n";

        my $path = dirname $name;
        if (!-d $path) {
            mkdir $path or die "mkdir $path failed: $!";
        }
        rename $file, $name
          or die "rename failed: $!";
        if ($self->config->{queue} && !$ENV{NOLINK}) {
            my $queue = $self->config->{queue} . "/" . basename $name;
            print "$name => $queue\n";
            symlink $name, $queue
              or die "symlink failed: $!:";
        }
    }
}

sub normalise_name {
    my $self = shift;
    my $show = shift or return '';
    return sprintf "%s.s%02de%02d", $show->{show}, $show->{season}, $show->{episode};
}

sub _parse_tpb_rss {
    my $rss = shift;
    my @matches;


    print "parsing as tpb\n" if $ENV{WM_DEBUG};
    for my $link ($rss =~ m{<link>(.*?)</link>}g) {
        my $filename = basename $link;
        push @matches, {
            url      => $link,
            filename => $filename,
        };
    }
    return @matches;
}

sub _parse_tvrss_rss {
    my $rss = shift;
    my @matches;
    
    print "parsing as tvrss\n" if $ENV{WM_DEBUG};
    while ($rss =~ m{<description>(.*?)</description><enclosure url="(.*?)"}g) {
        push @matches, {
            url => $2,
            filename => "$1.torrent",
        };
    }
    return @matches;
}

sub _parse_extratorrent_rss {
    my $rss = shift;
    my @matches;
    
    print "parsing as extratorrent\n" if $ENV{WM_DEBUG};
    while ($rss =~ m{<enclosure url="(.*?)"}g) {
        my $url = $1;
	my $filename = basename $url;
	$filename =~ s{\+}{ }g;
        push @matches, {
            url => $url,
            filename => $filename,
        };
    }
    return @matches;
}

sub _parse_mininova_rss {
    my $rss = shift;
    my @matches;
    
    print "parsing as mininova\n" if $ENV{WM_DEBUG};
    while ($rss =~ m{<title>(.*?)</title>.*?<enclosure url="(.*?)"}g) {
        push @matches, {
            url => $2,
            filename => "$1.torrent",
        };
    }
    return @matches;
}

sub _parse_btchat_rss {
    my $rss = shift;
    my @matches;

    print "parsing as btchat\n" if $ENV{WM_DEBUG};
    while ($rss =~ m{<item>\s+<title>(.*?)</title>.*?<link>(.*?)</link>}gsm) {
        push @matches, {
            url => $2,
            filename => $1,
        };
    }
    return @matches;
}

sub _parse_btjunkie_rss {
    my $rss = shift;
    my @matches;

    print "parsing as btjunkie\n" if $ENV{WM_DEBUG};
    while ($rss =~ m{<item>\s+<title>(.*?)</title>.*?<link>(.*?)</link>}gsm) {
	my $filename = $1;
	my $url = $2;
	$filename =~ s{\s*\[\d+/\d+\]$}{};
	$filename .= '.torrent';
        push @matches, {
            url      => $url,
            filename => $filename,
        };
    }
    return @matches;
}

sub _parse_kickass_rss {
    my $rss = shift;
    my @matches;

    print "parsing as kickass\n" if $ENV{WM_DEBUG};
    while ($rss =~ m{<item>\s+<title>(.*?)</title>.*?<torrentLink>(.*?)</torrentLink>}gsm) {
        push @matches, {
            url => $2,
            filename => $1,
        };
    }
    return @matches;
}

sub _parse_rss {
    my $rss = shift;
    if ($rss =~ m{Mininova}) {
        return _parse_mininova_rss( $rss );
    }
    if ($rss =~ m{<title>tvRSS -}) {
        return _parse_tvrss_rss( $rss );
    }
    if ($rss =~ m{<title>BT-Chat}) {
        return _parse_btchat_rss( $rss );
    }
    if ($rss =~ m{<title>BTJunkie}) {
        return _parse_btjunkie_rss( $rss );
    }
    if ($rss =~ m{ExtraTorrent}) {
        return _parse_extratorrent_rss( $rss );
    }
    if ($rss =~ m{KickassTorrents}i) {
        return _parse_kickass_rss( $rss );
    }
    return _parse_tpb_rss( $rss );
}

sub command_rss {
    my $self = shift;
    my $url = shift;
    my $rss = get $url or die "$url didn't give me nothing\n";
    my @torrents = _parse_rss($rss);
    #die Dump \@torrents;

    my %shows = $self->shows;
    my %i_have = map {
        $self->normalise_name( identify $_ ) => 1
    } find in => [ $self->config->{archive}, $self->config->{download} ];

    for my $parsed ( @torrents ) {
        my $torrent = $parsed->{url};
        my $filename = $parsed->{filename};
        print Dump $parsed if $ENV{WM_DEBUG};
        my $ep = identify $filename or next;
        print Dump $ep if $ENV{WM_DEBUG};
        
        next unless $shows{ $ep->{show} }; # don't watch it
        print "I watch $canon_show!\n"; if $ENV{WM_DEBUG};
        my $canon_show = $shows{ $ep->{show} }{show};
        my $name = $self->normalise_name( { %$ep, show => $canon_show } );

        print " => $name\n" if $ENV{WM_DEBUG};
        next if $i_have{ $name };      # i have it
        print "$name ($filename) from $torrent\n";
        my $path = $self->config->{download} . "/rss/$filename";
        mkdir dirname $path;
        my $rc = mirror $torrent, $path;
        unless (is_success($rc)) {
            print "Error: $rc ", status_message($rc), "\n";
            unlink $path;
        }
    }
}

sub command_help {
    my $self = shift;
    print <<END;
Warezomatic: because being lazy requires effort

Commands:
  id                      guess to what a show is
  list                    list what shows we're watching
  store FILE [FILE...]    put a file away
  rss URL                 smart torrent download

END
}

sub run {
    my $self = shift;
    my $command = shift || 'help';

    my $method = "command_$command";

    unless ($self->can($method)) {
        print "$0: unknown command $command\n";
        $self->command_help;
        exit 1;
    }
    $self->$method( @_ );
}


1;
