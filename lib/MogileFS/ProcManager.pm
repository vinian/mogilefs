package MogileFS::ProcManager;
use strict;
use warnings;
use POSIX;
use POSIX ":sys_wait_h"; # argument for waitpid
use Symbol;
use Socket;

# This class handles keeping lists of workers and clients and
# assigning them to eachother when things happen.  You don't actually
# instantiate a procmanager.  the class itself holds all state.

# Mappings: fd => [ clientref, jobstring, starttime ]
# queues are just lists of Client class objects
# ChildrenByJob: job => { pid => $client }
# ErrorsTo: fid => Client
# RecentQueries: [ string, string, string, ... ]
# Stats: element => number
our ($IsChild, @RecentQueries,
     %Mappings, %ChildrenByJob, %ErrorsTo, %Stats);

my @IdleQueryWorkers;  # workers that are idle, able to process commands  (MogileFS::Worker::Query, ...)
my @PendingQueries;    # [ MogileFS::Connection::Client, "$ip $query" ]

$IsChild = 0;  # either false if we're the parent, or a MogileFS::Worker object

# keep track of what all child pids are doing, and what jobs are being
# satisifed.
my %child  = ();    # pid -> MogileFS::Connection::Worker
my %todie  = ();    # pid -> 1 (lists pids that we've asked to die)
my %jobs   = ();    # jobname -> [ min, current ]

our $allkidsup = 0;  # if true, all our kids are running. set to 0 when a kid dies.

*error = \&Mgd::error;

sub RecentQueries {
    return @RecentQueries;
}

sub set_min_workers {
    my ($class, $job, $min) = @_;
    $jobs{$job} ||= [undef, 0];   # [min, current]
    $jobs{$job}->[0] = $min;

    # TODO: set allkipsup false, so spawner re-checks?
}

sub job_to_class_suffix {
    my ($class, $job) = @_;
    return {
        checker     => "Checker",
        queryworker => "Query",
        delete      => "Delete",
        replicate   => "Replicate",
        reaper      => "Reaper",
        monitor     => "Monitor",
    }->{$job};
}

sub job_to_class {
    my ($class, $job) = @_;
    my $suffix = $class->job_to_class_suffix($job) or return "";
    return "MogileFS::Worker::$suffix";
}

sub child_pids {
    return keys %child;
}

sub WatchDog {
    foreach my $pid (keys %child) {
        my MogileFS::Connection::Worker $child = $child{$pid};
        my $healthy = $child->watchdog_check;
        next if $healthy;

        error("Watchdog killing worker $pid (" . $child->job . ")");
        kill 9, $pid;
    }
}

# returns a sub that Danga::Socket calls after each event loop round.
# the sub must return 1 for the program to continue running.
sub PostEventLoopChecker {
    my $lastspawntime = 0; # time we last ran spawn_children sub

    return sub {
        # run only once per second
        my $now = time();
        return 1 unless $now > $lastspawntime;
        $lastspawntime = $now;

        MogileFS::ProcManager->WatchDog;

        # see if anybody has died, but don't hang up on doing so
        my $pid = waitpid -1, WNOHANG;
        return 1 if $pid <= 0 && $allkidsup;
        $allkidsup = 0; # know something died

        # when a child dies, figure out what it was doing
        # and note that job has one less worker
        my $jobconn;
        if ($pid > -1 && ($jobconn = delete $child{$pid})) {
            my $job = $jobconn->job;
            my $extra = $todie{$pid} ? "expected" : "UNEXPECTED";
            error("Child $pid ($job) died: $? ($extra)");
            MogileFS::ProcManager->NoteDeadChild($pid);

            if (my $jobstat = $jobs{$job}) {
                # if the pid is in %todie, then we have asked it to shut down
                # and have already decremented the jobstat counter and don't
                # want to do it again
                unless (my $true = delete $todie{$pid}) {
                    # decrement the count of currently running jobs
                    $jobstat->[1]--;
                }
            }
        }

        # foreach job, fork enough children
        while (my ($job, $jobstat) = each %jobs) {
            my $need = $jobstat->[0] - $jobstat->[1];
            if ($need > 0) {
                error("Job $job has only $jobstat->[1], wants $jobstat->[0], making $need.");
                for (1..$need) {
                    my $jobconn = make_new_child($job)
                        or return 1;  # basically bail: true value keeps event loop running
                    $child{$jobconn->pid} = $jobconn;

                    # now increase the count of processes currently doing this job
                    $jobstat->[1]++;
                }
            }
        }

        # if we got this far, all jobs have been re-created.  note that
        # so we avoid more CPU usage in this post-event-loop callback later
        $allkidsup = 1;

        # true value keeps us running:
        return 1;
    };
}

sub make_new_child {
    my $job = shift;

    my $pid;
    my $sigset;

    # block signal for fork
    $sigset = POSIX::SigSet->new(SIGINT);
    sigprocmask(SIG_BLOCK, $sigset)
        or return error("Can't block SIGINT for fork: $!");

    socketpair(my $parents_ipc, my $childs_ipc, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
        or die( "Sockpair failed" );

    return error("fork failed creating $job: $!")
        unless defined ($pid = fork);

    # enable auto-flush, so it's not pipe-buffered between parent/child
    select((select( $parents_ipc ), $|++)[0]);
    select((select( $childs_ipc  ), $|++)[0]);

    # if i'm the parent
    if ($pid) {
        sigprocmask(SIG_UNBLOCK, $sigset)
            or return error("Can't unblock SIGINT for fork: $!");

        close($childs_ipc);  # unnecessary but explicit
        IO::Handle::blocking($parents_ipc, 0);

        my $worker_conn = MogileFS::Connection::Worker->new($parents_ipc);
        $worker_conn->pid($pid);
        $worker_conn->job($job);
        MogileFS::ProcManager->RegisterWorkerConn($worker_conn);
        return $worker_conn;
    }

    # as a child, we want to close these and ignore them
    Mgd::close_listeners();
    close($parents_ipc);
    undef $parents_ipc;

    $SIG{INT} = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    $0 .= " [$job]";

    # unblock signals
    sigprocmask(SIG_UNBLOCK, $sigset)
        or return error("Can't unblock SIGINT for fork: $!");

    # now call our job function
    my $class = MogileFS::ProcManager->job_to_class($job)
        or die "No worker class defined for job '$job'\n";
    my $worker = $class->new($childs_ipc);

    # set our frontend into child mode
    MogileFS::ProcManager->SetAsChild($worker);

    $worker->work;
    exit 0;
}

sub PendingQueryCount {
    return scalar @PendingQueries;
}

sub BoredQueryWorkerCount {
    return scalar @IdleQueryWorkers;
}

sub QueriesInProgressCount {
    return scalar keys %Mappings;
}

sub StatsHash {
    return \%Stats;
}

sub foreach_job {
    my ($class, $cb) = @_;
    foreach my $job (sort keys %ChildrenByJob) {
        my $ct = scalar(keys %{$ChildrenByJob{$job}});
        $cb->($job, $ct, $jobs{$job}->[0], [ join(' ', sort { $a <=> $b } keys %{$ChildrenByJob{$job}}) ]);
    }
}

sub foreach_pending_query {
    my ($class, $cb) = @_;
    foreach my $clq (@PendingQueries) {
        $cb->($clq->[0],  # client object,
              $clq->[1],  # "$ip $query"
              );
    }
}

sub is_valid_job {
    my ($class, $job) = @_;
    return defined $jobs{$job};
}

sub valid_jobs {
    return sort keys %jobs;
}

sub request_job_process {
    my ($class, $job, $n) = @_;
    return 0 unless $class->is_valid_job($job);

    $jobs{$job}->[0] = $n;
    $allkidsup = 0;

    # try to clean out the queryworkers (if that's what we're doing?)
    MogileFS::ProcManager->CullQueryWorkers
        if $job eq 'queryworker';
}


# when a child is spawned, they'll have copies of all the data from the
# parent, but they don't need it.  this method is called when you want
# to indicate that this procmanager is running on a child and should clean.
sub SetAsChild {
    my ($class, $worker) = @_;

    @IdleQueryWorkers = ();
    @PendingQueries = ();
    %Mappings = ();
    $IsChild = $worker;
    %ErrorsTo = ();

    # and now kill off our event loop so that we don't waste time
    Danga::Socket->SetPostLoopCallback(sub { return 0; });
}

# called when a child has died.  a child is someone doing a job for us,
# but it might be a queryworker or any other type of job.  we just want
# to remove them from our list of children.  they're actually respawned
# by the make_new_child function elsewhere in Mgd.
sub NoteDeadChild {
    my $pid = $_[1];
    foreach my $job (keys %ChildrenByJob) {
        return if # bail out if we actually delete one
            delete $ChildrenByJob{$job}->{$pid};
    }
}

# called when a client dies.  clients are users, management or non.
# we just want to remove them from the error reporting interface, if
# they happen to be part of it.
sub NoteDeadClient {
    my $client = $_[1];
    delete $ErrorsTo{$client->{fd}};
}

# called when the error function in Mgd is called and we're in the parent,
# so it's pretty simple that basically we just spit it out to folks listening
# to errors
sub NoteError {
    return unless %ErrorsTo;

    my $msg = ":: ${$_[1]}\r\n";
    foreach my $client (values %ErrorsTo) {
        $client->write(\$msg);
    }
}

sub RemoveErrorWatcher {
    my ($class, $client) = @_;
    return delete $ErrorsTo{$client->{fd}};
}

sub AddErrorWatcher {
    my ($class, $client) = @_;
    $ErrorsTo{$client->{fd}} = $client;
}

# one-time initialization of a new worker connection
sub RegisterWorkerConn {
    my MogileFS::Connection::Worker $worker = $_[1];
    $worker->watch_read(1);

    #warn sprintf("Registering start-up of $worker (%s) [%d]\n", $worker->job, $worker->pid);

    # now do any special case startup
    if ($worker->job eq 'queryworker') {
        MogileFS::ProcManager->NoteIdleQueryWorker($worker);
    }

    # add to normal list
    $ChildrenByJob{$worker->job}->{$worker->pid} = $worker;

}

sub EnqueueCommandRequest {
    my ($class, $line, $client) = @_;
    push @PendingQueries, [
                           $client,
                           ($client->peer_ip_string || '0.0.0.0') . " $line"
                           ];
    MogileFS::ProcManager->ProcessQueues;
}

# puts a worker back in the queue, deleting any outstanding jobs in
# the mapping list for this fd.
sub NoteIdleQueryWorker {
    # first arg is class, second is worker
    my MogileFS::Connection::Worker $worker = $_[1];
    delete $Mappings{$worker->{fd}};

    # see if we need to kill off some workers
    if (job_needs_reduction('queryworker')) {
        Mgd::error("Reducing queryworker headcount by 1.");
        MogileFS::ProcManager->AskWorkerToDie($worker);
        return;
    }

    # must be okay, so put it in the queue
    push @IdleQueryWorkers, $worker;
    MogileFS::ProcManager->ProcessQueues;
}

# if we need to kill off a worker, this function takes in the WorkerConn
# object, tells it to die, marks us as having requested its death, and decrements
# the count of running jobs.
sub AskWorkerToDie {
    my MogileFS::Connection::Worker $worker = $_[1];
    note_pending_death($worker->job, $worker->pid);
    $worker->write(":shutdown\r\n");
}

# kill bored query workers so we can get down to the level requested.  this
# continues killing until we run out of folks to kill.
sub CullQueryWorkers {
    while (@IdleQueryWorkers && job_needs_reduction('queryworker')) {
        my MogileFS::Connection::Worker $worker = shift @IdleQueryWorkers;
        MogileFS::ProcManager->AskWorkerToDie($worker);
    }
}

# called when we get a response from a worker.  this reenqueues the
# worker so it can handle another response as well as passes the answer
# back on to the client.
sub HandleQueryWorkerResponse {
    # got a response from a worker
    my MogileFS::Connection::Worker $worker;
    my $line;
    (undef, $worker, $line) = @_;

    return Mgd::error("ASSERT: ProcManager (Child) got worker response: $line") if $IsChild;
    return unless $worker && $Mappings{$worker->{fd}};

    # get the client we're working with (if any)
    my ($client, $jobstr, $starttime) = @{ $Mappings{$worker->{fd}} };

    # if we have no client, then we just got a standard message from
    # the queryworker and need to pass it up the line
    return MogileFS::ProcManager->HandleChildRequest($worker, $line) if !$client;

    # FIXME: HOW IS THIS EVER CALLED?  things with colons never go to HandleQueryWorkerResponse.
    #        see MogileFS::Connection::Worker
    # out-of-band messages (not replies to requests) start with a colon:
    if ($line =~ /^:state_change (\w+) (\d+) (\w+)/) {
        my ($what, $whatid, $state) = ($1, $2, $3);
        state_change($what, $whatid, $state);
        return;
    }

    # at this point it was a command response, but if the client has gone
    # away, just reenqueue this query worker
    return MogileFS::ProcManager->NoteIdleQueryWorker($worker) if $client->{closed};

    # <numeric id> [client-side time to complete] <response>
    my ($time, $id, $res);
    if ($line =~ /^(\d+-\d+)\s+(\d+\.\d+)\s+(.+)$/) {
        # save time and response for use later
        ($id, $time, $res) = ($1, $2, $3);
    }

    # now, if it doesn't match
    unless ($id eq "$worker->{pid}-$worker->{reqid}") {
        Mgd::error("Worker responded with id $id, expected $worker->{pid}-$worker->{reqid}, killing");
        $client->close('worker_mismatch');
        return MogileFS::ProcManager->AskWorkerToDie($worker);
    }

    # now time this interval and add to @RecentQueries
    my $tinterval = Time::HiRes::tv_interval([$starttime]);
    push @RecentQueries, sprintf("%s %.4f %s", $jobstr, $tinterval, $time);
    shift @RecentQueries if scalar(@RecentQueries) > 50;

    # send text to client, put worker back in queue
    $client->write("$res\r\n");
    MogileFS::ProcManager->NoteIdleQueryWorker($worker);
}

# called from various spots to empty the queues of available pairs.
sub ProcessQueues {
    return if $IsChild;

    # try to match up a client with a worker
    while (@IdleQueryWorkers && @PendingQueries) {
        # get client that isn't closed
        my $clref;
        while (!$clref && @PendingQueries) {
            $clref = shift @PendingQueries
                or next;
            if ($clref->[0]->{closed}) {
                $clref = undef;
                next;
            }
        }
        next unless $clref;

        # get worker and make sure it's not closed already
        my MogileFS::Connection::Worker $worker = shift @IdleQueryWorkers;
        if (!defined $worker || $worker->{closed}) {
            unshift @PendingQueries, $clref;
            next;
        }

        # put in mapping and send data to worker
        push @$clref, Time::HiRes::gettimeofday();
        $Mappings{$worker->{fd}} = $clref;
        $Stats{queries}++;

        # increment our counter so we know what request counter this is going out
        $worker->{reqid}++;
        $worker->write("$worker->{pid}-$worker->{reqid} $clref->[1]\r\n");
    }
}

# send short descriptions of commands we support to the user
sub SendHelp {
    my $client = $_[1];

    # send general purpose help
    $client->write(<<HELP);
Mogilefsd admin commands:

    !recent     Recently executed queries and how long they took.
    !queue      Queries that are pending execution.
    !stats      General stats on what we\'re up to.
    !watch      Observe errors/messages from children.
    !jobs       Outstanding job counts, desired level, and pids.
    !shutdown   Immediately kill all of mogilefsd.

    !replication
                See the replication status for unreplicated files.
                Output format:
                <domain> <class> <devcount> <files>

    !to <job class> <message>
                Send <message> to all workers of <job class>.
                Mostly used for debugging.

    !want <count> <job class>
                Alter the level of workers of this class desired.
                Example: !want 20 queryworker, !want 3 replicate.
                See !jobs for what jobs are available.

HELP

}

# a child has contacted us with some command/status/something.
sub HandleChildRequest {
    return Mgd::error("ProcManager (Child) got request from child: $_[2]") if $IsChild;

    # if they have no job set, then their first line is what job they are
    # and not a command.  they also specify their pid, just so we know what
    # connection goes with what pid, in case it's ever useful information.
    my MogileFS::Connection::Worker $child = $_[1];
    my $cmd = $_[2];

    die "Child $child with no pid?" unless $child->job;

    # at this point we've got a command of some sort
    if ($cmd =~ /^error (.+)$/i) {
        # pass it on to our error handler, prefaced with the child's job
        Mgd::error("[" . $child->job . "(" . $child->pid . ")] $1");

    } elsif ($cmd =~ /^:state_change (\w+) (\d+) (\w+)/) {
        my ($what, $whatid, $state) = ($1, $2, $3);
        state_change($what, $whatid, $state, $child);

    } elsif ($cmd =~ /^repl_unreachable (\d+)/) {
        # announce to the other replicators that this fid can't be reached, but note
        # that we don't actually drain the queue to the requestor, as the replicator
        # isn't in a place where it can accept a queue drain right now.
        MogileFS::ProcManager->ImmediateSendToChildrenByJob('replicate', "repl_unreachable $1", $child);

    } elsif ($cmd =~ /^repl_i_did (\d+)/) {
        my $fid = $1;

        # announce to the other replicators that this fid was done and then drain the
        # queue to this person.
        MogileFS::ProcManager->ImmediateSendToChildrenByJob('replicate', "repl_was_done $fid", $child);

    } elsif ($cmd eq ":ping") {

        # warn sprintf("Job '%s' with pid %d is still alive at %d\n", $child->job, $child->pid, time());

        # this command expects a reply, either to die or stay alive.  beginning of worker's loops
        if (job_needs_reduction($child->job)) {
            MogileFS::ProcManager->AskWorkerToDie($child);
        } else {
            $child->write(":stay_alive\r\n");
        }

    } elsif ($cmd eq ":still_alive") {
        # a no-op

    } elsif ($cmd eq ":monitor_just_ran") {
        send_monitor_has_run($child);

    } elsif ($cmd =~ /^:invalidate_meta (\w+)/) {
        send_invalidate($1, $child);

    } elsif ($cmd =~ /^:set_config_from_child (\S+) (.+)/) {
        # and this will rebroadcast it to all other children
        # (including the one that just set it to us, but eh)
        MogileFS::Config->set_config($1, $2);

    } else {
        # unknown command
        my $show = $cmd;
        $show = substr($show, 0, 80) . "..." if length $cmd > 80;
        Mgd::error("Unknown command [$show] from child; job=" . $child->job);
    }
}

# Class method.
#   ProcManager->ImmediateSendToChildrenByJob($class, $message, [ $child ])
# given a job class, and a message, send it to all children of that job.  returns
# the number of children the message was sent to.
#
# if child is specified, the message will be sent to members of the job class that
# aren't that child.  so you can exclude the one that originated the message.
#
# doesn't add to queue of things child gets on next interactive command: writes immediately
# (won't get in middle of partial write, though, as danga::socket queues things up)
sub ImmediateSendToChildrenByJob {
    my $childref = $ChildrenByJob{$_[1]};
    return 0 unless defined $childref && %$childref;
    my $msg = $_[2];

    foreach my $child (values %$childref) {
        # ignore the child specified as the third arg if one is sent
        next if defined $_[3] && $_[3] == $child;

        # send the message to this child
        $child->write("$msg\r\n");
    }
    return scalar(keys %$childref);
}

# called when we notice that a worker has bit it.  we might have to restart a
# job that they had been working on.
sub NoteDeadWorkerConn {
    return if $IsChild;

    # get parms and error check
    my MogileFS::Connection::Worker $worker = $_[1];
    return unless $worker;

    # if there's a mapping for this worker's fd, they had a job that didn't get done
    if ($Mappings{$worker->{fd}}) {
        # unshift, since this one already went through the queue once
        unshift @PendingQueries, $Mappings{$worker->{fd}};
        delete $Mappings{$worker->{fd}};

        # now try to get it processing again
        MogileFS::ProcManager->ProcessQueues;
    }
}

# given (job, pid), record that this worker is about to die
sub note_pending_death {
    my ($job, $pid) = @_;

    die "$job not defined in call to note_pending_death.\n"
        unless defined $jobs{$job};

    $todie{$pid} = 1;
    $jobs{$job}->[1]--;
}

# see if we should reduce the number of active children
sub job_needs_reduction {
    my $job = shift;
    return $jobs{$job}->[0] < $jobs{$job}->[1];
}

sub is_child {
    return $IsChild;
}

sub state_change {
    my ($what, $whatid, $state, $child) = @_;
    #warn "STATE CHANGE: $what<$whatid> = $state\n";
    # TODO: can probably send this to all children now, not just certain types
    for my $type (qw(queryworker replicate delete monitor checker)) {
        MogileFS::ProcManager->ImmediateSendToChildrenByJob($type, ":state_change $what $whatid $state", $child);
    }
}

sub send_to_all_children {
    shift if @_ == 2;
    my $msg = shift;

    foreach my $child (values %child) {
        $child->write("$msg\r\n");
    }
}

sub send_invalidate {
    my ($what, $child) = @_;
    # TODO: can probably send this to all children now, not just certain types
    for my $type (qw(queryworker replicate delete monitor checker)) {
        MogileFS::ProcManager->ImmediateSendToChildrenByJob($type, ":invalidate_meta_once $what", $child);
    }
}

sub send_monitor_has_run {
    my $child = shift;
    for my $type (qw(replicate checker queryworker)) {
        MogileFS::ProcManager->ImmediateSendToChildrenByJob($type, ":monitor_has_run", $child);
    }
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End: