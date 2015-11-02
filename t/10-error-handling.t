use warnings;
use strict;

use Test::More;
use Stack::Unwind;

# I'm not sure how to handle
# errors here so this test just
# fails for now

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
