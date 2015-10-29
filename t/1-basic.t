use strict;
use warnings;

use Test::More tests => 1;
use Stack::Unwind;


my $x = 'foo';
mark LABEL: {
    unwind LABEL:;
    die;
    $x = 'bar';
}
is($x,'foo', 'Variable correctly set after mark block');
