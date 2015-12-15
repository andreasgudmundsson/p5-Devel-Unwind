use strict;
use warnings;

use Test::More tests => 2;
use Stack::Unwind;

my $x;
mark LABEL: {
    unwind LABEL: "value";
} or do {
    is($@, "value");
    $x = 'foo';
};
is($x,'foo', 'Variable correctly set after mark block');
