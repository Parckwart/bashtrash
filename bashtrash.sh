#!/usr/bin/env bash
#
# bashtrash -- POSIX cat(1), tail(1) and id(1) written entirely in bash.
#
# Nothing in here forks or execs an external program: every operation is a
# shell builtin, so these keep working in a shell with an empty $PATH.
# Source the file to shadow the real utilities:
#
#	. bashtrash.sh
#
# Conformance target: POSIX.1-2017 (IEEE Std 1003.1-2017).  Identifiers
# that bash does not expose (the effective group, the supplementary list)
# come from /proc/self/status, and names from /etc/passwd and /etc/group,
# all of them read with the read builtin.
#
# A bash variable cannot hold a NUL byte, so input is read as NUL delimited
# blocks: every block is NUL free and therefore storable, and the NULs that
# separated them are written back out explicitly.  That keeps arbitrary
# binary input byte for byte, and reading a block at a time rather than a
# byte at a time keeps the cost sane.

_BT_BLOCK=65536

# ---------------------------------------------------------------------------
# Helpers.  Everything private is prefixed with _bt_ so that sourcing this
# file adds no other names to the caller's namespace.
# ---------------------------------------------------------------------------

# Write a diagnostic to standard error, where POSIX wants it.
_bt_err() {
	printf '%s\n' "$*" >&2
}

# Explain why FILE cannot be read.  errno is not reachable from bash, so the
# three cases that actually occur are reconstructed from the file tests.
# Sets _bt_reason in the caller.
_bt_why() {
	if [ ! -e "$1" ]; then
		_bt_reason='No such file or directory'
	elif [ -d "$1" ]; then
		_bt_reason='Is a directory'
	elif [ ! -r "$1" ]; then
		_bt_reason='Permission denied'
	else
		_bt_reason='Cannot open'
	fi
}

# True if $1 is a decimal integer with an optional sign, as POSIX requires of
# the -c and -n option-arguments.
_bt_isnum() {
	local n=$1
	case $n in
	[+-]*)	n=${n#?} ;;
	esac
	[ -n "$n" ] || return 1
	case $n in
	*[!0-9]*)	return 1 ;;
	esac
	return 0
}

# Read up to $_BT_BLOCK bytes from fd $1 into _bt_buf.  _bt_nul is set to 1
# when the block was terminated by a NUL byte.  Returns non-zero at end of
# file, with any trailing bytes still left in _bt_buf.
_bt_read() {
	if IFS= read -r -d '' -n "$_BT_BLOCK" _bt_buf <&"$1"; then
		# A short block means read stopped at the NUL delimiter; a full
		# one means it stopped at the byte limit and left the NUL alone.
		if [ "${#_bt_buf}" -lt "$_BT_BLOCK" ]; then
			_bt_nul=1
		else
			_bt_nul=0
		fi
		return 0
	fi
	_bt_nul=0
	return 1
}

# Copy the rest of fd $1 to standard output, byte for byte.
_bt_copy() {
	local _bt_buf _bt_nul
	while _bt_read "$1"; do
		printf '%s' "$_bt_buf"
		[ "$_bt_nul" = 1 ] && printf '\000'
	done
	printf '%s' "$_bt_buf"
	return 0
}

# Same, but writing every byte the instant it is read, for cat -u.
_bt_copy_unbuffered() {
	# read -N 1 silently discards NUL bytes, so byte-at-a-time has
	# to go through the same NUL delimited reader with a one byte
	# block: every byte is then written the moment it is read.
	local _BT_BLOCK=1
	_bt_copy "$1"
}

# Number of newlines in $1.  Sets _bt_n.
_bt_count() {
	local stripped=${1//$'\n'/}
	_bt_n=$(( ${#1} - ${#stripped} ))
}

# Offset just past the $2'th newline of $1.  Sets _bt_off, or returns
# non-zero if the string holds fewer than $2 newlines.  Binary search keeps
# this out of quadratic territory on long lines.
_bt_after_nl() {
	local s=$1 k=$2 lo=1 hi=${#1} mid
	_bt_off=0
	[ "$k" -le 0 ] && return 0
	[ "$hi" -gt 0 ] || return 1
	_bt_count "$s"
	[ "$_bt_n" -ge "$k" ] || return 1
	while [ "$lo" -lt "$hi" ]; do
		mid=$(( (lo + hi) / 2 ))
		_bt_count "${s:0:mid}"
		if [ "$_bt_n" -ge "$k" ]; then
			hi=$mid
		else
			lo=$(( mid + 1 ))
		fi
	done
	_bt_off=$lo
	return 0
}

# ---------------------------------------------------------------------------
# The retained tail of the input, held as _bt_seg: a NUL free string per
# element, the original bytes being seg[0] NUL seg[1] NUL ... NUL seg[n-1].
# ---------------------------------------------------------------------------

# Append a block read by _bt_read.  $1 is the text, $2 its NUL flag.
_bt_append() {
	local last=$(( ${#_bt_seg[@]} - 1 ))
	_bt_seg[last]+=$1
	[ "$2" = 1 ] && _bt_seg+=("")
	return 0
}

# Total byte length of the retained data.  Sets _bt_total.
_bt_len() {
	local i n=${#_bt_seg[@]}
	_bt_total=$(( n - 1 ))
	for (( i = 0; i < n; i++ )); do
		_bt_total=$(( _bt_total + ${#_bt_seg[i]} ))
	done
}

# Discard the leading $1 bytes of the retained data.
_bt_drop() {
	local drop=$1 len
	while [ "$drop" -gt 0 ]; do
		len=${#_bt_seg[0]}
		if [ "$drop" -lt "$len" ]; then
			_bt_seg[0]=${_bt_seg[0]:drop}
			return 0
		fi
		drop=$(( drop - len ))
		# Only one segment left, or the cut lands exactly on the NUL
		# that follows it -- either way nothing more can go.
		if [ "${#_bt_seg[@]}" -eq 1 ] || [ "$drop" -eq 0 ]; then
			_bt_seg[0]=
			return 0
		fi
		drop=$(( drop - 1 ))		# the separating NUL
		_bt_seg=("${_bt_seg[@]:1}")
	done
	return 0
}

# Discard everything before the last $1 newlines, keeping the bytes that
# follow them.  Walks back from the end so the cost tracks the output size,
# not the input size.
_bt_keep_lines() {
	local keep=$1 i m want t rest
	local seen=0
	for (( i = ${#_bt_seg[@]} - 1; i >= 0; i-- )); do
		want=$(( keep - seen ))
		t=${_bt_seg[i]}
		m=0
		# Peel whole lines off the end.  Removing the shortest
		# suffix that starts with a newline only ever scans back
		# across one line, so this costs a pass per kept line
		# rather than a pass over the whole segment.
		while [ "$m" -lt "$want" ]; do
			case $t in
			*$'\n'*)	t=${t%$'\n'*}; m=$(( m + 1 )) ;;
			*)		break ;;
			esac
		done
		# Cut inside this segment only when a newline is still
		# left to cut after; otherwise the retained line runs
		# back into an earlier segment.
		if [ "$m" -eq "$want" ]; then
			case $t in
			*$'\n'*)
				rest=${t##*$'\n'}
				_bt_seg=("${_bt_seg[@]:i}")
				_bt_seg[0]=${_bt_seg[0]:$(( ${#t} - ${#rest} ))}
				return 0 ;;
			esac
		fi
		seen=$(( seen + m ))
	done
	return 0
}

# Write the retained data out.
_bt_emit() {
	local i n=${#_bt_seg[@]}
	printf '%s' "${_bt_seg[0]}"
	for (( i = 1; i < n; i++ )); do
		printf '\000%s' "${_bt_seg[i]}"
	done
	return 0
}

# Pause for $1 seconds without sleep(1): a pipe opened for both reading and
# writing never reports end of file, so read -t waits out its timeout on it.
# The process substitution forks a subshell -- still no external program.
_bt_snore() {
	[ -n "${_bt_snore_fd:-}" ] || exec {_bt_snore_fd}<> <(:)
	local junk
	read -r -t "$1" -u "$_bt_snore_fd" junk
	return 0
}

# ---------------------------------------------------------------------------
# cat -- POSIX.1-2017: cat [-u] [file...]
# ---------------------------------------------------------------------------
cat () {
	local status=0 unbuffered=0 arg opt file fd _bt_reason

	# Option parsing follows the POSIX Utility Syntax Guidelines: "--"
	# ends the options, a lone "-" is an operand naming standard input.
	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-*)	arg=${1#-}
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				u)	unbuffered=1 ;;
				*)	_bt_err "cat: illegal option -- $opt"
					_bt_err "usage: cat [-u] [file...]"
					return 1 ;;
				esac
			done
			shift ;;
		*)	break ;;
		esac
	done

	# "If no file operands are specified, the standard input shall be
	# used."
	[ "$#" -eq 0 ] && set -- -

	for file in "$@"; do
		if [ "$file" = - ]; then
			if [ "$unbuffered" = 1 ]; then
				_bt_copy_unbuffered 0
			else
				_bt_copy 0
			fi
			continue
		fi
		# A directory opens happily on Linux and only fails on read, so
		# it is rejected up front.
		if [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "cat: $file: $_bt_reason"
			# "shall continue processing the remaining files"
			status=1
			continue
		fi
		if [ "$unbuffered" = 1 ]; then
			_bt_copy_unbuffered "$fd"
		else
			_bt_copy "$fd"
		fi
		exec {fd}<&-
	done

	return "$status"
}

# ---------------------------------------------------------------------------
# tail -- POSIX.1-2017: tail [-f] [-c number|-n number] [file]
# ---------------------------------------------------------------------------
tail () {
	local mode=lines count=10 from_start=0 follow=0
	local arg opt val file fd rc started skip len
	local endsnl total_nl i
	local _bt_buf _bt_nul _bt_total _bt_n _bt_off _bt_reason
	local -a _bt_seg=("")

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-[0-9]*)
			# Obsolescent historical form "tail -number", equivalent
			# to "tail -n number".  Dropped from the standard, but no
			# conforming usage can collide with it.
			val=${1#-}
			if ! _bt_isnum "$val"; then
				_bt_err "tail: invalid number: $val"
				return 1
			fi
			mode=lines
			from_start=0
			count=$val
			shift ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				f)	follow=1 ;;
				c|n)	# The option-argument may be attached to
					# the option or be the next argument.
					if [ -n "$arg" ]; then
						val=$arg
						arg=
					elif [ "$#" -gt 0 ]; then
						val=$1
						shift
					else
						_bt_err "tail: option requires an argument -- $opt"
						_bt_err "usage: tail [-f] [-c number|-n number] [file]"
						return 1
					fi
					if ! _bt_isnum "$val"; then
						_bt_err "tail: invalid number: $val"
						return 1
					fi
					if [ "$opt" = c ]; then
						mode=bytes
					else
						mode=lines
					fi
					# A leading '+' counts from the start of
					# the file, anything else from the end.
					case $val in
					+*)	from_start=1; count=${val#+} ;;
					-*)	from_start=0; count=${val#-} ;;
					*)	from_start=0; count=$val ;;
					esac ;;
				*)	_bt_err "tail: illegal option -- $opt"
					_bt_err "usage: tail [-f] [-c number|-n number] [file]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	# Base 10 explicitly: "010" is eight to bash arithmetic otherwise.
	count=$(( 10#$count ))

	# POSIX allows at most one file operand.
	if [ "$#" -gt 1 ]; then
		_bt_err "tail: extra operand: $2"
		_bt_err "usage: tail [-f] [-c number|-n number] [file]"
		return 1
	fi
	[ "$#" -eq 0 ] && set -- -
	file=$1

	if [ "$file" = - ]; then
		fd=0
		# "If no file operand is specified and standard input is a pipe
		# or FIFO, the -f option shall be ignored."
		[ -f /dev/fd/0 ] || follow=0
	else
		if [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "tail: $file: $_bt_reason"
			return 1
		fi
		# -f is defined for regular files and FIFOs; elsewhere it is
		# unspecified, and ignoring it beats spinning on a device.
		if [ ! -f "$file" ] && [ ! -p "$file" ]; then
			follow=0
		fi
	fi

	if [ "$from_start" = 1 ]; then
		# Counting from the start: skip, then copy the remainder.  "+0"
		# is historically the whole file.
		[ "$count" -lt 1 ] && count=1
		skip=$(( count - 1 ))
		started=0
		while :; do
			if _bt_read "$fd"; then rc=0; else rc=1; fi
			if [ "$started" = 1 ]; then
				printf '%s' "$_bt_buf"
			elif [ "$mode" = bytes ]; then
				len=${#_bt_buf}
				if [ "$skip" -lt "$len" ]; then
					printf '%s' "${_bt_buf:skip}"
					started=1
				else
					skip=$(( skip - len ))
					# The separating NUL is a byte too.
					if [ "$_bt_nul" = 1 ]; then
						if [ "$skip" -eq 0 ]; then
							started=1
						else
							skip=$(( skip - 1 ))
						fi
					fi
				fi
			else
				_bt_count "$_bt_buf"
				if [ "$_bt_n" -ge "$skip" ]; then
					_bt_after_nl "$_bt_buf" "$skip"
					printf '%s' "${_bt_buf:_bt_off}"
					started=1
				else
					skip=$(( skip - _bt_n ))
				fi
			fi
			[ "$started" = 1 ] && [ "$_bt_nul" = 1 ] && printf '\000'
			[ "$rc" = 1 ] && break
		done
	else
		# Counting from the end: keep a rolling window just big enough
		# for the answer, so memory tracks the output, not the input.
		while :; do
			if _bt_read "$fd"; then rc=0; else rc=1; fi
			# A count of zero selects nothing at all; still read
			# on, so that -f resumes from the end of the input.
			if [ "$count" -eq 0 ]; then
				[ "$rc" = 1 ] && break
				continue
			fi
			_bt_append "$_bt_buf" "$_bt_nul"
			if [ "$mode" = bytes ]; then
				_bt_len
				if [ "$_bt_total" -gt "$count" ]; then
					_bt_drop $(( _bt_total - count ))
				fi
			else
				_bt_keep_lines "$count"
			fi
			[ "$rc" = 1 ] && break
		done

		if [ "$mode" = lines ] && [ "$count" -gt 0 ]; then
			# An unterminated final line is a line of its own, so it
			# displaces one of the newline terminated ones.
			i=$(( ${#_bt_seg[@]} - 1 ))
			endsnl=0
			if [ -n "${_bt_seg[i]}" ] &&
			   [ "${_bt_seg[i]:${#_bt_seg[i]}-1}" = $'\n' ]; then
				endsnl=1
			fi
			if [ "$endsnl" = 0 ]; then
				total_nl=0
				for (( i = 0; i < ${#_bt_seg[@]}; i++ )); do
					_bt_count "${_bt_seg[i]}"
					total_nl=$(( total_nl + _bt_n ))
				done
				if [ "$total_nl" -ge "$count" ]; then
					_bt_keep_lines $(( count - 1 ))
				fi
			fi
		fi
		_bt_emit
	fi

	if [ "$follow" = 1 ]; then
		# "do not terminate after the last line of the input file has
		# been copied, but read and copy further bytes from the input
		# file when they become available"
		while :; do
			if _bt_read "$fd"; then
				printf '%s' "$_bt_buf"
				[ "$_bt_nul" = 1 ] && printf '\000'
			else
				printf '%s' "$_bt_buf"
				_bt_snore 1
			fi
		done
	fi

	[ "$fd" != 0 ] && exec {fd}<&-
	return 0
}


# ---------------------------------------------------------------------------
# id -- POSIX.1-2017:
#	id [user]
#	id -G [-n] [user]
#	id -g [-nr] [user]
#	id -u [-nr] [user]
# ---------------------------------------------------------------------------

# Overridable so the tests can point the lookups at fixture files.
_BT_PASSWD=/etc/passwd
_BT_GROUP=/etc/group

_bt_usage_id() {
	_bt_err "usage: id [user]"
	_bt_err "       id -G [-n] [user]"
	_bt_err "       id -g [-nr] [user]"
	_bt_err "       id -u [-nr] [user]"
}

# Look up a passwd entry: $1 is the value to match, $2 is "name" to match it
# against the login name or "uid" against the user ID.  Sets _bt_name,
# _bt_uid and _bt_gid; returns non-zero when there is no such entry.
_bt_passwd() {
	local want=$1 key=$2 name pw uid gid rest fd
	_bt_name= _bt_uid= _bt_gid=
	{ exec {fd}<"$_BT_PASSWD"; } 2>/dev/null || return 1
	# The trailing test catches a final entry with no newline.
	while IFS=: read -r name pw uid gid rest <&"$fd" || [ -n "$name" ]; do
		case $key in
		name)	[ "$name" = "$want" ] || continue ;;
		*)	[ "$uid" = "$want" ] || continue ;;
		esac
		_bt_name=$name _bt_uid=$uid _bt_gid=$gid
		exec {fd}<&-
		return 0
	done
	exec {fd}<&-
	return 1
}

# Group name for group ID $1.  Sets _bt_grname, left empty when the ID maps
# to no group.
_bt_group_name() {
	local name pw gid rest fd
	_bt_grname=
	{ exec {fd}<"$_BT_GROUP"; } 2>/dev/null || return 1
	while IFS=: read -r name pw gid rest <&"$fd" || [ -n "$name" ]; do
		[ "$gid" = "$1" ] || continue
		_bt_grname=$name
		exec {fd}<&-
		return 0
	done
	exec {fd}<&-
	return 1
}

# Every group user $1 belongs to: the primary group $2 first, then each group
# whose member list names the user.  Sets the _bt_gids array.
_bt_user_groups() {
	local user=$1 primary=$2 name pw gid members fd
	_bt_gids=("$primary")
	{ exec {fd}<"$_BT_GROUP"; } 2>/dev/null || return 0
	while IFS=: read -r name pw gid members <&"$fd" || [ -n "$name" ]; do
		[ "$gid" = "$primary" ] && continue
		case ,$members, in
		*,"$user",*)	_bt_gids+=("$gid") ;;
		esac
	done
	exec {fd}<&-
	return 0
}

# Real and effective IDs of this process, plus its supplementary groups.
# Linux publishes all of them in /proc/self/status; bash on its own exposes
# only $UID, $EUID and $GROUPS, which is the fallback.
_bt_self_ids() {
	local IFS=$' \t\n' key rest fd
	_bt_ruid=$UID _bt_euid=$EUID _bt_rgid= _bt_egid=
	_bt_supp=()
	if { exec {fd}</proc/self/status; } 2>/dev/null; then
		while read -r key rest <&"$fd" || [ -n "$key" ]; do
			case $key in
			Uid:)		set -- $rest; _bt_ruid=$1 _bt_euid=$2 ;;
			Gid:)		set -- $rest; _bt_rgid=$1 _bt_egid=$2 ;;
			Groups:)	set -- $rest; _bt_supp=("$@") ;;
			esac
		done
		exec {fd}<&-
	fi
	[ -n "$_bt_rgid" ] || _bt_rgid=${GROUPS[0]-}
	[ -n "$_bt_egid" ] || _bt_egid=${GROUPS[0]-}
	return 0
}

# Append $1 to the _bt_gids array unless it is already there.
_bt_add_gid() {
	[ -n "$1" ] || return 0
	case " ${_bt_gids[*]-} " in
	*" $1 "*)	return 0 ;;
	esac
	_bt_gids+=("$1")
	return 0
}

id () {
	local opt arg want= names=0 real=0 user= have_user=0
	local wid g i sep rc
	local _bt_name _bt_uid _bt_gid _bt_grname
	local _bt_ruid _bt_euid _bt_rgid _bt_egid
	local -a _bt_gids=() _bt_ggids=() _bt_supp=()
	local IFS=$' \t\n'

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				G|g|u)	if [ -n "$want" ] && [ "$want" != "$opt" ]; then
						_bt_err 'id: cannot print "only" of more than one choice'
						_bt_usage_id
						return 1
					fi
					want=$opt ;;
				n)	names=1 ;;
				r)	real=1 ;;
				a)	;;	# historical no-op, ignored as elsewhere
				*)	_bt_err "id: illegal option -- $opt"
					_bt_usage_id
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	# POSIX gives id a single optional operand.
	if [ "$#" -gt 1 ]; then
		_bt_err "id: extra operand: $2"
		_bt_usage_id
		return 1
	fi
	if [ "$#" -eq 1 ]; then
		user=$1
		have_user=1
	fi

	# "-n ... shall be used only with -G, -g or -u", and likewise -r.
	if [ -z "$want" ] && { [ "$names" = 1 ] || [ "$real" = 1 ]; }; then
		_bt_err "id: cannot print only names or real IDs in default format"
		_bt_usage_id
		return 1
	fi

	if [ "$have_user" = 1 ]; then
		# A login name, or failing that a user ID, as history requires.
		if ! _bt_passwd "$user" name; then
			case $user in
			''|*[!0-9]*)	;;
			*)		_bt_passwd "$user" uid ;;
			esac
		fi
		if [ -z "$_bt_uid" ]; then
			_bt_err "id: '$user': no such user"
			return 1
		fi
		# Named users have no real/effective distinction to report.
		_bt_ruid=$_bt_uid _bt_euid=$_bt_uid
		_bt_rgid=$_bt_gid _bt_egid=$_bt_gid
		_bt_user_groups "$_bt_name" "$_bt_gid"
		_bt_ggids=(${_bt_gids[@]+"${_bt_gids[@]}"})
	else
		_bt_self_ids
		# The two lists genuinely differ.  -G asks for the
		# effective, real and supplementary IDs alike...
		_bt_gids=()
		_bt_add_gid "$_bt_rgid"
		_bt_add_gid "$_bt_egid"
		for g in ${_bt_supp[@]+"${_bt_supp[@]}"}; do
			_bt_add_gid "$g"
		done
		_bt_ggids=(${_bt_gids[@]+"${_bt_gids[@]}"})
		# ...while the default format reports the supplementary
		# affiliations, with the effective group prepended when
		# it is not already among them.  The real group is not
		# part of that list.
		_bt_gids=()
		for g in ${_bt_supp[@]+"${_bt_supp[@]}"}; do
			_bt_add_gid "$g"
		done
		case " ${_bt_gids[*]-} " in
		*" $_bt_egid "*)	;;
		*)	_bt_gids=("$_bt_egid" ${_bt_gids[@]+"${_bt_gids[@]}"}) ;;
		esac
	fi

	case $want in
	u)	if [ "$real" = 1 ]; then wid=$_bt_ruid; else wid=$_bt_euid; fi
		if [ "$names" = 1 ] && ! _bt_passwd "$wid" uid; then
			# No name for the ID: report the number instead, and
			# still exit non-zero, as every other id does.
			_bt_err "id: cannot find name for user ID $wid"
			printf '%u\n' "$wid"
			return 1
		fi
		if [ "$names" = 1 ]; then
			printf '%s\n' "$_bt_name"
		else
			printf '%u\n' "$wid"
		fi
		return 0 ;;
	g)	if [ "$real" = 1 ]; then wid=$_bt_rgid; else wid=$_bt_egid; fi
		if [ "$names" = 1 ] && ! _bt_group_name "$wid"; then
			_bt_err "id: cannot find name for group ID $wid"
			printf '%u\n' "$wid"
			return 1
		fi
		if [ "$names" = 1 ]; then
			printf '%s\n' "$_bt_grname"
		else
			printf '%u\n' "$wid"
		fi
		return 0 ;;
	G)	# "%u", then " %u" for each further affiliation.
		sep=
		rc=0
		for g in ${_bt_ggids[@]+"${_bt_ggids[@]}"}; do
			if [ "$names" != 1 ]; then
				printf '%s%u' "$sep" "$g"
			elif _bt_group_name "$g"; then
				printf '%s%s' "$sep" "$_bt_grname"
			else
				_bt_err "id: cannot find name for group ID $g"
				printf '%s%u' "$sep" "$g"
				rc=1
			fi
			sep=' '
		done
		printf '\n'
		return "$rc" ;;
	esac

	# Default format: uid, gid, then euid and egid only when they differ
	# from the real ones, then the group affiliations.
	printf 'uid=%u' "$_bt_ruid"
	_bt_passwd "$_bt_ruid" uid && printf '(%s)' "$_bt_name"
	printf ' gid=%u' "$_bt_rgid"
	_bt_group_name "$_bt_rgid" && printf '(%s)' "$_bt_grname"
	if [ "$_bt_euid" != "$_bt_ruid" ]; then
		printf ' euid=%u' "$_bt_euid"
		_bt_passwd "$_bt_euid" uid && printf '(%s)' "$_bt_name"
	fi
	if [ "$_bt_egid" != "$_bt_rgid" ]; then
		printf ' egid=%u' "$_bt_egid"
		_bt_group_name "$_bt_egid" && printf '(%s)' "$_bt_grname"
	fi
	if [ "${#_bt_gids[@]}" -gt 0 ]; then
		printf ' groups='
		sep=
		for g in "${_bt_gids[@]}"; do
			printf '%s%u' "$sep" "$g"
			_bt_group_name "$g" && printf '(%s)' "$_bt_grname"
			sep=,
		done
	fi
	printf '\n'
	return 0
}
