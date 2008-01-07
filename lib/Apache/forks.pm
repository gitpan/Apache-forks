package Apache::forks;
$VERSION = 0.022;

use strict;
use warnings;
use Carp ();

use constant MP2 => (exists $ENV{MOD_PERL_API_VERSION} &&
                     $ENV{MOD_PERL_API_VERSION} == 2) ? 1 : 0;
my @Import;

our $DEBUG = 0;

BEGIN {
	if (MP2) {
		require mod_perl2;
		require Apache2::MPM;
		require forks;
		require Apache2::Module;
		require Apache2::ServerUtil;
	}
	else {
		require mod_perl;
		if (defined $mod_perl::VERSION && $mod_perl::VERSION > 1 &&
			$mod_perl::VERSION < 1.99) {
			require Apache;
			require forks;

			#not using Apache::fork support yet (may be non-portable and/or deprecated)
#			require Apache::fork;
#			Apache::fork::forkoption(1);
#			no warnings 'redefine';
#			*threads::_fork = \&Apache::fork::fork;
		} else {
			die "Apache.pm is unavailable or unsupported version ($mod_perl::VERSION)";
		}
	}
	die "forks version 0.26 or later required--this is only version $forks::VERSION"
		unless defined($forks::VERSION) && $forks::VERSION >= 0.26;
	require forks::shared;
	{
		no warnings 'redefine';
		my $old_server_pre_startup = \&threads::_server_pre_startup;
		*threads::_server_pre_startup = sub {
			unless ($Apache::forks::DEBUG) {
				### close IO pipes to silence possible warnings to terminal ###
				close(STDERR);
				close(STDOUT);
				close(STDIN);
			}
			$old_server_pre_startup->()
				if ref($old_server_pre_startup) eq 'CODE';
		};
	}
}

sub debug {
	print STDERR "$_[1]\n" if $DEBUG >= $_[0] || threads->debug >= $_[0];
}

sub import {
	shift;
	forks->import(@_);

	my $timestamp = localtime(time);
	if (MP2) {
		if (!@Import) {
			Carp::carp("Apache MPM '".Apache2::MPM->show()
				."' is not supported: "
				."This package can't be used under threaded MPMs: "
				."Only 'Prefork' MPM is supported at this time\n")
			and return if Apache2::MPM->is_threaded;
			
			my $s = Apache2::ServerUtil->server;
			$s->push_handlers(PerlChildInitHandler => \&childinit);
			debug(1, "[$timestamp] [notice] $$:".threads->tid
				." Apache::forks PerlChildInitHandler enabled");
		}
	} else {
		Carp::carp("Apache.pm was not loaded\n")
		and return unless $INC{'Apache.pm'};

		if (!@Import and Apache->can('push_handlers')) {
			Apache->push_handlers(PerlChildInitHandler => \&childinit);
			debug(1, "[$timestamp] [notice] $$:".threads->tid
				." Apache::forks PerlChildInitHandler enabled");
		}
	}

	push @Import, [@_];
}

sub childinit {
	threads->isthread;
	my $timestamp = localtime(time);
	debug(1, "[$timestamp] [notice] $$:".threads->tid
		." Apache::forks PerlChildInitHandler executed");

	1;
}

package
	Apache::forks::shared;	# hide from PAUSE

sub import {
	shift;
	forks::shared->import(@_);
}

1;

__END__

=pod

=head1 NAME

Apache::forks - Transparent Apache ithreads integration using forks

=head1 VERSION

This documentation describes version 0.022.

=head1 SYNOPSIS

 # Configuration in httpd.conf

 PerlModule Apache::forks  # this should come before all other modules!

Do NOT change anything in your scripts. The usage of this module is transparent.

=head1 DESCRIPTION

Transparent Apache ithreads integration using forks.  This module enables the
ithreads API to be used among multiple processes in a pre-forking Apache http
environment.

=head1 REQUIRED MODULES

 Devel::Required (0.07)
 forks (0.26)
 mod_perl (any)
 Test::More (any)

=head1 USAGE

The module should be loaded upon startup of the Apache daemon.  You must be
using at least Apache httpd 1.3.0 or 2.0 for this module to work correctly.

Add the following line to your httpd.conf:

 PerlModule Apache::forks

or the following to the first PerlRequire script (i.e. startup.pl):

 use Apache::forks;

It is very important to load this module before all other perl modules!

A common usage is to load the module in a startup file via the PerlRequire
directive. See eg/startup.pl in this distribution.  In this case, be sure
that the module is first to load in the startup script, and that the
PerlRequre directive to load the startup script is the first mod_perl directive
in your httpd.conf file.

=head1 NOTES

=head2 threads->list and $thr->join differences in mod_perl

CGI scripts may behave differently when using forks with mod_perl, depending
on how you have implemented threads in your scripts.  This is frequently due to
the difference in the thread group behavior: every mod_perl handler (process)
is already a thread when your CGI starts executing, and all CGIs executing
simultaneously on your Apache server are all part of the same application
thread group.  Your script is no longer executed as the main thread
(Thread ID 0); it is just another child thread in the executing thread group.

This differs from pure CGI-style execution, where every CGI has its own unique
thread group (isolated from all other Apache process handlers) and each CGI
always begins execution as the main thread.

For example, if you were successfully doing the following in CGI:

 use forks;
 threads->new({'context' => 'scalar'}, sub {...}) for 1..5;
 push @results, $_->join foreach threads->list(threads::running);

the join operation would block indefinately in mod_perl until the current
request handler timed out and the execution was terminated by Apache. This occurs
because all other currently running Apache handler child processes are active
perl threads that can not be joined until the Apache httpd server is shut down
or the child handler is recycled by Apache (i.e. L<<a href="http://httpd.apache.org/docs/1.3/mod/core.html#maxrequestsperchild">MaxRequestsPerChild</a>>
was exceeded).

The solution is to do the following instead:

 use forks;
 push @my_threads, threads->new({'context' => 'scalar'}, sub {...}) for 1..5;
 push @results, $_->join foreach @my_threads;

This insures join actions only occur on threads explicitly started by the script.

Additionally, never do the following in mod_perl:

 threads->new({'context' => 'scalar'}, sub {...}) for 1..5;
 $_->join foreach threads->list(threads::joinable);	#<-- don't do this
 
as you might inadvertantly join threads started by from other Apache handler
processes! Do the following instead:

 push @my_threads, threads->new({'context' => 'scalar'}, sub {...}) for 1..5;
 $_->join foreach map($_->is_joinable ? $_ : (), @my_threads);
 
The good news about making such logic changes is that they will work both in CGI
and mod_perl modes.  If you code all your threaded CGIs in this style, your code
should work fine without changes when switching to mod_perl.

=head1 TODO

Determine why mod_perl appears to skip END blocks of child threads (threads
started in an apache-forked handler process) that complete and exit safely.
This isn't necessarily harmful, but should be resolved to insure highest level
of application and memory stability.

=head1 CAVIATS

This module will only work with Apache httpd 1.3.0 or newer.  This is due to the
lack of mod_perl support for PerlChildInitHandler directive.  See L<mod_perl/"mod_perl">
for more information regarding this.

For Apache 2.x, this module currently only supports the L<<a href="http://httpd.apache.org/docs/2.0/mod/prefork.html">prefork</a>>
MPM (Multi-Processing Module).  This is due to the architecture of L<forks>,
which only supports one perl thread per process.

=head1 BUGS

Forks 0.23 issues: Lots of warnings spew.  DBI handles act unpredictably.

Forks 0.24 issues: Unstable handlers on some platforms, likely due to overloading %SIG.
May need a less agressive signal management mode, for cases such as this.

=head1 CREDITS

=over

=item Apache::DBI

Provided the general framework to seamlessly load a module and execute a
subroutine on init of each Apache child handler process for both Apache 1.3.x 
and 2.x.

=back

=head1 AUTHOR

Eric Rybski

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2007-2008 Eric Rybski <rybskej@yahoo.com>.
All rights reserved.  This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=head1 SEE ALSO

L<forks>, L<forks::shared>.

=cut
