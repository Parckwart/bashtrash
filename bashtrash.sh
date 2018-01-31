#!/usr/bin/env bash

cat () {
	local file_not_found=false
	
	if [ "$1" ]; then
		for i in $*; do
			if [ -a "$i" ]; then
				while read -srN 1 i; do
					echo -n "$i"
				done < "$1"
			else
				echo "cat: $i: No such file or directory"
				file_not_found=true
			fi
		done
	else
		while read -srN 1 i; do
			echo -n "$i"
		done
	fi
	
	if [ "$1" ] && $file_not_found; then
		return 1
	else
		return 0
	fi
}
