use Stack::Unwind;
use feature 'say';
use Time::HiRes qw(alarm sleep);

$SIG{ALRM} = sub {
    say 'unwinding';
    unwind FOO:;
    die;
};

mark FOO: {
    eval {
        alarm 0.2;
        sleep 0.5;
        say "in FOO: eval";
    } or do {
        say "in FOO: or do";
    };
    say "last in FOO: mark";
};
say "after mark";
