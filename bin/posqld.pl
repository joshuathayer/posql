#!/usr/bin/perl

use strict;

BEGIN {
	if ($#ARGV < 0) {
		print "Usage: $0 PATH_TO_CONFFILE\n";
		exit;
	}

}

use lib "/Users/joshua/projects/posql/lib";
use File::Lockfile;
use Sys::Hostname;
use Sisyphus::Listener;
use Sisyphus::Proto::JSON;
use AnyEvent::Strict;
use posql::posqld;
use Net::Server::Daemonize qw ( daemonize check_pid_file );

my $config;
my $confPath = $ARGV[0];
require $confPath;
$config = $Config::config;

my $cluster_state = $Config::cluster_state;

# background, if wanted.
unless(check_pid_file("/var/run/" . $config->{dname} . ".pid")) { print $config->{dname} . " already running- aborting"; exit; }
$config->{daemonize} && daemonize('nobody','nogroup',"/var/run/".$config->{dname}.".pid"); 

my $log = Sislog->new({use_syslog=>1, facility=>$config->{dname}});
$log->open();

$log->log("posqld coming up");
my $listener = new Sisyphus::Listener;

$listener->{port} = $config->{port}; 
$listener->{ip} = $config->{ip}; 
$listener->{protocol} = "Sisyphus::Proto::JSON";
$listener->{application} = posql::posqld->new(
	$log,
);
$listener->{use_push_write} = 0;
$listener->listen();

AnyEvent->condvar->recv;

END {
	if ($log and ($! or $@)) {
		my $errm = "posqld ended with error: $! $@";
		$log->log($errm, time);
	}
}
