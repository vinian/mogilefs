package Mogstored::HTTPServer::Perlbal;
use strict;
use base 'Mogstored::HTTPServer';

sub start {
    my $self = shift;

    # use AIO channels in Perlbal
    Perlbal::AIO::set_file_to_chan_hook(sub {
        my $filename = shift;
        $filename =~ m{/dev(\d+)\b} or return undef;
        return "dev$1";
    });

    my $xs_conf = "";
    if (eval "use Perlbal::XS::HTTPHeaders (); 1") {
        $xs_conf .= "xs enable headers\n" unless defined $ENV{PERLBAL_XS_HEADERS} && ! $ENV{PERLBAL_XS_HEADERS};
    }

      # this is the perlbal configuration only.  not the mogstored configuration.
      my $pb_conf = "
$xs_conf
SERVER max_connections = $self->{maxconns}

   SET mogstored.listen = $self->{listen}
   SET mogstored.dirindexing = 0
   SET mogstored.enable_put = 1
   SET mogstored.enable_delete = 1
   SET mogstored.min_put_directory = 1
   SET mogstored.persist_client = 1
ENABLE mogstored

";

    Perlbal::run_manage_commands($pb_conf, sub { print STDERR "$_[0]\n"; });

    unless (Perlbal::Socket->WatchedSockets > 0) {
        die "Invalid configuration.  (shouldn't happen?)  Stopping.\n";
    }
}

sub pre_daemonize {
    my $self = shift;
    die "mogstored won't daemonize with \$ENV{MOGSTORED_RUN_WITHOUT_AIO} set.\n" if $ENV{'MOGSTORED_RUN_WITHOUT_AIO'};
}

sub post_daemonize {
    my $self = shift;
    # set number of AIO threads, between 10-100 (for some reason, have to
    # set aio threads after daemonizing)
    my $aio_threads = _aio_threads(_disks($self->{docroot}));
    Perlbal::run_manage_commands("SERVER aio_threads = $aio_threads", sub { print STDERR "$_[0]\n"; });
}

sub _disks {
    my $root = shift;
    opendir(my $dh, $root) or die "Failed to open docroot: $root: $!";
    return scalar grep { /^dev\d+$/ } readdir($dh);
}

# returns aio threads to use, given a disk count
sub _aio_threads {
    my $disks = shift;
    my $threads = ($disks || 1) * 10;
    return 100 if $threads > 100;
    return $threads;
}

1;
