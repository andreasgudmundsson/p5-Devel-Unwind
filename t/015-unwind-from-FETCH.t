use warnings;
use strict;

use Test::More;
use Stack::Unwind;

sub TIESCALAR { bless [] }
sub FETCH {
    eval { eval {
        unwind LABEL:;
    }};
}

mark LABEL: {
    my $x;
    tie $x, 'main';
    my $y = $x;
    fail "Execution resumed inside mark block";
}
pass "Execution resumed after mark block";
done_testing;
