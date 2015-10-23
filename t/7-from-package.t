use strict;
use warnings;

use Test::More;
use Stack::Unwind;

use Foobar;

mark FOO: {
    eval {
        Foobar::unwind();
        fail "Execution resumes after sub call that unwinds inside eval";
    } or do {
        fail "Execution resumes in do block";
    };
    fail "Execution resumes inside mark block";
}
pass "Execution resumes after mark block";
done_testing;
