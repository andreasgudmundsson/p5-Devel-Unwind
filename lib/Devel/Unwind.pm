package Devel::Unwind;
use strict;
use XSLoader;
use Exporter;

our @ISA = qw(Exporter);
our $VERSION = '0.01';

XSLoader::load(__PACKAGE__, $VERSION);

1;
