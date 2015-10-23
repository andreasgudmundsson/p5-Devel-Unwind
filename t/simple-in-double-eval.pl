use warnings;
use strict;
use Stack::Unwind;
use feature 'say';

say "Want:\n123456789\nabcdefghi\n\n";
eval {
    mark TOPLEVEL: {
        eval {
            eval {
                # This shouldn't die
                # if it can't find the label.
                # How do we handle that error?
                # exit?
                unwind ASDTOPLEVEL21:;
                die;
                say "A";
            } or do {
                say "whut: $@";
            };
            say "B";
        };
    };
    print for 1..9;
    print "\n";
};

say join("",'a'..'i');
eval {
    mark TOPLEVEL2: {
        eval {
            eval {
                unwind TOPLEVEL2:;
                die;
                say "a";
            };
            say "b";
        };
    };
    say "got here";
};
say "again";
