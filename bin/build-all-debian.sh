#!/bin/bash
#
#  Build all MogileFS packages

if [ ! -x /usr/bin/dpkg-buildpackage ] ; then
        echo "Command dpkg-buildpackage is not installed. Please ensure you have"
        echo "all the prerequisites listed in INSTALL.txt installed."
        exit 8
fi

if [ ! -d api -o ! -d server ] ; then
	echo "Wrong directory - run this from MogileFS top directory"
	exit 8
fi

pushd api/perl/MogileFS-Client
dpkg-buildpackage -rfakeroot
popd

if [ ! -f /usr/share/perl5/MogileFS/Client.pm ] ; then
        echo "You have to install libmogilefs-perl deb file and then run this script again."
        exit 8
fi

pushd utils
dpkg-buildpackage -rfakeroot
popd

pushd server
dpkg-buildpackage -rfakeroot
popd

echo Moving all built packages to packages/
mkdir -p packages

mv *.{dsc,changes,tar.gz,deb} packages/
mv api/perl/*.{dsc,changes,tar.gz,deb} packages/

ls -l packages/*
