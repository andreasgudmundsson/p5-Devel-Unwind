use Stack::Unwind;

unwind FOO:;
# There's something going on here if the module returns 0
# then execution resumes in the 'or do' block of simple-require.pl
# but if I return 1 then execution resumes after the mark
1;
