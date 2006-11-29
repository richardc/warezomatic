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
        my $data = eval { YAML::LoadFile( "$_/wm.conf" ) } || {};
        +{
            show => lc basename $_,
            path => $_,
            %$data
        }
    } find directory => mindepth => 1, maxdepth => 1, in => $self->config->{archive};

    my %shows;
    # allow for aliases
    for my $extra (grep { $_->{aka} } values %shows) {
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
    for my $show ($self->shows) {
        print $show->{show};
        if ($show->{aka}) {
            print "\t(aka: ", join(', ', @{ $show->{aka} } ), ")"
        }
        print "\n";
    }
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

        my $name = sprintf( "%s/season_%02d/%s.s%02de%02d%s",
                            $show->{path}, $episode->{season},
                            $show->{show}, $episode->{season},
                            $episode->{episode}, $episode->{extra} );
        print "$file -> $name\n";

        my $path = dirname $name;
        if (!-d $path) {
            mkdir $path or die "mkdir $path failed: $!";
        }
        rename $file, $name
          or die "rename failed: $!";
        if ($self->config->{queue} && !$ENV{NOLINK}) {
            my $queue = $self->config->{queue} . "/" . basename $name;
            print "$path => $queue\n";
            symlink $path, $queue
              or die "symlink failed: $!:";
        }
    }
}

sub normalise_name {
    my $self = shift;
    my $show = shift or return '';
    return sprintf "%s.s%02de%02d", $show->{show}, $show->{season}, $show->{episode};
}

sub command_rss {
    my $self = shift;
    my $url = shift;
    my $rss = get $url or die "$url didn't give me nothing\n";

    my %shows = $self->shows;
    my %i_have = map {
        $self->normalise_name( identify $_ ) => 1
    } find in => [ $self->config->{archive}, $self->config->{download} ];

    for my $torrent ( $rss =~ m{<link>(.*?)</link>}g ) {
        my $show = identify $torrent or next;
        my $normalised = $self->normalise_name( $show );

        next unless $shows{ $show->{show} }; # don't watch it
        next if $i_have{ $normalised };      # i have it
        print "$normalised from $torrent\n";
        my $path = $self->config->{download} . "/rss/" . basename $torrent;
        mkdir dirname $path;
        mirror $torrent, $path or unlink $path;
    }
}


sub command_help {
    my $self = shift;
    print <<END;
Warezomatic: because being lazy requires effort

Commands:
  id                  guess to what a show is
  list                list what shows we're watching

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
