#!/bin/bash
#
#  Build and install all MogileFS packages on this system
#
#  Usage:
#    PREFIX=/usr/local build-all.sh
#
#  Set PREFIX to the top-level install directory (subdirectories under this
#  will be bin, lib, man and share). The default prefix is $HOME/local.

PREFIX=${PREFIX:-$HOME/local}

if [ ! -d api -o ! -d server ] ; then
	echo "Wrong directory - run this from MogileFS top directory"
	exit 8
fi

build_and_install() {
	perl Makefile.PL INSTALLDIRS=vendor PREFIX=$PREFIX
	make
	make test
	make install
}

pushd api/perl/MogileFS-Client
build_and_install
popd

pushd utils
build_and_install
popd

pushd server
build_and_install
popd
