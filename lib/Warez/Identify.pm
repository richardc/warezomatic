package Warez::Identify;
use strict;
use warnings;
use File::Basename qw( basename );
use base qw( Exporter );
our @EXPORT = qw( identify );

sub identify {
    my $path = shift;
    my $file = basename $path;

    my ($show, $ep, $extra) = $file =~ m{^(.*?)(\d{3,}|s\d+\s*ep?\d+|\d+x\d+)(.*)}i
      or return;
    $show =~ s{[_\.]}{ }g; # dots or underscores for spaces is common
    $show =~ s{\s*$}{};    # but also as seperators
    $show =~ s{\s+-$}{};   # trailing hypens are probably delimiters

    $ep =~ m{^(\d+?)(\d\d)$} or $ep =~ m{^s?(\d+)\s*[ex]p?(\d+)}i
      or die "couldn't match $ep as episode";
    my ($season, $episode) = (0+$1, 0+$2);
    return {
        show    => lc $show,
        season  => $season,
        episode => $episode,
        extra   => $extra,
    };
}

1;
