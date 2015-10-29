use strict;
use warnings;

use Test::More;
use Stack::Unwind;

$SIG{__DIE__} = sub {
    unwind FOO:;
};

mark FOO: {
    eval {
        die "from eval";
        fail "Execution resumes in eval";
    } or do {
        fail "Execution resumes in do-block";
    };
    fail "Execution resumes in after eval but inside mark block";
};
pass "Execution resumes after mark block";
done_testing;
