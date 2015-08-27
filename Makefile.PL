use 5.14.2;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME => "Stack::Unwind",
    ABSTRACT => "Unwind the stack to a set mark",
    VERSION_FROM => "lib/Stack/Unwind.pm",
    LICENSE => "perl",
);
