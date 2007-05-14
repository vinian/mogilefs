#!/usr/bin/perl
use strict;
use warnings;
use Fuse;
use LWP::UserAgent;
use LWP::Simple;
use List::MoreUtils qw(uniq);
use MogileFS::Client;
use Path::Class;
use POSIX qw(ENOENT EISDIR EINVAL);
my $DEBUG = 0;

my $mogilefs = MogileFS::Client->new(
    domain  => 'resources',
    hosts   => [ 'cluster7:6001', 'cluster10:6001' ],
    timeout => 5,
);
$mogilefs->readonly(1);

my $ua = LWP::UserAgent->new;

sub e_getattr {
    my $filename = shift;
    warn "getattr $filename\n" if $DEBUG;

    my ( $size, $modes );
    my ( $dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize )
        = ( 0, 0, 0, 1, 0, 0, 1, 1024 );
    my ( $atime, $ctime, $mtime ) = ( time, time, time );

    if ( $filename !~ m{\.} ) {

        #        warn "directory!";
        $size  = 0;
        $modes = ( 0040 << 9 ) + 0755;
    } else {

        #        warn "file!";
        $size  = 123;
        $modes = ( 0100 << 9 ) + 0644;

        my @paths = $mogilefs->get_paths( $filename, { noverify => 1 } );
        my ( $content_type, $document_length, $modified_time, $expires,
            $server )
            = head( $paths[0] );
        $size = $document_length;
        ( $atime, $ctime, $mtime ) = ($modified_time) x 3;

        return -ENOENT() unless @paths;
    }

    warn(
        join(
            ",",
            (   $dev,   $ino,     $modes, $nlink, $uid,
                $gid,   $rdev,    $size,  $atime, $mtime,
                $ctime, $blksize, $blocks
            )
        ),
        "\n"
    ) if $DEBUG;

    return (
        $dev,  $ino,   $modes, $nlink, $uid,     $gid, $rdev,
        $size, $atime, $mtime, $ctime, $blksize, $blocks
    );
}

sub e_getdir {
    my $prefix = shift;
    warn "getdir $prefix\n" if $DEBUG;
    my @filenames;
    my $seen;
    $mogilefs->foreach_key(
        prefix => $prefix,
        sub {
            my $filename = shift;
            $filename =~ s/$prefix//;

            #            warn "file $filename";
            $filename =~ s{^/}{};
            push @filenames, $filename unless $filename =~ m{/};
            my $parent = file($filename)->parent;
            while (1) {
                last if $seen->{$parent}++;
                push @filenames, $parent unless $parent =~ m{/};

                #                 warn "dir $parent";
                $parent = $parent->parent;
                last if $parent eq '.';
                last if $parent eq '/';
                last if $parent =~ /\.\./;
            }
        }
    );

    @filenames = uniq @filenames;
    warn "returning: @filenames\n" if $DEBUG;
    return ( @filenames, 0 );
}

sub e_open {
    my $filename = shift;
    warn "open $filename\n" if $DEBUG;

    return -EISDIR() unless $filename =~ m{\.};
    my @paths = $mogilefs->get_paths( $filename, { noverify => 1 } );
    return -ENOENT() unless @paths;
    return 0;
}

sub e_read {
    my ( $filename, $buf, $off ) = @_;
    warn "read $filename $buf $off\n" if $DEBUG;

    return -EISDIR() if $filename =~ m{/$};
    my @paths = $mogilefs->get_paths( $filename, { noverify => 1 } );
    return -ENOENT() unless @paths;

    my ( $content_type, $document_length, $modified_time, $expires, $server )
        = head( $paths[0] );
    return 0 if $off == $document_length;

    my $maxoff = $off + ( $buf - 1 );
    $maxoff = $document_length if $maxoff > $document_length;
    my $range = $off . "-" . $maxoff;
    warn "  Range: bytes=$range\n" if $DEBUG;
    my $response = $ua->get( $paths[0], "Range" => "bytes=$range" );
    if ( $response->is_success ) {
        return $response->content;
    } else {
        warn $response->as_string;
    }
}

sub e_statfs { return 255, 1, 1, 1, 1, 2 }

# If you run the script directly, it will run fusermount, which will in turn
# re-run this script - hence the funky semantics
my ($mountpoint) = "";
$mountpoint = shift(@ARGV) if @ARGV;
Fuse::main(
    debug      => 1,
    mountpoint => $mountpoint,
    getattr    => "main::e_getattr",
    getdir     => "main::e_getdir",
    open       => "main::e_open",
    statfs     => "main::e_statfs",
    read       => "main::e_read",
    threaded   => 0,
);


