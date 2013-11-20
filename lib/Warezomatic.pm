package Warezomatic;
use strict;
use warnings;
use YAML;
use File::Basename qw( basename dirname );
use Warez::Identify;
use File::Find::Rule;
use LWP::Simple;
use HTML::Entities qw( decode_entities );
use base qw( Class::Accessor );
use 5.10.0; # we use the 5.10 named regex capture stuff

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
            link $name, $queue
              or die "link failed: $!:";
        }
    }
}

sub normalise_name {
    my $self = shift;
    my $show = shift or return '';
    return sprintf "%s.s%02de%02d", $show->{show}, $show->{season}, $show->{episode};
}


# data-driven regex 'parser'.  ugly but many sites emit invalid XML as RSS.
# the extract regex should extract 'filename' and 'url' keys.  If sanitising
# of this is needed it should be in the fixup sub
my @parsers = (
    {
        name => "The Pirate Bay",
        identify => qr{The Pirate Bay},
        extract  => qr{<item>\s+<title><!\[CDATA\[(?<filename>.*?)\]\]></title>\s+<link>(?<url>.*?)</link>}sm,
        fixup    => sub {
            $_->{filename} .= ".torrent";
            $_->{url} = decode_entities($_->{url});
            $_->{url} .= "&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A80";
            $_->{url} .= "&tr=udp%3A%2F%2Ftracker.publicbt.com%3A80";
            $_->{url} .= "&tr=udp%3A%2F%2Ftracker.istole.it%3A6969";
            $_->{url} .= "&tr=udp%3A%2F%2Ftracker.ccc.de%3A80";
            $_->{url} .= "&tr=udp%3A%2F%2Fopen.demonii.com%3A1337";
        },
    },
    {
        name => "TVRSS.net",
        identify => qr{<title>tvRSS -},
        extract  => qr{<description>(?<filename>.*?)</description><enclosure url="(<?url>.*?)"},
        fixup    => sub { $_->{filename} .= ".torrent" },
    },
    {
        name => "Mininova",
        identify => qr{Mininova},
        extract => qr{<title>(?<filename>.*?)</title>.*?<enclosure url="(?<url>.*?)"},
        fixup    => sub { $_->{filename} .= ".torrent" },
    },
    {
        name => "BT-Chat",
        identify => qr{<title>BT-Chat},
        extract => qr{<item>\s+<title>(?<filename>.*?)</title>.*?<link>(?<url>.*?)</link>}sm
    },
    {
        name => "BTJunkie",
        identify => qr{<title>BTJunkie},
        extract =>  qr{<item>\s+<title>(?<filename>.*?)</title>.*?<link>(?<url>.*?)</link>}sm,
        fixup   => sub {
            $_->{filename} =~ s{\s*\[\d+/\d+\]$}{};
            $_->{filename} .= '.torrent';
        },
    },
    {
        name     => "KickassTorrents",
        identify => qr{KickassTorrents}i,
        extract => qr{<item>\s+<title>(?<filename>.*?)</title>.*?<torrentLink>(?<url>.*?)</torrentLink>}sm,
    },
    {
        name => "ExtraTorrent",
        identify => qr{ExtraTorrent},
        extract => qr{<enclosure url="(?<url>.*?)"},
        fixup => sub {
            $_->{filename} = basename $_->{url};
            $_->{filename} =~ s{\+}{ }g;
        },
    },
    {
        name => "yourBittorrent.com",
        identify => qr{<title>yourBittorrent.com},
        extract => qr{<item>\s+<title>(?<filename>.*?)</title>.*?<link>(?<url>.*?)</link>}sm,
        fixup => sub { $_->{filename} .= ".torrent" },
    },
    {
        name => "ShowRSS",
        identify => qr{showrss},
        extract  => qr{<title>(?<filename>.*?)</title><link>(?<url>.*?)</link>},
        fixup    => sub {
            $_->{url} =~ s{(%([0-9a-f][0-9a-f]))}{ chr hex $2 }eig;
            $_->{filename} .= ".torrent";
        },
    },
    {
        name => "EZTV",
        identify => qr{<title>ezRSS},
        extract  => qr{<item>\s+<title>(?<filename>.*?)</title>.*?<link>(?<url>.*?)</link>}sm,
        fixup    => sub { $_->{filename} = basename $_->{url} },
    },
);

sub _parse_rss {
    my $self = shift;
    my $rss = shift;
    my @matches;

    my ($parser) = grep { $rss =~ $_->{identify} } @parsers;
    die "couldn't pick a parser\n" unless $parser;
    print "Parsing as $parser->{name}\n" if $ENV{WM_DEBUG};
    while ($rss =~ m{$parser->{extract}}g) {
        local $_ = {%+};
        $parser->{fixup}->($_) if $parser->{fixup};
        push @matches, $_;
    }
    return @matches;
}

sub command_rss {
    my $self = shift;
    my $url = shift;
    my $rss = get $url or die "$url didn't give me nothing\n";
    my @torrents = $self->_parse_rss($rss);
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
        my $canon_show = $shows{ $ep->{show} }{show};
        my $name = $self->normalise_name( { %$ep, show => $canon_show } );

        print " => $name\n" if $ENV{WM_DEBUG};
        next if $i_have{ $name };      # i have it
        print "$name ($filename) from $torrent\n";
        my $path = $self->config->{download} . "/rss/$filename";
        mkdir dirname $path;
        if ($torrent =~ /^magnet/) {
            # write a magnet torrent
            # https://wiki.archlinux.org/index.php/RTorrent#Saving_magnet_links_as_torrent_files_in_watch_folder

            my $length = length($torrent);
            open my $fh, ">", $path or die "Can't open file '$path': $!";
            print {$fh} "d10:magnet-uri${length}:${torrent}e\n";
        } else {
            # download as url
            my $rc = mirror $torrent, $path;
            unless (is_success($rc)) {
                print "Error: $rc ", status_message($rc), "\n";
                unlink $path;
            }
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
