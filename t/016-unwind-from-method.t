{
    package Foo;
    use Test::More;
    use Stack::Unwind;

    sub bar {
        unwind TOPLEVEL:;
        fail "Execution resumed inside mark";
    }
}

use warnings;
use strict;

use Test::More;
use Stack::Unwind;


mark TOPLEVEL: {
    (bless [], "Foo")->bar;
    fail "Execution resumed inside mark";
}
pass "Execution resumed after mark";
done_testing;
