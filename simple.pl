use warnings;
use strict;
use Stack::Unwind 'unwind';
use feature 'say';

mark TOPLEVEL: {
    eval {
        unwind TOPLEVEL:;
        die;
        say "after die";
    };
    say "last in mark";
};
say "after mark";
