use strict;
use warnings;

use Test::More;
use Stack::Unwind;

mark FOO: {
    goto BAR;
};
BAR:
mark FOOBAR: {
    unwind FOOBAR:;
    fail "NOK";
};
pass "OK";
done_testing;
