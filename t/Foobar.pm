package Foobar;

use warnings;
use strict;

use Stack::Unwind;

sub unwind {
    unwind FOO:;
    die;
}

1;
