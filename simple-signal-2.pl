use Stack::Unwind;
use feature 'say';
use Time::HiRes qw(alarm sleep);

$SIG{ALRM} = sub {
    say 'unwinding';
    unwind FOO:;
    die;
};

eval {
    mark FOO: {
        eval { #[A]
            eval {
                alarm 0.2;
                sleep 0.5;
                say "in FOO: eval";
            } or do {
                say "in FOO: or do";
            };
        } or do {
            say "this do block should never be executed"; # [B]
        };
        say "last in FOO: mark";
    };
    say "in last eval";
    die  "from last eval"; # [C]
} or do {
    print "or do $@";
};
say "last thing in program";

# Execution jumps from [C] to [A] I believe this means we need to at least
# pop the context blocks we've jumped past, [B] is gettings its cx->blk_eval.retop
# from the eval context of [A]
