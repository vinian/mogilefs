#!/usr/bin/perl
#

__END__

mkdir /mnt/mogilefs
mkdir /mnt/mogilefs/brad
mkdir /mnt/mogilefs/kenny
mkdir /mnt/mogilefs/cartman
mount -t nfs -o defaults,noatime,timeo=2,retrans=1,soft 10.1.0.10:/var/mogdata /mnt/mogilefs/brad
mount -t nfs -o defaults,noatime,timeo=2,retrans=1,soft 10.1.0.2:/var/mogdata /mnt/mogilefs/kenny
mount -t nfs -o defaults,noatime,timeo=2,retrans=1,soft 10.1.0.1:/var/mogdata /mnt/mogilefs/cartman


