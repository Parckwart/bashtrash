#!/usr/bin/env bash

function cat {
	local file_not_found=false
	
	if [ "$1" ]; then
		for i in $*; do
			if [ -a "$i" ]; then
				echo "$(<$i)"
			else
				echo "cat: $i: No such file or directory"
				file_not_found=true
			fi
		done
	else
		while read line; do
			echo "$line"
		done
	fi
	
	if [ "$1" ] && $file_not_found; then
		return 1
	else
		return 0
	fi
}