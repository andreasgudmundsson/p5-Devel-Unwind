use strict;
use warnings;

use Stack::Unwind;
use feature 'say';

mark FOO: {
    eval {
        require "required_unwind.pm";
        say "after require";
        1;
    } or do {
        say "or do";
    };
    say "before mark";
};
say "after mark";
