#!/bin/bash

TEMPDIR=/tmp/$$.d
TEMPLOGGED=${TEMPDIR}/logged

rm -rf $TEMPDIR
mkdir -m 700 $TEMPDIR || { echo "Can't create temp dir" 1>&2 ; exit 1 ; }

trap 'rm -rf $TEMPDIR' EXIT


export LC_ALL=C
netstat -ln | 
	grep '::1:20[0-9][0-9][0-9]' | 
	awk '{ print $4 }' | 
	sed -e 's/::1://' | sort > $TEMPLOGGED &&
	sort -t: +2 -3 /etc/passwd | 
	join -t: -1 1 -2 3 $TEMPLOGGED - | 
	awk -F: '{ printf("%s\t%s\n", $2, $1) }' | 
	sort
