use strict;
use warnings;

use Test::More;
use Stack::Unwind;

eval {
    mark FOO: {
        die "died in mark";
    }
    fail "Died in toplevel of mark but didn't hit the 'or do' handler";
} or do {
    like($@, qr/^died in mark/);
};
done_testing;
