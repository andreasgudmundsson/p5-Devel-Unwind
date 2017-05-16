use warnings;
use strict;

use Test::More;
use Devel::Unwind;

$SIG{__DIE__} = sub {};

alarm 1;

mark HI {
    local $SIG{ALRM} = sub {
        my $x = "adsfasdf";
        # Localizing the DIE handler used to result in crash due to a
        # buggy hack to avoid infinite recursion when unwinding from
        # within a DIE handler.
        #
        # We "fix" that and avoid other issues by not invoking the DIE handler
        # on 'unwind'
        local $SIG{__DIE__};
        unwind HI "from unwind 1";
    };
    sleep 2;
};

mark HI {
    eval {
        local $SIG{__DIE__};
        unwind HI "from unwind 2";
    };
};

pass "didn't crash";
done_testing;
