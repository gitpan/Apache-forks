#!/usr/local/bin/perl -w

# to load this file when the server starts, add this to httpd.conf:
# PerlRequire /path/to/startup.pl

# make sure we are in a sane environment.
$ENV{MOD_PERL} or die "GATEWAY_INTERFACE not Perl!";

use Apache::Registry;
use Apache::forks;
#use Apache::forks::shared;
use strict;

#...other startup modules and items go here

1;
