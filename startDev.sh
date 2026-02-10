#/bin/bash
MOJO_MODE=development PERL5LIB=.:local/lib/perl5 perl ./local/bin/hypnotoad app.pl
#MOJO_MODE=development carton exec hypnotoad app.pl
