use strict;
use warnings;

use Test::More tests => 1;
use Stack::Unwind;

my $x;
mark LABEL: {
    $x = 'foo';
    unwind LABEL:;
    $x = 'bar';
}
is($x,'foo', 'Variable correctly set after mark block');
