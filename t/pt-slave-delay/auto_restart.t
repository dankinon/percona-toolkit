#!/usr/bin/env perl

BEGIN {
   die "The PERCONA_TOOLKIT_BRANCH environment variable is not set.  See http://code.google.
com/p/maatkit/wiki/Testing"
      unless $ENV{PERCONA_TOOLKIT_BRANCH} && -d $ENV{PERCONA_TOOLKIT_BRANCH};
   unshift @INC, "$ENV{PERCONA_TOOLKIT_BRANCH}/lib";

};

use strict;
use warnings FATAL => 'all';
use English qw( -no_match_vars );
use Test::More;
use Data::Dumper;

use PerconaTest; 
use Sandbox;
require "$trunk/bin/pt-slave-delay";

my $dp  = DSNParser->new(opts => $dsn_opts);
my $sb  = Sandbox->new(basedir => '/tmp', DSNParser => $dp);
my $dbh = $sb->get_dbh_for('slave1');

if ( !$dbh ) {
   plan skip_all => 'Cannot connect to MySQL slave.';
}
elsif ( !@{$dbh->selectcol_arrayref('SHOW DATABASES LIKE "sakila"')} ) {
   plan skip_all => 'sakila db not loaded';
}
else {
   plan tests => 3;
}

my $cnf = '/tmp/12346/my.sandbox.cnf';
my $cmd = "$trunk/bin/pt-slave-delay -F $cnf";
my $output;

# #############################################################################
# Issue 991: Make mk-slave-delay reconnect to db when it loses the dbconnection
# #############################################################################

# Fork a child that will stop the slave while we, the parent, run
# tool.  The tool should report that it lost its slave cxn, then
# the child should restart the slave, and the tool should report
# that it reconnected and did some work, ending with "Setting slave
# to run normally".
diag('Running...');
my $pid = fork();
if ( $pid ) {
   # parent
   $output = `$cmd --interval 1 --run-time 4 2>&1`;
   like(
      $output,
      qr/Lost connection.+?Reconnected to slave.+Setting slave to run/ms,
      "Reconnect to slave"
   );
}
else {
   # child
   sleep 1;
   diag(`/tmp/12346/stop >/dev/null`);
   sleep 1;
   diag(`/tmp/12346/start >/dev/null`);
   diag(`/tmp/12346/use -e "set global read_only=1"`);
   exit;
}
# Reap the child.
waitpid ($pid, 0);

# Do it all over again, but this time KILL instead of restart.
$pid = fork();
if ( $pid ) {
   # parent. Note the --database mysql
   $output = `$cmd --database mysql --interval 1 --run-time 4 2>&1`;
   like(
      $output,
      qr/Lost connection.+?Reconnected to slave.+Setting slave to run/ms,
      "Reconnect to slave when KILL'ed"
   );
}
else {
   # child. Note that we'll kill the parent's 'mysql' connection
   sleep 1;
   my $c_dbh = $sb->get_dbh_for('slave1');
   my @cxn = @{$c_dbh->selectall_arrayref('show processlist', {Slice => {}})};
   foreach my $c ( @cxn ) {
      # The parent's connection:
      # {command => 'Sleep',db => 'mysql',host => 'localhost',id => '5',info => undef,state => '',time => '1',user => 'msandbox'}
      if ( ($c->{db} || '') eq 'mysql' && ($c->{user} || '') eq 'msandbox' ) {
         $c_dbh->do("KILL $c->{id}");
      }
   }
   exit;
}
# Reap the child.
waitpid ($pid, 0);

# #############################################################################
# Done.
# #############################################################################
ok($sb->ok(), "Sandbox servers") or BAIL_OUT(__FILE__ . " broke the sandbox");
exit;
