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
        like($@, qr/'BAR' not found/);
    };
    die "died from foo";
} or do {
    like($@, qr/^died from foo/);;
};
done_testing;
