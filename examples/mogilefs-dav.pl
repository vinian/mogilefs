#!/usr/bin/perl

# hachi 20070227
# This is a partially finished server implemented using Net::DAV::Server and the FilePaths plugin for MogileFS.

use strict;
use warnings;

use HTTP::Daemon;
#use Filesys::Virtual::MogileFS; # Below for the time being
use Net::DAV::Server;

my $filesys = Filesys::Virtual::MogileFS->new;
my $webdav = Net::DAV::Server->new();

$webdav->filesys($filesys);

my $d = HTTP::Daemon->new(
    LocalAddr => '0.0.0.0',
    LocalPort => 8008,
    ReuseAddr => 1) || die $!;

print $d->url . "\n";

while (my $c = $d->accept) {
    while (my $request = $c->get_request) {
        my $response = eval { $webdav->run($request) };
        warn "EVAL: $@" if $@;
        $c->send_response($response);
    }
    $c->close;
    undef $c;
}

package Filesys::Virtual::MogileFS;

use strict;
use warnings;

use lib 'cvs/mogilefs/api/perl/MogileFS-Client/lib';
use lib 'cvs/mogilefs/api/perl/MogileFS-Client-FilePaths/lib';

use base 'Filesys::Virtual';

use Fcntl qw(:mode);
use LWP::Simple;
use MogileFS::Client::FilePaths;
use Tie::Handle::HTTP;

sub new {
    my $class = shift;
    my $self = bless {
        cwd => '/',
    }, (ref $class || $class);

    my $mogclient = MogileFS::Client::FilePaths->new(
        hosts => ['127.0.0.1:7001'],
        domain => "filepaths",
    );

    die unless $mogclient;

    $self->{mogclient} = $mogclient;

    return $self;
}

sub mogclient { return $_[0]->{mogclient}; }

sub open_write {
    my $self = shift;
    my $path = $self->_fixup_path(shift);

    open(my $handle, "+>", undef) or die("Couldn't open a tempfile?: $!");

    # Look at me, I'm graham barr!
    *{$handle} = \$path;

    return $handle;
}

sub close_write {
    my $self = shift;
    my $handle = shift;

    my $size = (stat($handle))[7];

    my $path = ${*{$handle}{SCALAR}};
    my $mog_handle = $self->mogclient->new_file($path, 'temp', $size,
                                                {
                                                    meta => {
                                                                mtime => scalar(time),
                                                            },
                                                });

    seek($handle, 0, 0) or die("Couldn't seek to 0");

    while (sysread $handle, my $buffer, 1024) {
        print $mog_handle $buffer;
    }
    close $handle;
    close $mog_handle;
}

sub open_read {
    my $self = shift;
    my $path = $self->_fixup_path(shift);

    my @paths = $self->mogclient->get_paths($path);

    return unless @paths;

    my $handle = Tie::Handle::HTTP->new($paths[0]);

    return $handle;
}

sub close_read {
    my $self = shift;
    my $handle = shift;

    close $handle;
}

sub list {
    my $self = shift;
    my $path = $self->_fixup_path(shift);

    my @listing = $self->mogclient->list($path);

    return unless @listing;

    my @files = map {$_->{name}} @listing;

    return @files;
}

my @dir_stat = (
    e => 1,
    d => 1,
);

my @file_stat = (
    e => 1,
    d => 0,
    s => 1025,
);

sub MODE_DIR  () { S_IFDIR | S_IRWXU | S_IRWXG | S_IRWXO }
sub MODE_FILE () { S_IFREG | S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH }

sub stat {
    my $self = shift;
    my $path = $self->_fixup_path(shift);

    my $mogclient = $self->mogclient;

    my @paths = $mogclient->get_paths($path);

    if (@paths) {
        if (my ($content_type, $document_length, $modified_time, $expires, $server) = head($paths[0])) {
            return ($$, 0, MODE_FILE, 1, 0, 0, undef, $document_length, time, $modified_time, $^T, 512, 512);
        }
        return ($$, 0, MODE_FILE, 1, 0, 0, undef, 1024, time, $^T, $^T, 512, 512);
    }

    my @listing = $mogclient->list($path);

    if (scalar(@listing) || $path eq '/') {
        return ($$, 0, MODE_DIR, 1, 0, 0, undef, 1024, time, $^T, $^T, 512, 512);
    }

    return;
}

<<EOT;
0 dev
1 ino
2 mode
3 nlink
4 uid
5 gid
6 rdev
7 size
8 atime
9 mtime
10 ctime
11 blksize
12 blocks
EOT


sub test {
    my $self = shift;
    my $test = shift;
    my $path = $self->_fixup_path(shift);
    warn "Test: $test on $path\n" if 0;

    my @stat = $self->stat($path);

    return 0 unless @stat;

    my $tests = {
        'e' => sub {
            return 1;
        },
        's' => sub {
            return $stat[7];
        },
        'f' => sub {
            return S_ISREG($stat[2]);
        },
        'd' => sub {
            return S_ISDIR($stat[2]);
        },
        'r' => sub {
            return 1;
        },
    };

    if (exists $tests->{$test}) {
        my $result = $tests->{$test}->();
        warn "Result: $result\n" if 0;
        return $result;
    }

    warn "No test defined for $test on file $path\n";
}

sub cwd {
    my $self = shift;
    my $cwd = $self->{cwd};
    return $cwd;
}

sub chdir {
    my $self = shift;
    my $path = shift;
    return $self->{cwd} = $path;
}

sub delete {
    my $self = shift;
    my $path = $self->_fixup_path(shift);

    $self->mogclient->delete($path);
}

sub _fixup_path {
    my $self = shift;
    my $path = shift;

    unless (defined $path) {
        $path = '';
    }

    if ($path =~ m!^/!) {
        return $path;
    }

    my $cwd = $self->{cwd};
    $cwd =~ s!/*$!/!;
    return "${cwd}${path}";
}

1;

# vim: filetype=perl softtabstop=4 expandtab
