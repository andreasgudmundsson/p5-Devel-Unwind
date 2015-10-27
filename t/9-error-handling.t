use warnings;
use strict;

use Test::More;
use Stack::Unwind;

mark FOO: {
    eval {
        unwind BAR:;
        1;
    } or do {
        fail "How should we fail? <$@>";
    };
};
fail "You can only fail";
done_testing;
