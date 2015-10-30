use strict;
use warnings;

use Test::More;
use Stack::Unwind;

mark FOO: {
    return;
}
mark FOOBAR: {
    unwind FOOBAR:;
    fail "Execution resumed inside mark FOOBAR: after unwind";
}
pass "Execution resumed after mark";
done_testing;
