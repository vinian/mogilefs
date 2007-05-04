package MogileFS::RebalancePolicy::PercentFree;
use strict;
use warnings;
use base 'MogileFS::RebalancePolicy';
use MogileFS::Util qw(weighted_list error);

sub devfids_to_rebalance {
    my ($self) = @_;

    # first, find a device.. only migrate away from disks which are in the 50th+ percentile,
    # in terms of fullness.  then picked one based on a weighted selection of their fullness.
    my @devs = (sort { $b->percent_full <=> $a->percent_full }
                grep { $_->can_read_from && $_->can_delete_from && defined $_->percent_full }
                MogileFS::Device->devices);

    # nothing to do, disabling.
    unless (@devs) {
        error("Rebalancing -- nothing to do..  Disabling.");
        MogileFS::Config->set_server_setting("enable_rebalance", 0);
        return ();
    }

    # stop if most full is only 25% more full than least full.
    my $most_full  = $devs[0]->percent_full;
    my $least_full = $devs[-1]->percent_full;
    if ($least_full && ($most_full / $least_full) < 1.25) {
        error("Rebalancing good enough.  Disabling.");
        MogileFS::Config->set_server_setting("enable_rebalance", 0);
        return ();
    }

    my $to_chop = int(@devs / 2);
    @devs = @devs[0..$#devs-$to_chop];
    @devs = weighted_list(map { [$_, $_->percent_full] } @devs);

    my @ret;
    my $sto = Mgd::get_store();
    while (my $dev = shift @devs) {
        my @fids = $sto->random_fids_on_device($dev->id, 50);
        foreach my $fid (@fids) {
            push @ret, MogileFS::DevFID->new($dev, $fid);
        }
        last if @ret >= 50;
    }
    return @ret;
}

1;
