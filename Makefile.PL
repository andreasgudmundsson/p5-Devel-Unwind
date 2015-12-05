use ExtUtils::MakeMaker;

WriteMakefile(
    NAME => "Stack::Unwind",
    ABSTRACT => "Unwind the stack to a set mark",
    VERSION_FROM => "lib/Stack/Unwind.pm",
    LICENSE => "perl",
);

# Add -Wall to CCFLAGS without overwriting the defaults
package MY;
sub cflags {
    my $self   = shift;
    my $cflags = $self->SUPER::cflags(@_);
    my @cflags = split /\n/, $cflags;

    $self->{CCFLAGS} .= ' -Wall ';
    $self->{CCFLAGS} .= ' -Wextra';
    $self->{CCFLAGS} .= ' -Wno-unused-function';
    $self->{CCFLAGS} .= ' -Wno-unused-label';
    $self->{CCFLAGS} .= ' -std=c89 ';

    foreach (@cflags) {
        $_ = "CCFLAGS = $self->{CCFLAGS}" if /^CCFLAGS/;
    }
    return $self->{CFLAGS} = join("\n", @cflags) . "\n";
}
