package Stack::Unwind;
use strict;
use XSLoader;
use Exporter;

our @ISA = qw(Exporter);

our $VERSION = '0.01';

our @EXPORT_OK = qw(unwind);

XSLoader::load(__PACKAGE__, $VERSION);

1;
