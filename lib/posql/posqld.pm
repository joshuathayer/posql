package posql::posqld;

# this is the posql daemon App
# this is an App in the Sisyphus framework sense

use lib '/Users/joshua/projects/sisyphus/lib';

use strict;
use Data::Dumper;
use JSON;
use String::CRC32;
use Scalar::Util qw/ weaken /;
use Sisyphus::Connector;
use Sisyphus::ConnectionPool;
use Sisyphus::Proto::Factory;
use Sisyphus::Proto::Mysql;

# TODO
# alarms to clear return_values

sub new {
	my $class = shift;
    my $log = shift;

	my $self = {
        handles => {},
        queues => {},
		return_values => {},
        qstate => {},
	};

	$self->{rid} = 0;
	$self->{log} = $log;

	return(bless($self, $class));
}

# create a new request ID
sub getRID {
	my $self = shift;
	$self->{rid} += 1;
	return $self->{rid};
}

# framework calls this when client connects
sub new_connection {
	my $self = shift;
	my ($ip, $port, $cid) = @_;

    $self->{log}->log("$ip:$port new connection");
	
	# create an array to hold return values
	$self->{return_values}->{$cid} = [];
}

# framework calls this when client disconnects
sub remote_closed {
    my ($self, $host, $port, $cid) = @_;

    $self->{log}->log("$host closed connection");
}

# called by framework when message arrives
sub message {
	my ($self, $host, $port, $message, $cid) = @_;

	foreach my $m (@$message) {
		$self->{log}->log("command $m->{command}");
		if ($m->{command} eq "dosql") {
			$self->do_sql($cid, $m->{sql}, $m->{handle});
		} elsif ($m->{command} eq "fields") {
			$self->do_fields($cid, $m->{sthid});
		} elsif ($m->{command} eq "fetchrows") {
			$self->do_fetchrows($cid, $m->{count}, $m->{sthid});
		} elsif ($m->{command} eq "new-mysql-host") {
			$self->do_new_mysql_host($cid, $m);
		} elsif ($m->{command} eq "rm-mysql-host") {
			$self->do_rm_mysql_host($cid, $m->{hostname}, $m->{handle});
        } elsif ($m->{command} eq "handle-dump") {
			$self->do_handle_dump($cid, $m->{handle});
		} else {
			$self->{log}->log("got unknown command $m->{command}");
		}
	}

}

sub do_new_mysql_host {
    my ($self, $cid, $m) = @_;

    my $hostname = $m->{hostname};
    my $port = $m->{port};
    my $user = $m->{user};
    my $password = $m->{password};
    my $handle = $m->{handle};
    my $db = $m->{db};

    $self->{handles}->{ $handle }->{ $hostname }->{port} = $port;
    $self->{handles}->{ $handle }->{ $hostname }->{user} = $user;
    $self->{handles}->{ $handle }->{ $hostname }->{password} = $password;
    $self->{handles}->{ $handle }->{ $hostname }->{state} = "disconnected";
    $self->{handles}->{ $handle }->{ $hostname }->{qcount} = 0;
    $self->{handles}->{ $handle }->{ $hostname }->{pool} = undef;

    print STDERR Dumper $self->{handles};

    push(@{$self->{return_values}->{$cid}}, {result=>"ok"});
    $self->{client_callback}->([$cid]);

    if(not(defined($self->{queues}->{$handle}))) { $self->{queues}->{$handle} = [] };

    # make this a subroutine, to support reconnections

    # connect.
    $self->{handles}->{ $handle }->{ $hostname }->{pool} = new Sisyphus::ConnectionPool;
    my $pool = $self->{handles}->{ $handle }->{ $hostname }->{pool};
    $pool->{host} = $hostname;
    $pool->{port} = $port;
    $pool->{connections_to_make} = 10;
    $pool->{protocolName} = "Mysql";
    $pool->{protocolArgs} = {
        user => $user,
        pw => $password,
        db => $db,
        err => sub {
            my $err = shift;
            $self->{log}->log("A mysql error occured on connection to $hostname ($handle): $err");
        },
    };

    # callback gets called once all connections are made in this pool
    $pool->connect(
        sub {
            $self->{log}->log("handle $handle finished connecting to mysql instance on $hostname");
            $self->{handles}->{ $handle }->{ $hostname }->{state} = "connected";

            # at connection-time, we should certainly have claimable connections.
            # this should change if for some reason we want to do something before
            # handling queries
            $self->{claimable_hosts}->{$handle}->{$hostname} = 1;

            # notify all connected clients of available handle

	        foreach my $this_cid (keys(%{$self->{return_values}})) {

                push(@{$self->{return_values}->{$this_cid}},
                    { notice => "handle_available", handle => $handle }
                );

                $self->{client_callback}->([$cid]);
            }

        }
    );

    # when a query is done and the calling code releases the connection, we want to 
    # see if any other queries are waiting. it would be nice to do this per-handle,
    # that would probably require modifying Sisyphus::ConnectionPool
    # XXX NO see note below about releasing and service_queryqueue
    $pool->{release_cb} = sub {
        # $wself->service_queryqueue;
    };

}

sub do_handle_dump {
    my ($self, $cid, $handle) = @_;

    $self->{log}->log("in do_handle_dump for $handle");
    print Dumper $self->{handles}->{$handle};

    my $ret;
    # this could stand to dump a lot more information
    foreach my $hostname (keys(%{$self->{handles}->{$handle}})) {
        my $host = $self->{handles}->{$handle}->{$hostname};
        foreach my $thing (qw/port user password state qcount/) {
            $ret->{$hostname}->{$thing} = $host->{$thing};
        }

        $ret->{$hostname}->{hostname} = $hostname;
    }

    push(@{$self->{return_values}->{$cid}}, $ret);
    $self->{client_callback}->([$cid]);
}

sub do_sql {
	my ($self, $cid, $sql, $handle) = @_;
    my $cb;

	my $rid = $self->getRID();

    push(@{$self->{return_values}->{$cid}}, { sthid => "$rid" });
    $self->{client_callback}->([$cid]);

    $self->{qstate}->{$rid}->{state} = "waiting";

    # push on to queue of queries to run once a connection becomes free
    push(@{$self->{queues}->{$handle}}, sub {

        # this gets run once a connection is claimable...
        my @hosts = keys(%{$self->{claimable_hosts}->{$handle}});
        my $host = $hosts[ int(rand($#hosts + 1)) ];

        $self->{log}->log("do_sql >>$sql<< on handle $handle, chose host $host, rid $rid");

        $self->{handles}->{$handle}->{$host}->{pool}->claim( sub {
            # once we've claimed a connection of our own... 
            my $ac = shift;
            my $wac = $ac;

            # if we've taken the last of the available connections, we note that
            # this host should not be in the list of hosts that have claimable
            # connections
            if (not ($self->{handles}->{$handle}->{$host}->{pool}->claimable())) {
                delete $self->{claimable_hosts}->{$handle}->{$host};
            }

            # we want to keep track of our connection,
            # so that other methods may operate on it (ie, "fields")
            $self->{qstate}->{$rid}->{ac} = $ac;
            $self->{qstate}->{$rid}->{state} = "running";
            $ac->{protocol}->query(
                q  => $sql,
                cb => sub {
                    my $row = shift;
                    if ($row->[0] eq "DONE") {

                        # since we will released this connection, by definition this 
                        # host has a claimable connection. thus we put this host back
                        # in the list of those which can be claim()ed from.
                        $self->{claimable_hosts}->{$handle}->{$host} = 1;

                        # it's important to release() under the above line, since the
                        # release callback will call service_queryqueue, which wants to
                        # see something in claimable_hosts
                        # XXX no, i've changed this. we'll call service_queryqueue by hand,
                        # so we can pass it a handle explicitly. the release callback
                        # is no essentially no-op
                        $self->{handles}->{$handle}->{$host}->{pool}->release($wac);

                        # $cb->(["DONE"]);
                        $self->{log}->log("query id $rid finished fetching rows from mysql server");
                        $self->{qstate}->{$rid}->{state} = "done";
                        $self->service_queryqueue($handle);
                    } else {
                        if(not($self->{qstate}->{$rid}->{notice_state} eq "data_available")) {

                            $self->{qstate}->{$rid}->{notice_state} = "data_available";

                            push(@{$self->{return_values}->{$cid}},
                                { notice => "data_available", sthid => $rid }
                            );

                            $self->{client_callback}->([$cid]);
                        }

                        $self->{qstate}->{$rid}->{state} = "fetching";

                        push(@{$self->{qstate}->{$rid}->{results}}, $row);
                        $self->{log}->log("query id $rid fetched row from mysql server");
                        # $cb->($row);
                    }
                },
            );
        });
    });

    $self->service_queryqueue($handle);
}

sub service_queryqueue {
    my ($self, $handle) = @_;

    if(scalar(keys(%{$self->{claimable_hosts}->{$handle}}))) {
        if (scalar(@{$self->{queues}->{$handle}})) {
            $self->{log}->log("found query to run, in service_queryqueue");
            my $sub = pop(@{$self->{queues}->{$handle}});
            $sub->();
        }
    } else {
        $self->{log}->log("out of hosts with claimable handles! enqueuing query.");
    }
}

sub do_fetchrows {
    my ($self, $cid, $count, $rid) = @_;

    my $ret;

    $ret->{sthid} = $rid;

    # give caller the query state, so they can retry or whatever if the q's not done
    $ret->{state} = $self->{qstate}->{$rid}->{state};
    my $result_count = scalar(@{$self->{qstate}->{$rid}->{results}});
    my $realcount = $result_count > $count ? $count : $result_count;
    while($realcount) {
        my $r = shift(@{$self->{qstate}->{$rid}->{results}});
        push(@{$ret->{rows}}, $r);
        $realcount--;
    }

    push(@{$self->{return_values}->{$cid}}, $ret);

    if (not(scalar(@{$self->{qstate}->{$rid}->{results}}))) {
        if(not($self->{qstate}->{$rid}->{notice_state} eq "data_exhausted")) {
            $self->{qstate}->{$rid}->{notice_state} = "data_exhausted";
            unshift(@{$self->{return_values}->{$cid}},
                { notice => "data_exhausted", sthid=>$rid}
            );
        }
    }
    $self->{client_callback}->([$cid]);
}

sub do_fields {
    my ($self, $cid, $rid) = @_;

    $self->{log}->log("got a do_fields for rid $rid");

    my $ac = $self->{qstate}->{$rid}->{ac};
    my $fields = $ac->{protocol}->fields();

    my $ret;
    $ret->{sthid} = $rid;
    $ret->{fields} = $fields;

    push(@{$self->{return_values}->{$cid}}, $ret);
    $self->{client_callback}->([$cid]);
}

sub get_data {
	my ($self, $cid) = @_;
	my $v = pop(@{$self->{return_values}->{$cid}});
	return $v;
}

1;
