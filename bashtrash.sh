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
	# Byte semantics: in a multibyte locale ${#s}, ${s:i:n} and
	# read -n all count characters, which would make every length
	# here wrong.  Restored on return.
	local LC_ALL=C
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
	local LC_ALL=C
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
	local LC_ALL=C
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

# ---------------------------------------------------------------------------
# basename -- POSIX.1-2017: basename string [suffix]
# ---------------------------------------------------------------------------
basename () {
	local LC_ALL=C s suffix=
	[ "$#" -gt 0 ] && [ "$1" = -- ] && shift
	if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
		_bt_err "usage: basename string [suffix]"
		return 1
	fi
	s=$1
	[ "$#" -eq 2 ] && suffix=$2
	case $s in
	'')	printf '\n'; return 0 ;;
	*[!/]*)	;;
	*)	printf '/\n'; return 0 ;;	# nothing but slashes
	esac
	s=${s%"${s##*[!/]}"}		# drop trailing slashes
	s=${s##*/}			# keep the last component
	# "If the suffix is identical to the remaining characters, it shall
	# not be removed."
	if [ -n "$suffix" ] && [ "$s" != "$suffix" ]; then
		s=${s%"$suffix"}
	fi
	printf '%s\n' "$s"
	return 0
}

# ---------------------------------------------------------------------------
# dirname -- POSIX.1-2017: dirname string
# ---------------------------------------------------------------------------
dirname () {
	local LC_ALL=C s
	[ "$#" -gt 0 ] && [ "$1" = -- ] && shift
	if [ "$#" -ne 1 ]; then
		_bt_err "usage: dirname string"
		return 1
	fi
	s=$1
	# The steps below are the ones the standard spells out, in order.
	case $s in
	'')	printf '.\n'; return 0 ;;
	*[!/]*)	;;
	*)	printf '/\n'; return 0 ;;	# nothing but slashes
	esac
	s=${s%"${s##*[!/]}"}		# trailing slashes
	case $s in
	*/*)	;;
	*)	printf '.\n'; return 0 ;;	# no slash left
	esac
	s=${s%"${s##*/}"}		# trailing non-slashes
	s=${s%"${s##*[!/]}"}		# trailing slashes again
	[ -n "$s" ] || s=/
	printf '%s\n' "$s"
	return 0
}

# ---------------------------------------------------------------------------
# head -- POSIX.1-2017: head [-n number] [file...]
# -c is the Issue 8 spelling of the long-standing extension.
# ---------------------------------------------------------------------------
head () {
	local LC_ALL=C mode=lines count=10 arg opt val file fd status=0
	local first=1 many=0 left rc len label _bt_reason
	local _bt_buf _bt_nul _bt_n _bt_off

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-[0-9]*)
			val=${1#-}
			_bt_isnum "$val" || { _bt_err "head: invalid number: $val"; return 1; }
			mode=lines count=$val
			shift ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				c|n)	if [ -n "$arg" ]; then
						val=$arg
						arg=
					elif [ "$#" -gt 0 ]; then
						val=$1
						shift
					else
						_bt_err "head: option requires an argument -- $opt"
						return 1
					fi
					_bt_isnum "$val" || { _bt_err "head: invalid number: $val"; return 1; }
					case $val in
					-*|+*)	val=${val#[-+]} ;;
					esac
					if [ "$opt" = c ]; then mode=bytes; else mode=lines; fi
					count=$val ;;
				*)	_bt_err "head: illegal option -- $opt"
					_bt_err "usage: head [-n number] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	count=$(( 10#$count ))

	[ "$#" -eq 0 ] && set -- -
	[ "$#" -gt 1 ] && many=1

	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
			label='standard input'
		else
			if [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
				_bt_why "$file"
				_bt_err "head: $file: $_bt_reason"
				status=1
				continue
			fi
			label=$file
		fi
		if [ "$many" = 1 ]; then
			[ "$first" = 1 ] || printf '\n'
			printf '==> %s <==\n' "$label"
		fi
		first=0

		left=$count
		while [ "$left" -gt 0 ]; do
			if _bt_read "$fd"; then rc=0; else rc=1; fi
			if [ "$mode" = lines ]; then
				_bt_count "$_bt_buf"
				if [ "$_bt_n" -ge "$left" ]; then
					_bt_after_nl "$_bt_buf" "$left"
					printf '%s' "${_bt_buf:0:_bt_off}"
					left=0
				else
					printf '%s' "$_bt_buf"
					[ "$_bt_nul" = 1 ] && printf '\000'
					left=$(( left - _bt_n ))
				fi
			else
				len=${#_bt_buf}
				if [ "$left" -le "$len" ]; then
					printf '%s' "${_bt_buf:0:left}"
					left=0
				else
					printf '%s' "$_bt_buf"
					left=$(( left - len ))
					# the separating NUL is a byte of its own
					if [ "$_bt_nul" = 1 ] && [ "$left" -gt 0 ]; then
						printf '\000'
						left=$(( left - 1 ))
					fi
				fi
			fi
			[ "$rc" = 1 ] && break
		done
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# tee -- POSIX.1-2017: tee [-ai] [file...]
# ---------------------------------------------------------------------------
tee () {
	local LC_ALL=C append=0 ignore=0 arg opt f fd status=0 saved=
	local -a fds=()
	local _bt_buf _bt_nul _bt_reason

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
				a)	append=1 ;;
				i)	ignore=1 ;;
				*)	_bt_err "tee: illegal option -- $opt"
					_bt_err "usage: tee [-ai] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	if [ "$ignore" = 1 ]; then
		saved=$(trap -p INT)
		trap '' INT
	fi

	for f in "$@"; do
		if [ "$append" = 1 ]; then
			{ exec {fd}>>"$f"; } 2>/dev/null
		else
			{ exec {fd}>"$f"; } 2>/dev/null
		fi
		if [ "$?" = 0 ]; then
			fds+=("$fd")
		else
			_bt_why "$f"
			_bt_err "tee: $f: $_bt_reason"
			status=1
		fi
	done

	while _bt_read 0; do
		printf '%s' "$_bt_buf"
		[ "$_bt_nul" = 1 ] && printf '\000'
		for fd in ${fds[@]+"${fds[@]}"}; do
			printf '%s' "$_bt_buf" >&"$fd"
			[ "$_bt_nul" = 1 ] && printf '\000' >&"$fd"
		done
	done
	printf '%s' "$_bt_buf"
	for fd in ${fds[@]+"${fds[@]}"}; do
		printf '%s' "$_bt_buf" >&"$fd"
		exec {fd}>&-
	done

	if [ "$ignore" = 1 ]; then
		if [ -n "$saved" ]; then eval "$saved"; else trap - INT; fi
	fi
	return "$status"
}

# ---------------------------------------------------------------------------
# sleep -- POSIX.1-2017: sleep time
# ---------------------------------------------------------------------------
sleep () {
	local LC_ALL=C t
	if [ "$#" -ne 1 ]; then
		_bt_err "usage: sleep time"
		return 1
	fi
	t=$1
	# POSIX asks for a non-negative decimal integer; a fraction is the
	# usual extension and read -t takes one directly.
	case $t in
	''|*[!0-9.]*)	_bt_err "sleep: invalid time interval: $t"; return 1 ;;
	*.*.*)		_bt_err "sleep: invalid time interval: $t"; return 1 ;;
	.)		_bt_err "sleep: invalid time interval: $t"; return 1 ;;
	esac
	_bt_snore "$t"
	return 0
}

# ---------------------------------------------------------------------------
# tty -- POSIX.1-2017: tty
# ---------------------------------------------------------------------------
tty () {
	local LC_ALL=C d
	if [ "$#" -gt 0 ]; then
		_bt_err "tty: extra operand: $1"
		return 1
	fi
	if [ ! -t 0 ]; then
		printf 'not a tty\n'
		return 1
	fi
	# ttyname() is not reachable, but the device can be identified by
	# comparing device and inode against what fd 0 points at.
	for d in /dev/pts/[0-9]* /dev/tty[0-9]* /dev/ttyS[0-9]* /dev/console /dev/tty; do
		[ -c "$d" ] || continue
		if [ "$d" -ef /proc/self/fd/0 ]; then
			printf '%s\n' "$d"
			return 0
		fi
	done
	printf 'not a tty\n'
	return 1
}

# ---------------------------------------------------------------------------
# uname -- POSIX.1-2017: uname [-amnrsv]
#
# Note that -a here is the standard's -a, which is exactly -mnrsv; GNU adds
# processor, hardware platform and operating system to its own -a.
# ---------------------------------------------------------------------------
uname () {
	local LC_ALL=C arg opt sep= out=
	local want_s=0 want_n=0 want_r=0 want_v=0 want_m=0 any=0
	local sysname nodename release version machine

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-*)	[ "$1" = - ] && break
			arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				a)	want_s=1 want_n=1 want_r=1 want_v=1 want_m=1 ;;
				s)	want_s=1 ;;
				n)	want_n=1 ;;
				r)	want_r=1 ;;
				v)	want_v=1 ;;
				m)	want_m=1 ;;
				*)	_bt_err "uname: illegal option -- $opt"
					_bt_err "usage: uname [-amnrsv]"
					return 1 ;;
				esac
				any=1
			done ;;
		*)	break ;;
		esac
	done
	if [ "$#" -gt 0 ]; then
		_bt_err "uname: extra operand: $1"
		return 1
	fi
	[ "$any" = 1 ] || want_s=1

	IFS= read -r sysname  < /proc/sys/kernel/ostype    2>/dev/null || sysname=unknown
	IFS= read -r nodename < /proc/sys/kernel/hostname  2>/dev/null || nodename=unknown
	IFS= read -r release  < /proc/sys/kernel/osrelease 2>/dev/null || release=unknown
	IFS= read -r version  < /proc/sys/kernel/version   2>/dev/null || version=unknown
	# uname(2) is out of reach; bash records the build machine type.
	machine=${HOSTTYPE:-unknown}

	[ "$want_s" = 1 ] && { out=$sysname; sep=' '; }
	[ "$want_n" = 1 ] && { out=$out$sep$nodename; sep=' '; }
	[ "$want_r" = 1 ] && { out=$out$sep$release; sep=' '; }
	[ "$want_v" = 1 ] && { out=$out$sep$version; sep=' '; }
	[ "$want_m" = 1 ] && { out=$out$sep$machine; sep=' '; }
	printf '%s\n' "$out"
	return 0
}

# ---------------------------------------------------------------------------
# wc -- POSIX.1-2017: wc [-c|-m] [-lw] [file...]
#
# The counts are gathered for every input before anything is written, because
# the column width depends on the total size of the regular-file inputs and
# stat() is not reachable from a builtin -- the bytes have to be counted to
# be known.
# ---------------------------------------------------------------------------

# Count newlines, words and bytes on fd $1 into _bt_lines/_bt_words/_bt_bytes.
_bt_wc_count() {
	local fd=$1 len nw prev=0 rc t
	_bt_lines=0 _bt_words=0 _bt_bytes=0
	while :; do
		if _bt_read "$fd"; then rc=0; else rc=1; fi
		len=${#_bt_buf}
		if [ "$len" -gt 0 ]; then
			_bt_bytes=$(( _bt_bytes + len ))
			_bt_count "$_bt_buf"
			_bt_lines=$(( _bt_lines + _bt_n ))
			# IFS splitting treats only space, tab and newline as
			# collapsing whitespace, so fold the other blanks in
			# before counting words.
			case $_bt_buf in
			*[$'\v\f\r']*)	t=${_bt_buf//[$'\v\f\r']/ } ;;
			*)		t=$_bt_buf ;;
			esac
			set -- $t
			nw=$#
			if [ "$nw" -gt 0 ]; then
				# A word split across a block boundary is one
				# word, not two.
				case $_bt_buf in
				[![:space:]]*)	[ "$prev" = 1 ] && nw=$(( nw - 1 )) ;;
				esac
				_bt_words=$(( _bt_words + nw ))
			fi
			case $_bt_buf in
			*[![:space:]])	prev=1 ;;
			*)		prev=0 ;;
			esac
		fi
		if [ "$rc" = 0 ] && [ "$_bt_nul" = 1 ]; then
			# the separating NUL is a byte, and not a space
			_bt_bytes=$(( _bt_bytes + 1 ))
			[ "$prev" = 0 ] && _bt_words=$(( _bt_words + 1 ))
			prev=1
		fi
		[ "$rc" = 1 ] && break
	done
	return 0
}

wc () {
	local _bt_lc=${LC_ALL-}
	local LC_ALL=C IFS=$' \t\n'
	local arg opt file fd status=0 i n tmp out width=1 ncols
	local want_l=0 want_w=0 want_c=0 want_m=0 any=0
	local reg_total=0 nonregular=0 ninputs
	local tot_l=0 tot_w=0 tot_c=0
	local -a cl=() cw=() cc=() names=()
	local _bt_buf _bt_nul _bt_n _bt_lines _bt_words _bt_bytes _bt_reason

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
				l)	want_l=1 any=1 ;;
				w)	want_w=1 any=1 ;;
				c)	want_c=1 want_m=0 any=1 ;;
				m)	want_m=1 want_c=0 any=1 ;;
				*)	_bt_err "wc: illegal option -- $opt"
					_bt_err "usage: wc [-c|-m] [-lw] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$any" = 0 ]; then
		want_l=1 want_w=1 want_c=1
	fi
	ncols=$(( want_l + want_w + want_c + want_m ))
	# -m counts characters, so that path needs the caller's locale back.
	[ "$want_m" = 1 ] && LC_ALL=$_bt_lc

	[ "$#" -eq 0 ] && set -- -
	ninputs=$#

	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
			names+=('')
			if [ -f /dev/fd/0 ]; then :; else nonregular=1; fi
		else
			if [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
				_bt_why "$file"
				_bt_err "wc: $file: $_bt_reason"
				status=1
				continue
			fi
			names+=("$file")
			[ -f "$file" ] || nonregular=1
		fi
		_bt_wc_count "$fd"
		[ "$fd" = 0 ] || exec {fd}<&-
		cl+=("$_bt_lines"); cw+=("$_bt_words"); cc+=("$_bt_bytes")
		tot_l=$(( tot_l + _bt_lines ))
		tot_w=$(( tot_w + _bt_words ))
		tot_c=$(( tot_c + _bt_bytes ))
		if [ "$file" = - ]; then
			[ -f /dev/fd/0 ] && reg_total=$(( reg_total + _bt_bytes ))
		else
			[ -f "$file" ] && reg_total=$(( reg_total + _bt_bytes ))
		fi
	done

	# One count for one input needs no alignment; otherwise the width comes
	# from the combined size of the regular files, and anything whose size
	# cannot be known in advance forces the historical minimum of 7.
	if [ "$ncols" = 1 ] && [ "$ninputs" = 1 ]; then
		width=1
	else
		width=1
		n=$reg_total
		while [ "$n" -ge 10 ]; do
			n=$(( n / 10 ))
			width=$(( width + 1 ))
		done
		[ "$nonregular" = 1 ] && [ "$width" -lt 7 ] && width=7
	fi

	for (( i = 0; i < ${#cl[@]}; i++ )); do
		out=
		if [ "$want_l" = 1 ]; then printf -v tmp '%*d' "$width" "${cl[i]}"; out=$tmp; fi
		if [ "$want_w" = 1 ]; then printf -v tmp '%*d' "$width" "${cw[i]}"; out=${out:+$out }$tmp; fi
		if [ "$want_c" = 1 ] || [ "$want_m" = 1 ]; then
			printf -v tmp '%*d' "$width" "${cc[i]}"; out=${out:+$out }$tmp
		fi
		if [ -n "${names[i]}" ]; then
			printf '%s %s\n' "$out" "${names[i]}"
		else
			printf '%s\n' "$out"
		fi
	done
	if [ "${#cl[@]}" -gt 1 ]; then
		out=
		if [ "$want_l" = 1 ]; then printf -v tmp '%*d' "$width" "$tot_l"; out=$tmp; fi
		if [ "$want_w" = 1 ]; then printf -v tmp '%*d' "$width" "$tot_w"; out=${out:+$out }$tmp; fi
		if [ "$want_c" = 1 ] || [ "$want_m" = 1 ]; then
			printf -v tmp '%*d' "$width" "$tot_c"; out=${out:+$out }$tmp
		fi
		printf '%s total\n' "$out"
	fi
	return "$status"
}

# ---------------------------------------------------------------------------
# uniq -- POSIX.1-2017: uniq [-c|-d|-u] [-f fields] [-s chars] [input [output]]
# ---------------------------------------------------------------------------

# The comparison key: skip $2 fields, then $3 characters, of line $1.
# A field is leading blanks followed by non-blanks.
_bt_uniq_key() {
	local s=$1 f=$2 c=$3 i
	for (( i = 0; i < f; i++ )); do
		s=${s#"${s%%[![:blank:]]*}"}	# leading blanks
		s=${s#"${s%%[[:blank:]]*}"}	# the field itself
	done
	[ "$c" -gt 0 ] && s=${s:c}
	_bt_key=$s
}

uniq () {
	local LC_ALL=C
	local arg opt val fields=0 chars=0 show_c=0 only_d=0 only_u=0
	local infd=0 outfd=1 opened_in=0 opened_out=0
	local line key prevline prevkey n=0 have=0 rc _bt_key _bt_reason

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-[0-9]*)	# obsolescent "-n" meaning -f n
			val=${1#-}
			_bt_isnum "$val" || { _bt_err "uniq: invalid number: $val"; return 1; }
			fields=$val
			shift ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				c)	show_c=1 ;;
				d)	only_d=1 ;;
				u)	only_u=1 ;;
				f|s)	if [ -n "$arg" ]; then
						val=$arg
						arg=
					elif [ "$#" -gt 0 ]; then
						val=$1
						shift
					else
						_bt_err "uniq: option requires an argument -- $opt"
						return 1
					fi
					_bt_isnum "$val" || { _bt_err "uniq: invalid number: $val"; return 1; }
					if [ "$opt" = f ]; then fields=$val; else chars=$val; fi ;;
				*)	_bt_err "uniq: illegal option -- $opt"
					_bt_err "usage: uniq [-c|-d|-u] [-f fields] [-s chars] [input [output]]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	fields=$(( 10#$fields )); chars=$(( 10#$chars ))

	if [ "$#" -gt 2 ]; then
		_bt_err "uniq: extra operand: $3"
		return 1
	fi
	if [ "$#" -ge 1 ] && [ "$1" != - ]; then
		if [ -d "$1" ] || ! { exec {infd}<"$1"; } 2>/dev/null; then
			_bt_why "$1"
			_bt_err "uniq: $1: $_bt_reason"
			return 1
		fi
		opened_in=1
	fi
	if [ "$#" -eq 2 ] && [ "$2" != - ]; then
		if ! { exec {outfd}>"$2"; } 2>/dev/null; then
			_bt_why "$2"
			_bt_err "uniq: $2: $_bt_reason"
			[ "$opened_in" = 1 ] && exec {infd}<&-
			return 1
		fi
		opened_out=1
	fi

	# Emit the group that just ended.
	_bt_uniq_flush() {
		[ "$have" = 1 ] || return 0
		if [ "$only_d" = 1 ] && [ "$n" -le 1 ]; then return 0; fi
		if [ "$only_u" = 1 ] && [ "$n" -gt 1 ]; then return 0; fi
		if [ "$show_c" = 1 ]; then
			printf '%7d %s\n' "$n" "$prevline" >&"$outfd"
		else
			printf '%s\n' "$prevline" >&"$outfd"
		fi
		return 0
	}

	while IFS= read -r line <&"$infd" || [ -n "$line" ]; do
		_bt_uniq_key "$line" "$fields" "$chars"
		key=$_bt_key
		if [ "$have" = 1 ] && [ "$key" = "$prevkey" ]; then
			n=$(( n + 1 ))
		else
			_bt_uniq_flush
			prevline=$line prevkey=$key n=1 have=1
		fi
		line=
	done
	_bt_uniq_flush
	unset -f _bt_uniq_flush

	[ "$opened_in" = 1 ] && exec {infd}<&-
	[ "$opened_out" = 1 ] && exec {outfd}>&-
	return 0
}

# ---------------------------------------------------------------------------
# Shared helpers for the line oriented utilities.
# ---------------------------------------------------------------------------

# Parse a cut/expand style list of numbers and ranges into _bt_lo/_bt_hi,
# sorted and with overlaps merged.  A high end of 0 means "to the end".
_bt_ranges() {
	local list=$1 item lo hi i j n hadf=0
	_bt_lo=() _bt_hi=()
	case $- in *f*) hadf=1 ;; esac
	set -f
	local IFS=', '
	set -- $list
	for item in "$@"; do
		case $item in
		-*-*|*-*-*)	_bt_rangeerr=$item; [ "$hadf" = 1 ] || set +f; return 1 ;;
		*-*)		lo=${item%%-*}; hi=${item#*-}
				[ -n "$lo" ] || lo=1
				[ -n "$hi" ] || hi=0 ;;
		*)		lo=$item; hi=$item ;;
		esac
		case $lo$hi in
		''|*[!0-9]*)	_bt_rangeerr=$item; [ "$hadf" = 1 ] || set +f; return 1 ;;
		esac
		lo=$(( 10#$lo )); [ "$hi" = 0 ] || hi=$(( 10#$hi ))
		[ "$lo" -ge 1 ] || { _bt_rangeerr=$item; [ "$hadf" = 1 ] || set +f; return 1; }
		_bt_lo+=("$lo"); _bt_hi+=("$hi")
	done
	[ "$hadf" = 1 ] || set +f

	# insertion sort by low end, then merge
	n=${#_bt_lo[@]}
	for (( i = 1; i < n; i++ )); do
		lo=${_bt_lo[i]} hi=${_bt_hi[i]} j=$(( i - 1 ))
		while [ "$j" -ge 0 ] && [ "${_bt_lo[j]}" -gt "$lo" ]; do
			_bt_lo[j+1]=${_bt_lo[j]}; _bt_hi[j+1]=${_bt_hi[j]}
			j=$(( j - 1 ))
		done
		_bt_lo[j+1]=$lo; _bt_hi[j+1]=$hi
	done
	local -a mlo=() mhi=()
	for (( i = 0; i < n; i++ )); do
		if [ "${#mlo[@]}" -gt 0 ]; then
			j=$(( ${#mlo[@]} - 1 ))
			if [ "${mhi[j]}" = 0 ]; then continue; fi
			if [ "${_bt_lo[i]}" -le $(( ${mhi[j]} + 1 )) ]; then
				if [ "${_bt_hi[i]}" = 0 ]; then
					mhi[j]=0
				elif [ "${_bt_hi[i]}" -gt "${mhi[j]}" ]; then
					mhi[j]=${_bt_hi[i]}
				fi
				continue
			fi
		fi
		mlo+=("${_bt_lo[i]}"); mhi+=("${_bt_hi[i]}")
	done
	_bt_lo=(${mlo[@]+"${mlo[@]}"}); _bt_hi=(${mhi[@]+"${mhi[@]}"})
	return 0
}

# Split $1 on the single character $2 into the _bt_fld array, keeping empty
# fields -- word splitting drops a trailing one, so a sentinel is appended
# and then discarded.
_bt_split() {
	local s=$1 d=$2 hadf=0
	case $- in *f*) hadf=1 ;; esac
	set -f
	local IFS=$d
	set -- "$s$d"x
	set -- $1
	_bt_fld=("${@:1:$#-1}")
	[ "$hadf" = 1 ] || set +f
	return 0
}

# ---------------------------------------------------------------------------
# cut -- POSIX.1-2017:
#	cut -b list [-n] [file...]
#	cut -c list [-n] [file...]
#	cut -f list [-d delim] [-s] [file...]
# ---------------------------------------------------------------------------
cut () {
	local LC_ALL=C
	local arg opt val mode= list= delim=$'\t' suppress=0 file fd status=0
	local line i lo hi out nf first _bt_rangeerr _bt_reason
	local -a _bt_lo=() _bt_hi=() _bt_fld=()

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
				b|c|f)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "cut: option requires an argument -- $opt"
						return 1
					fi
					mode=$opt list=$val ;;
				d)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "cut: option requires an argument -- $opt"
						return 1
					fi
					delim=$val ;;
				s)	suppress=1 ;;
				n)	;;	# -b only, and a no-op without multibyte splitting
				*)	_bt_err "cut: illegal option -- $opt"
					_bt_err "usage: cut -b list [-n] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	if [ -z "$mode" ]; then
		_bt_err "cut: you must specify a list of bytes, characters, or fields"
		return 1
	fi
	if ! _bt_ranges "$list"; then
		_bt_err "cut: invalid byte, character or field list: $_bt_rangeerr"
		return 1
	fi
	if [ "${#_bt_lo[@]}" -eq 0 ]; then
		_bt_err "cut: invalid byte, character or field list"
		return 1
	fi

	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "cut: $file: $_bt_reason"
			status=1
			continue
		fi
		line=
		while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
			out= first=1
			if [ "$mode" = f ]; then
				case $line in
				*"$delim"*)	;;
				*)	# a line with no delimiter is passed
					# through, or dropped under -s
					[ "$suppress" = 1 ] || printf '%s\n' "$line"
					line=
					continue ;;
				esac
				_bt_split "$line" "$delim"
				nf=${#_bt_fld[@]}
				for (( i = 0; i < ${#_bt_lo[@]}; i++ )); do
					lo=${_bt_lo[i]}; hi=${_bt_hi[i]}
					[ "$hi" = 0 ] && hi=$nf
					[ "$hi" -gt "$nf" ] && hi=$nf
					while [ "$lo" -le "$hi" ]; do
						# An empty field is still a field, so
						# the separator cannot be driven off
						# whether anything has accumulated.
						if [ "$first" = 1 ]; then
							out=${_bt_fld[lo-1]}
							first=0
						else
							out=$out$delim${_bt_fld[lo-1]}
						fi
						lo=$(( lo + 1 ))
					done
				done
			else
				for (( i = 0; i < ${#_bt_lo[@]}; i++ )); do
					lo=${_bt_lo[i]}; hi=${_bt_hi[i]}
					if [ "$hi" = 0 ]; then
						out=$out${line:lo-1}
					else
						out=$out${line:lo-1:hi-lo+1}
					fi
				done
			fi
			printf '%s\n' "$out"
			line=
		done
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# comm -- POSIX.1-2017: comm [-123] file1 file2
# ---------------------------------------------------------------------------
comm () {
	local LC_ALL=C
	local arg opt c1=1 c2=1 c3=1 fd1 fd2 l1 l2 h1 h2 p1 p2 p3 _bt_reason

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-[123]*)
			arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				1)	c1=0 ;;
				2)	c2=0 ;;
				3)	c3=0 ;;
				*)	_bt_err "comm: illegal option -- $opt"
					return 1 ;;
				esac
			done ;;
		-*)	_bt_err "comm: illegal option -- ${1#-}"
			_bt_err "usage: comm [-123] file1 file2"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ "$#" -ne 2 ]; then
		_bt_err "usage: comm [-123] file1 file2"
		return 1
	fi

	if [ "$1" = - ]; then
		fd1=0
	elif [ -d "$1" ] || ! { exec {fd1}<"$1"; } 2>/dev/null; then
		_bt_why "$1"; _bt_err "comm: $1: $_bt_reason"; return 1
	fi
	if [ "$2" = - ]; then
		fd2=0
	elif [ -d "$2" ] || ! { exec {fd2}<"$2"; } 2>/dev/null; then
		_bt_why "$2"; _bt_err "comm: $2: $_bt_reason"
		[ "$fd1" = 0 ] || exec {fd1}<&-
		return 1
	fi

	# The prefix for a column is one tab per column printed before it.
	p1=
	p2=; [ "$c1" = 1 ] && p2=$'\t'
	p3=; [ "$c1" = 1 ] && p3=$'\t'
	[ "$c2" = 1 ] && p3=$p3$'\t'

	l1= l2=
	if IFS= read -r l1 <&"$fd1" || [ -n "$l1" ]; then h1=1; else h1=0; fi
	if IFS= read -r l2 <&"$fd2" || [ -n "$l2" ]; then h2=1; else h2=0; fi
	while [ "$h1" = 1 ] || [ "$h2" = 1 ]; do
		if [ "$h1" = 1 ] && [ "$h2" = 1 ] && [ "$l1" = "$l2" ]; then
			[ "$c3" = 1 ] && printf '%s%s\n' "$p3" "$l1"
			l1= l2=
			if IFS= read -r l1 <&"$fd1" || [ -n "$l1" ]; then h1=1; else h1=0; fi
			if IFS= read -r l2 <&"$fd2" || [ -n "$l2" ]; then h2=1; else h2=0; fi
		elif [ "$h2" = 0 ] || { [ "$h1" = 1 ] && [ "$l1" '<' "$l2" ]; }; then
			[ "$c1" = 1 ] && printf '%s%s\n' "$p1" "$l1"
			l1=
			if IFS= read -r l1 <&"$fd1" || [ -n "$l1" ]; then h1=1; else h1=0; fi
		else
			[ "$c2" = 1 ] && printf '%s%s\n' "$p2" "$l2"
			l2=
			if IFS= read -r l2 <&"$fd2" || [ -n "$l2" ]; then h2=1; else h2=0; fi
		fi
	done

	[ "$fd1" = 0 ] || exec {fd1}<&-
	[ "$fd2" = 0 ] || exec {fd2}<&-
	return 0
}

# ---------------------------------------------------------------------------
# paste -- POSIX.1-2017: paste [-s] [-d list] file...
# ---------------------------------------------------------------------------
paste () {
	local LC_ALL=C
	local arg opt val serial=0 dlist=$'\t' file i n di line out any status=0
	local -a fds=() alive=() delims=()
	local _bt_reason

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
				s)	serial=1 ;;
				d)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "paste: option requires an argument -- d"
						return 1
					fi
					dlist=$val ;;
				*)	_bt_err "paste: illegal option -- $opt"
					_bt_err "usage: paste [-s] [-d list] file..."
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	[ "$#" -eq 0 ] && set -- -

	# The delimiter list, with escapes expanded; an empty list means none.
	delims=()
	i=0
	while [ "$i" -lt "${#dlist}" ]; do
		di=${dlist:i:1}
		if [ "$di" = '\' ] && [ $(( i + 1 )) -lt "${#dlist}" ]; then
			i=$(( i + 1 ))
			case ${dlist:i:1} in
			n)	di=$'\n' ;;
			t)	di=$'\t' ;;
			0)	di= ;;
			'\')	di='\' ;;
			*)	di=${dlist:i:1} ;;
			esac
		fi
		delims+=("$di")
		i=$(( i + 1 ))
	done
	[ "${#delims[@]}" -gt 0 ] || delims=($'\t')

	for file in "$@"; do
		if [ "$file" = - ]; then
			fds+=(0)
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "paste: $file: $_bt_reason"
			status=1
			continue
		else
			fds+=("$fd")
		fi
		alive+=(1)
	done
	n=${#fds[@]}
	[ "$n" -gt 0 ] || return "$status"

	if [ "$serial" = 1 ]; then
		for (( i = 0; i < n; i++ )); do
			out= any=0 di=0 line=
			while IFS= read -r line <&"${fds[i]}" || [ -n "$line" ]; do
				if [ "$any" = 1 ]; then
					out=$out${delims[di]}
					di=$(( (di + 1) % ${#delims[@]} ))
				fi
				out=$out$line
				any=1
				line=
			done
			[ "$any" = 1 ] && printf '%s\n' "$out"
			[ "${fds[i]}" = 0 ] || exec {fds[i]}<&-
		done
		return "$status"
	fi

	while :; do
		out= any=0 di=0
		for (( i = 0; i < n; i++ )); do
			[ "$i" -gt 0 ] && { out=$out${delims[di]}; di=$(( (di + 1) % ${#delims[@]} )); }
			if [ "${alive[i]}" = 1 ]; then
				line=
				if IFS= read -r line <&"${fds[i]}" || [ -n "$line" ]; then
					out=$out$line
					any=1
				else
					alive[i]=0
				fi
			fi
		done
		[ "$any" = 1 ] || break
		printf '%s\n' "$out"
	done
	for (( i = 0; i < n; i++ )); do
		[ "${fds[i]}" = 0 ] || exec {fds[i]}<&-
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# fold -- POSIX.1-2017: fold [-bs] [-w width] [file...]
# ---------------------------------------------------------------------------
fold () {
	local LC_ALL=C
	local arg opt val width=80 bytes=0 spaces=0 file fd status=0
	local line i c col start seg brk _bt_reason

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-[0-9]*)	width=${1#-}
			_bt_isnum "$width" || { _bt_err "fold: invalid width: $width"; return 1; }
			shift ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				b)	bytes=1 ;;
				s)	spaces=1 ;;
				w)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "fold: option requires an argument -- w"
						return 1
					fi
					_bt_isnum "$val" || { _bt_err "fold: invalid width: $val"; return 1; }
					width=$val ;;
				*)	_bt_err "fold: illegal option -- $opt"
					_bt_err "usage: fold [-bs] [-w width] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	width=$(( 10#$width ))
	if [ "$width" -lt 1 ]; then
		_bt_err "fold: invalid width: $width"
		return 1
	fi

	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "fold: $file: $_bt_reason"
			status=1
			continue
		fi
		line=
		while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
			start=0 col=0
			for (( i = 0; i < ${#line}; i++ )); do
				c=${line:i:1}
				if [ "$bytes" = 1 ]; then
					col=$(( col + 1 ))
				else
					# Width is measured in display columns
					# unless -b is given.
					case $c in
					$'\b')	[ "$col" -gt 0 ] && col=$(( col - 1 )) ;;
					$'\r')	col=0 ;;
					$'\t')	col=$(( col + 8 - col % 8 )) ;;
					*)	col=$(( col + 1 )) ;;
					esac
				fi
				if [ "$col" -gt "$width" ]; then
					brk=$i
					if [ "$spaces" = 1 ]; then
						seg=${line:start:i-start}
						case $seg in
						*[$' \t']*)
							seg=${seg%"${seg##*[$' \t']}"}
							brk=$(( start + ${#seg} )) ;;
						esac
					fi
					[ "$brk" -gt "$start" ] || brk=$i
					# A character that overflows the width all by
					# itself still has to be emitted, or the line
					# never advances.
					[ "$brk" -gt "$start" ] || brk=$(( start + 1 ))
					printf '%s\n' "${line:start:brk-start}"
					start=$brk
					col=0
					i=$(( brk - 1 ))
				fi
			done
			printf '%s\n' "${line:start}"
			line=
		done
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# expand / unexpand -- POSIX.1-2017:
#	expand [-t tablist] [file...]
#	unexpand [-a] [-t tablist] [file...]
# ---------------------------------------------------------------------------

# Parse a tab list into _bt_stops.  A single number means "every n columns",
# which is recorded as _bt_tabevery; an explicit list leaves that at 0.
_bt_tablist() {
	local list=$1 item prev=0 hadf=0
	_bt_stops=() _bt_tabevery=0
	case $- in *f*) hadf=1 ;; esac
	set -f
	local IFS=', '
	set -- $list
	for item in "$@"; do
		case $item in
		''|*[!0-9]*)	_bt_rangeerr=$item; [ "$hadf" = 1 ] || set +f; return 1 ;;
		esac
		item=$(( 10#$item ))
		[ "$item" -gt "$prev" ] || { _bt_rangeerr=$item; [ "$hadf" = 1 ] || set +f; return 1; }
		prev=$item
		_bt_stops+=("$item")
	done
	[ "$hadf" = 1 ] || set +f
	[ "${#_bt_stops[@]}" -gt 0 ] || return 1
	if [ "${#_bt_stops[@]}" -eq 1 ]; then
		_bt_tabevery=${_bt_stops[0]}
		_bt_stops=()
	fi
	return 0
}

# The next tab stop strictly after column $1.  Past the last listed stop a
# tab is worth a single column, which is what every expand does.
_bt_nextstop() {
	local col=$1 s
	_bt_stop_real=1
	if [ "$_bt_tabevery" -gt 0 ]; then
		_bt_stop=$(( col / _bt_tabevery * _bt_tabevery + _bt_tabevery ))
		return 0
	fi
	for s in ${_bt_stops[@]+"${_bt_stops[@]}"}; do
		if [ "$s" -gt "$col" ]; then
			_bt_stop=$s
			return 0
		fi
	done
	# Past the last listed stop a tab is worth a single column.
	_bt_stop=$(( col + 1 ))
	_bt_stop_real=0
	return 0
}

expand () {
	local LC_ALL=C
	local arg opt val file fd status=0 line i c col out pad
	local -a _bt_stops=()
	local _bt_tabevery=8 _bt_stop _bt_stop_real _bt_rangeerr _bt_reason

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-[0-9]*)	# obsolescent "expand -8"
			if ! _bt_tablist "${1#-}"; then
				_bt_err "expand: invalid tab size: ${1#-}"
				return 1
			fi
			shift ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				t)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "expand: option requires an argument -- t"
						return 1
					fi
					if ! _bt_tablist "$val"; then
						_bt_err "expand: invalid tab size: $_bt_rangeerr"
						return 1
					fi ;;
				i)	;;	# GNU: leading blanks only; accepted, not honoured
				*)	_bt_err "expand: illegal option -- $opt"
					_bt_err "usage: expand [-t tablist] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "expand: $file: $_bt_reason"
			status=1
			continue
		fi
		line=
		while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
			out= col=0
			for (( i = 0; i < ${#line}; i++ )); do
				c=${line:i:1}
				case $c in
				$'\t')	_bt_nextstop "$col"
					printf -v pad '%*s' $(( _bt_stop - col )) ''
					out=$out$pad
					col=$_bt_stop ;;
				$'\b')	out=$out$c
					[ "$col" -gt 0 ] && col=$(( col - 1 )) ;;
				*)	out=$out$c
					col=$(( col + 1 )) ;;
				esac
			done
			printf '%s\n' "$out"
			line=
		done
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	return "$status"
}

unexpand () {
	local LC_ALL=C
	local arg opt val allblanks=0 file fd status=0
	local line i c col out run runcol runraw seen
	local -a _bt_stops=()
	local _bt_tabevery=8 _bt_stop _bt_stop_real _bt_rangeerr _bt_reason

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
				a)	allblanks=1 ;;
				t)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "unexpand: option requires an argument -- t"
						return 1
					fi
					if ! _bt_tablist "$val"; then
						_bt_err "unexpand: invalid tab size: $_bt_rangeerr"
						return 1
					fi
					allblanks=1 ;;	# -t implies -a
				*)	_bt_err "unexpand: illegal option -- $opt"
					_bt_err "usage: unexpand [-a] [-t tablist] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "unexpand: $file: $_bt_reason"
			status=1
			continue
		fi
		line=
		while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
			out= col=0 run=0 runcol=0 runraw= seen=0
			for (( i = 0; i < ${#line}; i++ )); do
				c=${line:i:1}
				case $c in
				' ')	[ "$run" = 0 ] && runcol=$col
					run=$(( run + 1 ))
					runraw=$runraw$c
					col=$(( col + 1 )) ;;
				$'\t')	[ "$run" = 0 ] && runcol=$col
					_bt_nextstop "$col"
					run=$(( run + _bt_stop - col ))
					runraw=$runraw$c
					col=$_bt_stop ;;
				*)	_bt_unexpand_flush
					out=$out$c
					col=$(( col + 1 ))
					seen=1 ;;
				esac
			done
			_bt_unexpand_flush
			printf '%s\n' "$out"
			line=
		done
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	return "$status"
}

# Emit the pending run of blanks.  Interior blanks are left exactly as they
# were unless -a was given, a run of a single column is never worth a tab,
# and anything longer is converted greedily: a tab at every stop the run
# reaches, then spaces for the remainder.
_bt_unexpand_flush() {
	local at end pad conv=
	[ "$run" -gt 0 ] || return 0
	# Interior blanks stay as they were unless -a was given, and a run of
	# a single column is never worth a tab.
	if { [ "$seen" = 1 ] && [ "$allblanks" = 0 ]; } || [ "$run" -eq 1 ]; then
		out=$out$runraw
		run=0 runraw=
		return 0
	fi
	at=$runcol
	end=$(( runcol + run ))
	# Build the conversion separately: if it turns out not to be usable
	# the original text has to go out instead, not both.
	while :; do
		_bt_nextstop "$at"
		# Only a genuine stop earns a tab; past the end of an explicit
		# list there are no more.
		[ "$_bt_stop_real" = 1 ] || break
		[ "$_bt_stop" -le "$end" ] || break
		conv=$conv$'\t'
		at=$_bt_stop
	done
	if [ "$at" -lt "$end" ]; then
		# The stops cannot reproduce the run exactly.  Spaces are fine
		# for a run that was spaces, but a run holding a literal tab is
		# left alone rather than flattened.
		case $runraw in
		*$'\t'*)
			out=$out$runraw
			run=0 runraw=
			return 0 ;;
		esac
		printf -v pad '%*s' $(( end - at )) ''
		conv=$conv$pad
	fi
	out=$out$conv
	run=0 runraw=
	return 0
}

# ---------------------------------------------------------------------------
# tr -- POSIX.1-2017:
#	tr [-c|-C] [-s] string1 string2
#	tr -s [-c|-C] string1
#	tr -d [-c|-C] string1
#	tr -ds [-c|-C] string1 string2
# ---------------------------------------------------------------------------

# The byte value of character $1, and the character for byte value $1.
_bt_ord() { printf -v _bt_n '%d' "'$1"; }
_bt_chr() { local o; printf -v o '%03o' "$1"; printf -v _bt_c "\\$o"; }

# Read one character of a tr operand: string $1 at index $2.  Sets _bt_c (an
# empty string when the character is NUL, with _bt_cnul set) and _bt_i.
_bt_tr_getc() {
	local s=$1 i=$2 c d oct j
	c=${s:i:1}
	_bt_cnul=0
	if [ "$c" = '\' ] && [ $(( i + 1 )) -lt "${#s}" ]; then
		d=${s:i+1:1}
		case $d in
		a)	_bt_c=$'\a'; _bt_i=$(( i + 2 )) ;;
		b)	_bt_c=$'\b'; _bt_i=$(( i + 2 )) ;;
		f)	_bt_c=$'\f'; _bt_i=$(( i + 2 )) ;;
		n)	_bt_c=$'\n'; _bt_i=$(( i + 2 )) ;;
		r)	_bt_c=$'\r'; _bt_i=$(( i + 2 )) ;;
		t)	_bt_c=$'\t'; _bt_i=$(( i + 2 )) ;;
		v)	_bt_c=$'\v'; _bt_i=$(( i + 2 )) ;;
		'\')	_bt_c='\'; _bt_i=$(( i + 2 )) ;;
		[0-7])	oct=
			j=$(( i + 1 ))
			while [ "${#oct}" -lt 3 ] && [ "$j" -lt "${#s}" ]; do
				case ${s:j:1} in
				[0-7])	oct=$oct${s:j:1}; j=$(( j + 1 )) ;;
				*)	break ;;
				esac
			done
			if [ $(( 8#$oct )) -eq 0 ]; then
				_bt_c=; _bt_cnul=1
			else
				_bt_chr $(( 8#$oct ))
			fi
			_bt_i=$j ;;
		*)	_bt_c=$d; _bt_i=$(( i + 2 )) ;;
		esac
	else
		_bt_c=$c
		_bt_i=$(( i + 1 ))
	fi
	return 0
}

# Append every character of character class $1 to _bt_set.
_bt_tr_class() {
	local k c
	for (( k = 1; k < 256; k++ )); do
		_bt_chr "$k"
		c=$_bt_c
		case $1 in
		alpha)	case $c in [[:alpha:]]) _bt_set+=("$c") ;; esac ;;
		digit)	case $c in [[:digit:]]) _bt_set+=("$c") ;; esac ;;
		alnum)	case $c in [[:alnum:]]) _bt_set+=("$c") ;; esac ;;
		upper)	case $c in [[:upper:]]) _bt_set+=("$c") ;; esac ;;
		lower)	case $c in [[:lower:]]) _bt_set+=("$c") ;; esac ;;
		space)	case $c in [[:space:]]) _bt_set+=("$c") ;; esac ;;
		blank)	case $c in [[:blank:]]) _bt_set+=("$c") ;; esac ;;
		punct)	case $c in [[:punct:]]) _bt_set+=("$c") ;; esac ;;
		print)	case $c in [[:print:]]) _bt_set+=("$c") ;; esac ;;
		graph)	case $c in [[:graph:]]) _bt_set+=("$c") ;; esac ;;
		cntrl)	case $c in [[:cntrl:]]) _bt_set+=("$c") ;; esac ;;
		xdigit)	case $c in [[:xdigit:]]) _bt_set+=("$c") ;; esac ;;
		esac
	done
	return 0
}

# Expand a tr operand into _bt_set, with _bt_set_nul recording whether NUL is
# a member.  _bt_set_fill is the character an unbounded [c*] asks to pad with.
_bt_tr_expand() {
	# ${#1}, not ${#s}: every word on a local line is expanded before any
	# of its assignments happen, so s is not set yet here.
	local s=$1 i=0 n=${#1} c1 c2 lo hi k cls rep cnt rest
	_bt_set=() _bt_set_nul=0 _bt_set_fill=
	while [ "$i" -lt "$n" ]; do
		rest=${s:i}
		case $rest in
		'[:'*)	cls=${rest#'[:'}
			case $cls in
			*':]'*)	cls=${cls%%':]'*}
				case " alpha digit alnum upper lower space blank punct print graph cntrl xdigit " in
				*" $cls "*)
					_bt_tr_class "$cls"
					i=$(( i + ${#cls} + 4 ))
					continue ;;
				esac ;;
			esac ;;
		'[='*)	cls=${rest#'[='}
			case $cls in
			*'=]'*)	cls=${cls%%'=]'*}
				# No equivalence classes beyond the character
				# itself in this locale.
				if [ "${#cls}" -eq 1 ]; then
					_bt_set+=("$cls")
					i=$(( i + 4 ))
					continue
				fi ;;
			esac ;;
		esac
		# [c*n] repeats, [c*] pads to the length of the other set
		case $rest in
		'['*)	_bt_tr_getc "$s" $(( i + 1 ))
			c1=$_bt_c
			k=$_bt_i
			if [ "${s:k:1}" = '*' ]; then
				cnt=${s:k+1}
				cnt=${cnt%%]*}
				if [ "${s:k+1+${#cnt}:1}" = ']' ]; then
					case $cnt in
					'')	_bt_set_fill=$c1
						i=$(( k + 2 ))
						continue ;;
					*[!0-9]*) ;;
					*)	rep=$(( 10#$cnt ))
						if [ "$rep" -eq 0 ]; then
							_bt_set_fill=$c1
						else
							for (( ; rep > 0; rep-- )); do
								_bt_set+=("$c1")
							done
						fi
						i=$(( k + 2 + ${#cnt} ))
						continue ;;
					esac
				fi
			fi ;;
		esac
		_bt_tr_getc "$s" "$i"
		c1=$_bt_c
		[ "$_bt_cnul" = 1 ] && _bt_set_nul=1
		i=$_bt_i
		# a-b ranges
		if [ "$i" -lt "$n" ] && [ "${s:i:1}" = '-' ] && [ $(( i + 1 )) -lt "$n" ] && [ -n "$c1" ]; then
			_bt_tr_getc "$s" $(( i + 1 ))
			c2=$_bt_c
			if [ -n "$c2" ]; then
				i=$_bt_i
				_bt_ord "$c1"; lo=$_bt_n
				_bt_ord "$c2"; hi=$_bt_n
				for (( k = lo; k <= hi; k++ )); do
					_bt_chr "$k"
					_bt_set+=("$_bt_c")
				done
				continue
			fi
		fi
		[ -n "$c1" ] && _bt_set+=("$c1")
	done
	return 0
}

tr () {
	local LC_ALL=C
	local arg opt comp=0 del=0 squeeze=0 i k c t out fill
	local -a set1=() set2=() _bt_set=()
	local _bt_set_nul _bt_set_fill _bt_c _bt_n _bt_cnul _bt_i
	local _bt_buf _bt_nul rc
	local nul1=0 nul2=0 del_nul=0 sq_nul=0 map_nul= map_nul_isnul=0
	local lastout= lastisnul=0 have_last=0

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-[cCds]*)
			arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				c|C)	comp=1 ;;
				d)	del=1 ;;
				s)	squeeze=1 ;;
				esac
			done ;;
		-*)	_bt_err "tr: illegal option -- ${1#-}"
			_bt_err "usage: tr [-c|-C] [-s] string1 string2"
			return 1 ;;
		*)	break ;;
		esac
	done

	if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
		_bt_err "usage: tr [-c|-C] [-s] string1 string2"
		return 1
	fi
	if [ "$del" = 0 ] && [ "$#" -lt 2 ] && [ "$squeeze" = 0 ]; then
		_bt_err "usage: tr [-c|-C] [-s] string1 string2"
		return 1
	fi

	_bt_tr_expand "$1"
	set1=(${_bt_set[@]+"${_bt_set[@]}"})
	nul1=$_bt_set_nul
	if [ "$#" -eq 2 ]; then
		_bt_tr_expand "$2"
		set2=(${_bt_set[@]+"${_bt_set[@]}"})
		nul2=$_bt_set_nul
		fill=$_bt_set_fill
	fi

	if [ "$comp" = 1 ]; then
		# The complement of set1 over every byte value.
		local -A in1=()
		for c in ${set1[@]+"${set1[@]}"}; do in1[$c]=1; done
		set1=()
		[ "$nul1" = 1 ] && nul1=0 || nul1=1
		for (( k = 1; k < 256; k++ )); do
			_bt_chr "$k"
			[ -n "${in1[$_bt_c]-}" ] || set1+=("$_bt_c")
		done
	fi

	local -A dset=() sset=() map=()
	if [ "$del" = 1 ]; then
		for c in ${set1[@]+"${set1[@]}"}; do dset[$c]=1; done
		del_nul=$nul1
		if [ "$squeeze" = 1 ] && [ "$#" -eq 2 ]; then
			for c in ${set2[@]+"${set2[@]}"}; do sset[$c]=1; done
			sq_nul=$nul2
		fi
	else
		if [ "$#" -eq 2 ]; then
			# A short set2 is padded with its last character.
			[ -n "$fill" ] || fill=${set2[${#set2[@]}-1]-}
			for (( i = 0; i < ${#set1[@]}; i++ )); do
				if [ "$i" -lt "${#set2[@]}" ]; then
					map[${set1[i]}]=${set2[i]}
				elif [ -n "$fill" ]; then
					map[${set1[i]}]=$fill
				fi
			done
			if [ "$nul1" = 1 ]; then
				map_nul=${set2[0]-}
				map_nul_isnul=$nul2
			fi
			if [ "$squeeze" = 1 ]; then
				for c in ${set2[@]+"${set2[@]}"}; do sset[$c]=1; done
				sq_nul=$nul2
			fi
		elif [ "$squeeze" = 1 ]; then
			for c in ${set1[@]+"${set1[@]}"}; do sset[$c]=1; done
			sq_nul=$nul1
		fi
	fi

	# One pass over the input.  NUL cannot live in a bash string, so the
	# accumulated output is flushed whenever a NUL has to go out.
	out=
	while :; do
		if _bt_read 0; then rc=0; else rc=1; fi
		for (( i = 0; i < ${#_bt_buf}; i++ )); do
			c=${_bt_buf:i:1}
			[ -n "${dset[$c]-}" ] && continue
			t=${map[$c]-$c}
			if [ -n "${sset[$t]-}" ] && [ "$have_last" = 1 ] &&
			   [ "$lastisnul" = 0 ] && [ "$t" = "$lastout" ]; then
				continue
			fi
			out=$out$t
			lastout=$t lastisnul=0 have_last=1
		done
		if [ "$rc" = 0 ] && [ "$_bt_nul" = 1 ]; then
			if [ "$del_nul" = 0 ]; then
				if [ -n "$map_nul" ]; then
					t=$map_nul
					if [ -n "${sset[$t]-}" ] && [ "$have_last" = 1 ] &&
					   [ "$lastisnul" = 0 ] && [ "$t" = "$lastout" ]; then
						:
					else
						out=$out$t
						lastout=$t lastisnul=0 have_last=1
					fi
				elif [ "$sq_nul" = 1 ] && [ "$have_last" = 1 ] && [ "$lastisnul" = 1 ]; then
					:
				else
					printf '%s' "$out"
					out=
					printf '\000'
					lastisnul=1 have_last=1
				fi
			fi
		fi
		printf '%s' "$out"
		out=
		[ "$rc" = 1 ] && break
	done
	return 0
}

# ---------------------------------------------------------------------------
# cmp -- POSIX.1-2017: cmp [-l|-s] file1 file2
# ---------------------------------------------------------------------------

# Make sure the pending buffer for one side holds data, or is known to be at
# end of file.  $2/$3/$4 name the pending, NUL-pending and eof variables.
_bt_cmp_fill() {
	local -n _p=$2 _n=$3 _e=$4
	[ -z "$_p" ] || return 0
	[ "$_n" = 0 ] || return 0
	[ "$_e" = 0 ] || return 0
	if _bt_read "$1"; then
		_p=$_bt_buf
		_n=$_bt_nul
	else
		_p=$_bt_buf
		_n=0
		_e=1
	fi
	return 0
}

cmp () {
	local LC_ALL=C
	local arg opt listall=0 silent=0 fd1 fd2 f1 f2 _bt_reason
	local p1= p2= n1=0 n2=0 e1=0 e2=0
	local off=0 line=1 k lo hi mid v1 v2 x1 x2 rc=0
	local _bt_buf _bt_nul _bt_n _bt_c

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
				l)	listall=1 ;;
				s)	silent=1 ;;
				*)	_bt_err "cmp: illegal option -- $opt"
					_bt_err "usage: cmp [-l|-s] file1 file2"
					return 2 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$#" -ne 2 ]; then
		_bt_err "usage: cmp [-l|-s] file1 file2"
		return 2
	fi
	f1=$1 f2=$2

	if [ "$f1" = - ]; then
		fd1=0
	elif [ -d "$f1" ] || ! { exec {fd1}<"$f1"; } 2>/dev/null; then
		_bt_why "$f1"; _bt_err "cmp: $f1: $_bt_reason"; return 2
	fi
	if [ "$f2" = - ]; then
		fd2=0
	elif [ -d "$f2" ] || ! { exec {fd2}<"$f2"; } 2>/dev/null; then
		_bt_why "$f2"; _bt_err "cmp: $f2: $_bt_reason"
		[ "$fd1" = 0 ] || exec {fd1}<&-
		return 2
	fi

	while :; do
		_bt_cmp_fill "$fd1" p1 n1 e1
		_bt_cmp_fill "$fd2" p2 n2 e2
		x1=0 x2=0
		[ -z "$p1" ] && [ "$n1" = 0 ] && [ "$e1" = 1 ] && x1=1
		[ -z "$p2" ] && [ "$n2" = 0 ] && [ "$e2" = 1 ] && x2=1
		if [ "$x1" = 1 ] && [ "$x2" = 1 ]; then
			break
		fi
		if [ "$x1" = 1 ] || [ "$x2" = 1 ]; then
			# One is a prefix of the other.  The wording of this
			# diagnostic is not specified by the standard.
			if [ "$silent" = 0 ]; then
				if [ "$x1" = 1 ]; then
					_bt_err "cmp: EOF on $f1 after byte $off"
				else
					_bt_err "cmp: EOF on $f2 after byte $off"
				fi
			fi
			rc=1
			break
		fi

		if [ -n "$p1" ] && [ -n "$p2" ]; then
			k=${#p1}
			[ "${#p2}" -lt "$k" ] && k=${#p2}
			if [ "${p1:0:k}" = "${p2:0:k}" ]; then
				_bt_count "${p1:0:k}"
				line=$(( line + _bt_n ))
				off=$(( off + k ))
				p1=${p1:k} p2=${p2:k}
				continue
			fi
			# Longest common prefix, by bisection.
			lo=0 hi=$k
			while [ "$lo" -lt "$hi" ]; do
				mid=$(( (lo + hi + 1) / 2 ))
				if [ "${p1:0:mid}" = "${p2:0:mid}" ]; then
					lo=$mid
				else
					hi=$(( mid - 1 ))
				fi
			done
			if [ "$lo" -gt 0 ]; then
				_bt_count "${p1:0:lo}"
				line=$(( line + _bt_n ))
				off=$(( off + lo ))
				p1=${p1:lo} p2=${p2:lo}
			fi
			_bt_ord "${p1:0:1}"; v1=$_bt_n
			_bt_ord "${p2:0:1}"; v2=$_bt_n
		else
			# At least one side is sitting on a NUL, which cannot
			# be held in the pending string.
			if [ -z "$p1" ]; then v1=0; else _bt_ord "${p1:0:1}"; v1=$_bt_n; fi
			if [ -z "$p2" ]; then v2=0; else _bt_ord "${p2:0:1}"; v2=$_bt_n; fi
			if [ "$v1" = 0 ] && [ "$v2" = 0 ]; then
				off=$(( off + 1 ))
				n1=0 n2=0
				continue
			fi
		fi

		rc=1
		off=$(( off + 1 ))
		if [ "$silent" = 1 ]; then
			break
		fi
		if [ "$listall" = 1 ]; then
			# The standard's format is "%d %o %o\n"; GNU pads the
			# byte number to the width of the file size.
			printf '%d %o %o\n' "$off" "$v1" "$v2"
		else
			printf '%s %s differ: char %d, line %d\n' "$f1" "$f2" "$off" "$line"
			break
		fi
		# Step over the differing byte on both sides.
		if [ -z "$p1" ]; then n1=0; else
			[ "${p1:0:1}" = $'\n' ] && line=$(( line + 1 ))
			p1=${p1:1}
		fi
		if [ -z "$p2" ]; then n2=0; else p2=${p2:1}; fi
	done

	[ "$fd1" = 0 ] || exec {fd1}<&-
	[ "$fd2" = 0 ] || exec {fd2}<&-
	return "$rc"
}

# ---------------------------------------------------------------------------
# date -- POSIX.1-2017: date [-u] [+format]
#
# Setting the clock needs a syscall no builtin reaches, so only the display
# form is implemented.  bash's printf has strftime built in.
# ---------------------------------------------------------------------------
date () {
	local LC_ALL=C arg opt fmt='%a %b %e %H:%M:%S %Z %Y' out

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		+*)	break ;;
		-)	break ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				u)	local TZ=UTC0 ;;
				*)	_bt_err "date: illegal option -- $opt"
					_bt_err "usage: date [-u] [+format]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	if [ "$#" -gt 1 ]; then
		_bt_err "date: extra operand: $2"
		return 1
	fi
	if [ "$#" -eq 1 ]; then
		case $1 in
		+*)	fmt=${1#+} ;;
		*)	_bt_err "date: setting the date requires a system call no builtin can make"
			return 1 ;;
		esac
	fi
	# -1 is "now"; printf -v keeps the result from being re-scanned.
	printf -v out "%($fmt)T" -1
	printf '%s\n' "$out"
	return 0
}

# ---------------------------------------------------------------------------
# asa -- POSIX.1-2017: asa [file...]
# Interprets FORTRAN carriage-control characters in column one.
# ---------------------------------------------------------------------------
asa () {
	local LC_ALL=C file fd status=0 line ctl rest first=1 _bt_reason

	[ "$#" -gt 0 ] && [ "$1" = -- ] && shift
	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "asa: $file: $_bt_reason"
			status=1
			continue
		fi
		line=
		while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
			ctl=${line:0:1}
			rest=${line:1}
			case $ctl in
			'+')	# overprint: return to the start of the line
				[ "$first" = 1 ] || printf '\r' ;;
			0)	[ "$first" = 1 ] || printf '\n'
				printf '\n' ;;
			1)	[ "$first" = 1 ] || printf '\n'
				printf '\f' ;;
			*)	[ "$first" = 1 ] || printf '\n' ;;
			esac
			printf '%s' "$rest"
			first=0
			line=
		done
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	[ "$first" = 0 ] && printf '\n'
	return "$status"
}

# ---------------------------------------------------------------------------
# cksum -- POSIX.1-2017: cksum [file...]
# The CRC the standard specifies, polynomial 0x04C11DB7.
# ---------------------------------------------------------------------------

# Build the CRC table once, on first use.
_bt_crc_init() {
	local i k c
	[ "${#_BT_CRC[@]}" -eq 256 ] && return 0
	_BT_CRC=()
	for (( i = 0; i < 256; i++ )); do
		c=$(( i << 24 ))
		for (( k = 0; k < 8; k++ )); do
			if (( c & 0x80000000 )); then
				c=$(( ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF ))
			else
				c=$(( (c << 1) & 0xFFFFFFFF ))
			fi
		done
		_BT_CRC+=("$c")
	done
	return 0
}
_BT_CRC=()

# CRC and byte count of fd $1, into _bt_crc and _bt_len.
_bt_cksum_fd() {
	local fd=$1 i v rc crc=0 n=0 len
	local _bt_buf _bt_nul _bt_n
	while :; do
		if _bt_read "$fd"; then rc=0; else rc=1; fi
		len=${#_bt_buf}
		for (( i = 0; i < len; i++ )); do
			printf -v v '%d' "'${_bt_buf:i:1}"
			crc=$(( ((crc << 8) & 0xFFFFFFFF) ^ _BT_CRC[ ((crc >> 24) ^ v) & 0xFF ] ))
		done
		n=$(( n + len ))
		if [ "$rc" = 0 ] && [ "$_bt_nul" = 1 ]; then
			crc=$(( ((crc << 8) & 0xFFFFFFFF) ^ _BT_CRC[ (crc >> 24) & 0xFF ] ))
			n=$(( n + 1 ))
		fi
		[ "$rc" = 1 ] && break
	done
	# The length is folded in, low-order octet first.
	len=$n
	while [ "$len" -gt 0 ]; do
		crc=$(( ((crc << 8) & 0xFFFFFFFF) ^ _BT_CRC[ ((crc >> 24) ^ (len & 0xFF)) & 0xFF ] ))
		len=$(( len >> 8 ))
	done
	_bt_crc=$(( ~crc & 0xFFFFFFFF ))
	_bt_len=$n
	return 0
}

cksum () {
	local LC_ALL=C file fd status=0 _bt_crc _bt_len _bt_reason

	[ "$#" -gt 0 ] && [ "$1" = -- ] && shift
	_bt_crc_init
	if [ "$#" -eq 0 ]; then
		_bt_cksum_fd 0
		printf '%u %d\n' "$_bt_crc" "$_bt_len"
		return 0
	fi
	for file in "$@"; do
		if [ "$file" = - ]; then
			_bt_cksum_fd 0
			printf '%u %d %s\n' "$_bt_crc" "$_bt_len" "$file"
			continue
		fi
		if [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "cksum: $file: $_bt_reason"
			status=1
			continue
		fi
		_bt_cksum_fd "$fd"
		exec {fd}<&-
		printf '%u %d %s\n' "$_bt_crc" "$_bt_len" "$file"
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# split -- POSIX.1-2017:
#	split [-l line_count] [-a suffix_length] [file [name]]
#	split -b n[k|m] [-a suffix_length] [file [name]]
# ---------------------------------------------------------------------------

# The $1'th suffix of length $2: aa, ab, ... zz.
_bt_suffix() {
	local n=$1 w=$2 i
	_bt_sfx=
	for (( i = 0; i < w; i++ )); do
		_bt_chr $(( 97 + n % 26 ))
		_bt_sfx=$_bt_c$_bt_sfx
		n=$(( n / 26 ))
	done
	[ "$n" -eq 0 ] || return 1
	return 0
}

split () {
	local LC_ALL=C
	local arg opt val mode=lines count=1000 width=2 file name=x fd out
	local idx=0 left rc len _bt_sfx _bt_c _bt_n _bt_off _bt_reason
	local _bt_buf _bt_nul

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		-[0-9]*)	# obsolescent "split -500"
			val=${1#-}
			_bt_isnum "$val" || { _bt_err "split: invalid number: $val"; return 1; }
			mode=lines count=$val
			shift ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				l|b|a)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "split: option requires an argument -- $opt"
						return 1
					fi
					case $opt in
					l)	_bt_isnum "$val" || { _bt_err "split: invalid number of lines: $val"; return 1; }
						mode=lines count=$(( 10#$val )) ;;
					b)	case $val in
						*k)	val=${val%k}
							_bt_isnum "$val" || { _bt_err "split: invalid number of bytes: $val"; return 1; }
							count=$(( 10#$val * 1024 )) ;;
						*m)	val=${val%m}
							_bt_isnum "$val" || { _bt_err "split: invalid number of bytes: $val"; return 1; }
							count=$(( 10#$val * 1048576 )) ;;
						*)	_bt_isnum "$val" || { _bt_err "split: invalid number of bytes: $val"; return 1; }
							count=$(( 10#$val )) ;;
						esac
						mode=bytes ;;
					a)	_bt_isnum "$val" || { _bt_err "split: invalid suffix length: $val"; return 1; }
						width=$(( 10#$val )) ;;
					esac ;;
				*)	_bt_err "split: illegal option -- $opt"
					_bt_err "usage: split [-l line_count] [-a suffix_length] [file [name]]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	if [ "$count" -lt 1 ]; then
		_bt_err "split: invalid number: 0"
		return 1
	fi
	if [ "$#" -gt 2 ]; then
		_bt_err "split: extra operand: $3"
		return 1
	fi
	file=-
	[ "$#" -ge 1 ] && file=$1
	[ "$#" -eq 2 ] && name=$2

	if [ "$file" = - ]; then
		fd=0
	elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
		_bt_why "$file"
		_bt_err "split: $file: $_bt_reason"
		return 1
	fi

	out=
	left=$count
	while :; do
		if _bt_read "$fd"; then rc=0; else rc=1; fi
		while :; do
			if [ -z "$out" ]; then
				if [ -z "$_bt_buf" ] && { [ "$rc" = 1 ] || [ "$_bt_nul" = 0 ]; }; then
					break
				fi
				if ! _bt_suffix "$idx" "$width"; then
					_bt_err "split: output file suffixes exhausted"
					[ "$fd" = 0 ] || exec {fd}<&-
					return 1
				fi
				if ! { exec {out}>"$name$_bt_sfx"; } 2>/dev/null; then
					_bt_err "split: cannot open $name$_bt_sfx"
					[ "$fd" = 0 ] || exec {fd}<&-
					return 1
				fi
				idx=$(( idx + 1 ))
				left=$count
			fi
			if [ "$mode" = bytes ]; then
				len=${#_bt_buf}
				if [ "$len" -ge "$left" ]; then
					printf '%s' "${_bt_buf:0:left}" >&"$out"
					_bt_buf=${_bt_buf:left}
					exec {out}>&-
					out=
					continue
				fi
				printf '%s' "$_bt_buf" >&"$out"
				left=$(( left - len ))
				_bt_buf=
				if [ "$rc" = 0 ] && [ "$_bt_nul" = 1 ]; then
					printf '\000' >&"$out"
					_bt_nul=0
					left=$(( left - 1 ))
					if [ "$left" -le 0 ]; then
						exec {out}>&-
						out=
					fi
				fi
				break
			fi
			_bt_count "$_bt_buf"
			if [ "$_bt_n" -ge "$left" ]; then
				_bt_after_nl "$_bt_buf" "$left"
				printf '%s' "${_bt_buf:0:_bt_off}" >&"$out"
				_bt_buf=${_bt_buf:_bt_off}
				exec {out}>&-
				out=
				continue
			fi
			printf '%s' "$_bt_buf" >&"$out"
			left=$(( left - _bt_n ))
			_bt_buf=
			if [ "$rc" = 0 ] && [ "$_bt_nul" = 1 ]; then
				printf '\000' >&"$out"
				_bt_nul=0
			fi
			break
		done
		[ "$rc" = 1 ] && break
	done
	[ -z "$out" ] || exec {out}>&-
	[ "$fd" = 0 ] || exec {fd}<&-
	return 0
}

# ---------------------------------------------------------------------------
# env -- POSIX.1-2017: env [-i] [name=value]... [utility [argument...]]
#
# Running the named utility is the whole point, so that one execve is the
# caller's, not this implementation's.
# ---------------------------------------------------------------------------
env () {
	local LC_ALL=C ignore=0 arg n prog

	local -a assigns=()
	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-|-i)	ignore=1; shift ;;
		-*)	_bt_err "env: illegal option -- ${1#-}"
			_bt_err "usage: env [-i] [name=value]... [utility [argument...]]"
			return 1 ;;
		*)	break ;;
		esac
	done
	while [ "$#" -gt 0 ]; do
		case $1 in
		*=*)	assigns+=("$1"); shift ;;
		*)	break ;;
		esac
	done

	if [ "$#" -eq 0 ]; then
		(
			if [ "$ignore" = 1 ]; then
				for n in $(compgen -e); do unset "$n"; done
			fi
			for n in ${assigns[@]+"${assigns[@]}"}; do export "$n"; done
			for n in $(compgen -e); do printf '%s=%s\n' "$n" "${!n}"; done
		)
		return 0
	fi

	# Resolve the utility while PATH is still there to resolve it with;
	# execvp would have had the same chance.
	prog=$1
	case $prog in
	*/*)	if [ ! -e "$prog" ]; then
			_bt_err "env: '$prog': No such file or directory"
			return 127
		fi
		if [ ! -x "$prog" ] || [ -d "$prog" ]; then
			_bt_err "env: '$prog': Permission denied"
			return 126
		fi ;;
	*)	prog=$(command -v "$1" 2>/dev/null)
		if [ -z "$prog" ]; then
			_bt_err "env: '$1': No such file or directory"
			return 127
		fi ;;
	esac

	if [ "$ignore" = 1 ] && [ "${#assigns[@]}" -eq 0 ]; then
		# exec -c is the only way to hand a child a genuinely empty
		# environment from inside bash.
		( exec -c "$prog" "${@:2}" )
		return $?
	fi
	(
		if [ "$ignore" = 1 ]; then
			for n in $(compgen -e); do unset "$n"; done
		fi
		for n in ${assigns[@]+"${assigns[@]}"}; do export "$n"; done
		"$prog" "${@:2}"
	)
	return $?
}

# ---------------------------------------------------------------------------
# nl -- POSIX.1-2017:
#	nl [-p] [-b type] [-d delim] [-f type] [-h type] [-i incr] [-l num]
#	   [-n format] [-s sep] [-v startnum] [-w width] [file]
#
# The -bp/-hp/-fp regular expression is matched with bash's =~, which is an
# ERE where the standard asks for a BRE.
# ---------------------------------------------------------------------------
nl () {
	local LC_ALL=C
	local arg opt val file fd status=0
	local btype=t htype=n ftype=n bre= hre= fre=
	local delim='\:' sep=$'\t' fmt=rn width=6 start=1 incr=1 blank=1 renumber=1
	local line num sect=body type re out pad blanks=0 newsect _bt_reason

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
				p)	renumber=0 ;;
				b|f|h|d|i|l|n|s|v|w)
					if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "nl: option requires an argument -- $opt"
						return 1
					fi
					case $opt in
					b)	btype=${val:0:1}; bre=${val:1} ;;
					f)	ftype=${val:0:1}; fre=${val:1} ;;
					h)	htype=${val:0:1}; hre=${val:1} ;;
					d)	delim=$val
						[ "${#delim}" -eq 1 ] && delim=$delim: ;;
					i)	incr=$val ;;
					l)	blank=$val ;;
					n)	fmt=$val ;;
					s)	sep=$val ;;
					v)	start=$val ;;
					w)	width=$val ;;
					esac ;;
				*)	_bt_err "nl: illegal option -- $opt"
					_bt_err "usage: nl [-p] [-b type] [-d delim] [-f type] [-h type] [file]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	case $fmt in
	ln|rn|rz)	;;
	*)	_bt_err "nl: invalid line numbering format: $fmt"; return 1 ;;
	esac
	for val in "$incr" "$blank" "$width"; do
		_bt_isnum "$val" || { _bt_err "nl: invalid number: $val"; return 1; }
	done
	_bt_isnum "$start" || { _bt_err "nl: invalid starting line number: $start"; return 1; }
	incr=$(( 10#$incr )); blank=$(( 10#$blank ))
	width=$(( 10#$width )); start=$(( 10#$start ))
	[ "$blank" -ge 1 ] || blank=1

	if [ "$#" -gt 1 ]; then
		_bt_err "nl: extra operand: $2"
		return 1
	fi
	if [ "$#" -eq 0 ] || [ "$1" = - ]; then
		fd=0
	else
		if [ -d "$1" ] || ! { exec {fd}<"$1"; } 2>/dev/null; then
			_bt_why "$1"
			_bt_err "nl: $1: $_bt_reason"
			return 1
		fi
	fi

	num=$start
	printf -v pad '%*s' $(( width + ${#sep} )) ''
	line=
	while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
		# A section delimiter is written out as an empty line.
		case $line in
		"$delim$delim$delim")	sect=header; newsect=1 ;;
		"$delim$delim")	sect=body;   newsect=1 ;;
		"$delim")		sect=footer; newsect=1 ;;
		*)			newsect=0 ;;
		esac
		if [ "$newsect" = 1 ]; then
			[ "$renumber" = 1 ] && num=$start
			blanks=0
			printf '\n'
			line=
			continue
		fi
		case $sect in
		header)	type=$htype re=$hre ;;
		footer)	type=$ftype re=$fre ;;
		*)	type=$btype re=$bre ;;
		esac

		out=0
		case $type in
		a)	if [ -z "$line" ]; then
				# -l groups consecutive empty lines
				blanks=$(( blanks + 1 ))
				[ "$blanks" -ge "$blank" ] && { out=1; blanks=0; }
			else
				blanks=0
				out=1
			fi ;;
		t)	blanks=0
			[ -n "$line" ] && out=1 ;;
		n)	blanks=0 ;;
		p)	blanks=0
			[[ $line =~ $re ]] && out=1 ;;
		*)	blanks=0
			[ -n "$line" ] && out=1 ;;
		esac

		if [ "$out" = 1 ]; then
			case $fmt in
			ln)	printf '%-*d%s%s\n' "$width" "$num" "$sep" "$line" ;;
			rz)	printf '%0*d%s%s\n' "$width" "$num" "$sep" "$line" ;;
			*)	printf '%*d%s%s\n' "$width" "$num" "$sep" "$line" ;;
			esac
			num=$(( num + incr ))
		else
			printf '%s%s\n' "$pad" "$line"
		fi
		line=
	done
	[ "$fd" = 0 ] || exec {fd}<&-
	return "$status"
}

# ---------------------------------------------------------------------------
# tsort -- POSIX.1-2017: tsort [file]
#
# The order among items with no relation between them is unspecified; this
# keeps the order they were first seen in.
# ---------------------------------------------------------------------------
tsort () {
	local LC_ALL=C
	local file fd status=0 tok u v i n out _bt_reason
	local -a nodes=() queue=()
	local -A indeg=() succ=() known=()

	[ "$#" -gt 0 ] && [ "$1" = -- ] && shift
	if [ "$#" -gt 1 ]; then
		_bt_err "tsort: extra operand: $2"
		return 1
	fi
	if [ "$#" -eq 0 ] || [ "$1" = - ]; then
		fd=0
	else
		if [ -d "$1" ] || ! { exec {fd}<"$1"; } 2>/dev/null; then
			_bt_why "$1"
			_bt_err "tsort: $1: $_bt_reason"
			return 1
		fi
	fi

	u=
	while read -r tok <&"$fd" || [ -n "$tok" ]; do
		for v in $tok; do
			if [ -z "${known[$v]-}" ]; then
				known[$v]=1
				nodes+=("$v")
				indeg[$v]=0
				succ[$v]=
			fi
			if [ -z "$u" ]; then
				u=$v
			else
				if [ "$u" != "$v" ]; then
					succ[$u]="${succ[$u]} $v"
					indeg[$v]=$(( ${indeg[$v]} + 1 ))
				fi
				u=
			fi
		done
		tok=
	done
	[ "$fd" = 0 ] || exec {fd}<&-
	if [ -n "$u" ]; then
		_bt_err "tsort: odd number of tokens"
		return 1
	fi

	for v in ${nodes[@]+"${nodes[@]}"}; do
		[ "${indeg[$v]}" -eq 0 ] && queue+=("$v")
	done
	n=0
	i=0
	while [ "$i" -lt "${#queue[@]}" ]; do
		u=${queue[i]}
		i=$(( i + 1 ))
		printf '%s\n' "$u"
		n=$(( n + 1 ))
		for v in ${succ[$u]}; do
			indeg[$v]=$(( ${indeg[$v]} - 1 ))
			[ "${indeg[$v]}" -eq 0 ] && queue+=("$v")
		done
	done
	if [ "$n" -lt "${#nodes[@]}" ]; then
		# Whatever is left is in a cycle.
		_bt_err "tsort: input contains a loop"
		for v in ${nodes[@]+"${nodes[@]}"}; do
			[ "${indeg[$v]}" -gt 0 ] && printf '%s\n' "$v"
		done
		status=1
	fi
	return "$status"
}

# ---------------------------------------------------------------------------
# pathchk -- POSIX.1-2017: pathchk [-p] pathname...
#
# Without -p the limits are the ones this kernel actually uses, since
# pathconf() is not reachable from a builtin.
# ---------------------------------------------------------------------------
pathchk () {
	local LC_ALL=C
	local arg opt portable=0 leading=0 p comp rest status=0
	local namemax=255 pathmax=4096 dir

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
				p)	portable=1 ;;
				P)	leading=1 ;;
				*)	_bt_err "pathchk: illegal option -- $opt"
					_bt_err "usage: pathchk [-p] pathname..."
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$#" -eq 0 ]; then
		_bt_err "usage: pathchk [-p] pathname..."
		return 1
	fi
	# -p asks about the limits every conforming system guarantees; without
	# it the question is whether this system could use the name, and
	# pathconf() is not reachable, so the kernel's own limits stand in.
	if [ "$portable" = 1 ]; then
		namemax=14 pathmax=256
	fi

	for p in "$@"; do
		if [ -z "$p" ]; then
			_bt_err "pathchk: '': No such file or directory"
			status=1
			continue
		fi
		if [ "${#p}" -gt "$pathmax" ]; then
			_bt_err "pathchk: '$p': name too long (${#p} > $pathmax)"
			status=1
			continue
		fi
		rest=$p
		dir=
		while :; do
			rest=${rest#/}
			comp=${rest%%/*}
			[ -n "$comp" ] || break
			if [ "${#comp}" -gt "$namemax" ]; then
				_bt_err "pathchk: '$p': component too long: $comp"
				status=1
				break
			fi
			if [ "$portable" = 1 ]; then
				case $comp in
				*[!A-Za-z0-9._-]*)
					_bt_err "pathchk: '$p': non-portable character in: $comp"
					status=1
					break ;;
				esac
			fi
			# A leading hyphen is checked only under -P.
			if [ "$leading" = 1 ]; then
				case $comp in
				-*)	_bt_err "pathchk: '$p': leading '-' in: $comp"
					status=1
					break ;;
				esac
			fi
			case $rest in
			*/*)	rest=${rest#*/} ;;
			*)	break ;;
			esac
			# -p is about portability, not about what this
			# filesystem happens to hold, so the rest is skipped.
			[ "$portable" = 0 ] || continue
			dir=$dir/$comp
			if [ -e "$dir" ] && [ ! -d "$dir" ]; then
				_bt_err "pathchk: '$p': $comp is not a directory"
				status=1
				break
			fi
			if [ -d "$dir" ] && [ ! -x "$dir" ]; then
				_bt_err "pathchk: '$p': $comp is not searchable"
				status=1
				break
			fi
		done
	done
	return "$status"
}
# ---------------------------------------------------------------------------
# strings -- POSIX.1-2017: strings [-a] [-t format] [-n number] [file...]
# ---------------------------------------------------------------------------
strings () {
	local LC_ALL=C
	local arg opt val minlen=4 tfmt= file fd status=0
	local i c run runoff off len rc _bt_reason
	local _bt_buf _bt_nul

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
				a)	;;	# whole file is scanned either way here
				n|t)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "strings: option requires an argument -- $opt"
						return 1
					fi
					if [ "$opt" = n ]; then
						_bt_isnum "$val" || { _bt_err "strings: invalid number: $val"; return 1; }
						minlen=$(( 10#$val ))
					else
						case $val in
						d|o|x)	tfmt=$val ;;
						*)	_bt_err "strings: invalid radix: $val"; return 1 ;;
						esac
					fi ;;
				[0-9])	minlen=$opt$arg; arg=
					_bt_isnum "$minlen" || { _bt_err "strings: invalid number"; return 1; }
					minlen=$(( 10#$minlen )) ;;
				*)	_bt_err "strings: illegal option -- $opt"
					_bt_err "usage: strings [-a] [-t format] [-n number] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	[ "$minlen" -ge 1 ] || minlen=1

	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "strings: $file: $_bt_reason"
			status=1
			continue
		fi
		run= runoff=0 off=0
		while :; do
			if _bt_read "$fd"; then rc=0; else rc=1; fi
			len=${#_bt_buf}
			for (( i = 0; i < len; i++ )); do
				c=${_bt_buf:i:1}
				case $c in
				# A tab counts as part of a string, as it does elsewhere.
				[[:print:]]|$'\t')
					[ -z "$run" ] && runoff=$(( off + i ))
					run=$run$c ;;
				*)	if [ "${#run}" -ge "$minlen" ]; then
						_bt_strings_emit
					fi
					run= ;;
				esac
			done
			off=$(( off + len ))
			# the separating NUL ends any run
			if [ "$rc" = 0 ] && [ "$_bt_nul" = 1 ]; then
				if [ "${#run}" -ge "$minlen" ]; then
					_bt_strings_emit
				fi
				run=
				off=$(( off + 1 ))
			fi
			[ "$rc" = 1 ] && break
		done
		if [ "${#run}" -ge "$minlen" ]; then
			_bt_strings_emit
		fi
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	return "$status"
}

_bt_strings_emit() {
	case $tfmt in
	d)	printf '%7d %s\n' "$runoff" "$run" ;;
	o)	printf '%7o %s\n' "$runoff" "$run" ;;
	x)	printf '%7x %s\n' "$runoff" "$run" ;;
	*)	printf '%s\n' "$run" ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# tabs -- POSIX.1-2017: tabs [-n] [+m[n]] / tabs [-T type] n1[,n2,...]
#
# The escape sequences are the ANSI ones; a terminfo database is a binary file
# this could parse, but not one worth parsing.
# ---------------------------------------------------------------------------
tabs () {
	local LC_ALL=C
	local arg every=8 margin=0 out i col stop
	local -a stops=()

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-[0-9]*)	every=${1#-}; stops=(); shift ;;
		+m*)	margin=${1#+m}; [ -n "$margin" ] || margin=10; shift ;;
		-T)	shift; [ "$#" -gt 0 ] && shift ;;
		-T*)	shift ;;
		-a)	stops=(1 10 16 36 72); every=0; shift ;;
		-c)	stops=(1 8 12 16 20 55); every=0; shift ;;
		-f)	stops=(1 7 11 15 19 23); every=0; shift ;;
		-p)	stops=(1 5 9 13 17 21 25 29 33 37 41 45 49 53 57 61); every=0; shift ;;
		-s)	stops=(1 10 55); every=0; shift ;;
		-u)	stops=(1 12 20 44); every=0; shift ;;
		-*)	_bt_err "tabs: illegal option -- ${1#-}"
			_bt_err "usage: tabs [-n] [+m[n]] [n1[,n2,...]]"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ "$#" -gt 0 ]; then
		if ! _bt_ranges "$1"; then
			_bt_err "tabs: invalid tab stop: $1"
			return 1
		fi
		stops=(${_bt_lo[@]+"${_bt_lo[@]}"})
		every=0
	fi

	# Clear every stop, return to the left margin, then walk right setting
	# one at each position.
	printf '\033[3g\r'
	col=1
	if [ "${#stops[@]}" -gt 0 ]; then
		for stop in "${stops[@]}"; do
			[ "$stop" -ge "$col" ] || continue
			printf -v out '%*s' $(( stop - col )) ''
			printf '%s\033H' "$out"
			col=$stop
		done
	else
		[ "$every" -ge 1 ] || every=8
		stop=1
		while [ "$stop" -le 80 ]; do
			printf -v out '%*s' $(( stop - col )) ''
			printf '%s\033H' "$out"
			col=$stop
			stop=$(( stop + every ))
		done
		# Finish at the right-hand edge, as the real one does.
		if [ "$col" -lt 80 ]; then
			printf -v out '%*s' $(( 80 - col )) ''
			printf '%s' "$out"
		fi
	fi
	printf '\r'
	return 0
}

# ---------------------------------------------------------------------------
# expr -- POSIX.1-2017: expr operand...
# ---------------------------------------------------------------------------

# Is $1 a decimal integer, optionally signed?
_bt_expr_int() {
	case $1 in
	''|-|+)		return 1 ;;
	[-+]*)		case ${1#[-+]} in *[!0-9]*|'') return 1 ;; esac ;;
	*)		case $1 in *[!0-9]*) return 1 ;; esac ;;
	esac
	return 0
}

# The standard's `:` operand is a BRE; bash's =~ is an ERE, so the metacharacters
# that differ are swapped over.
_bt_bre2ere() {
	local s=$1 out= i c
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		if [ "$c" = '\' ] && [ $(( i + 1 )) -lt "${#s}" ]; then
			case ${s:i+1:1} in
			# \+ \? and \| are the operators in a BRE as every
			# implementation extends it, so they lose the backslash.
			'+'|'?'|'|')	out=$out${s:i+1:1} ;;
			'('|')'|'{'|'}')	out=$out${s:i+1:1} ;;
			*)			out=$out'\'${s:i+1:1} ;;
			esac
			i=$(( i + 1 ))
		else
			case $c in
			'('|')'|'{'|'}'|'+'|'?'|'|')	out=$out'\'$c ;;
			*)				out=$out$c ;;
			esac
		fi
	done
	_bt_re=$out
}

_bt_expr_peek() {
	if [ "$_bt_i" -lt "$_bt_n" ]; then
		_bt_tok=${_bt_A[_bt_i]}
		return 0
	fi
	_bt_tok=
	return 1
}

_bt_expr_primary() {
	if ! _bt_expr_peek; then
		_bt_err "expr: syntax error"
		_bt_bad=2
		return 1
	fi
	case $_bt_tok in
	'+')	# "+ token" is the historical way to hand expr a
		# string that would otherwise read as an operator.
		_bt_i=$(( _bt_i + 1 ))
		if [ "$_bt_i" -ge "$_bt_n" ]; then
			_bt_err "expr: syntax error: missing argument after '+'"
			_bt_bad=2
			return 1
		fi
		_bt_val=${_bt_A[_bt_i]}
		_bt_i=$(( _bt_i + 1 ))
		return 0 ;;
	'(')	_bt_i=$(( _bt_i + 1 ))
		_bt_expr_or || return 1
		if ! _bt_expr_peek || [ "$_bt_tok" != ')' ]; then
			_bt_err "expr: syntax error: expected )"
			_bt_bad=2
			return 1
		fi
		_bt_i=$(( _bt_i + 1 ))
		return 0 ;;
	length)	_bt_i=$(( _bt_i + 1 ))
		_bt_expr_primary || return 1
		_bt_val=${#_bt_val}
		return 0 ;;
	substr)	_bt_i=$(( _bt_i + 1 ))
		local s p l
		_bt_expr_primary || return 1; s=$_bt_val
		_bt_expr_primary || return 1; p=$_bt_val
		_bt_expr_primary || return 1; l=$_bt_val
		if ! _bt_expr_int "$p" || ! _bt_expr_int "$l" || [ "$p" -lt 1 ] || [ "$l" -lt 1 ]; then
			_bt_val=
		else
			_bt_val=${s:p-1:l}
		fi
		return 0 ;;
	index)	_bt_i=$(( _bt_i + 1 ))
		local str chars k j
		_bt_expr_primary || return 1; str=$_bt_val
		_bt_expr_primary || return 1; chars=$_bt_val
		_bt_val=0
		for (( k = 0; k < ${#str}; k++ )); do
			for (( j = 0; j < ${#chars}; j++ )); do
				if [ "${str:k:1}" = "${chars:j:1}" ]; then
					_bt_val=$(( k + 1 ))
					return 0
				fi
			done
		done
		return 0 ;;
	match)	_bt_i=$(( _bt_i + 1 ))
		local a b
		_bt_expr_primary || return 1; a=$_bt_val
		_bt_expr_primary || return 1; b=$_bt_val
		_bt_expr_match "$a" "$b"
		return 0 ;;
	*)	_bt_val=$_bt_tok
		_bt_i=$(( _bt_i + 1 ))
		return 0 ;;
	esac
}

# STRING : BRE -- the captured group if the pattern has one, otherwise the
# number of characters matched.
_bt_expr_match() {
	local s=$1 re
	_bt_bre2ere "$2"
	re=$_bt_re
	if [[ $s =~ ^$re ]]; then
		if [ "${#BASH_REMATCH[@]}" -gt 1 ]; then
			_bt_val=${BASH_REMATCH[1]}
		else
			_bt_val=${#BASH_REMATCH[0]}
		fi
	else
		case $re in
		*'('*)	_bt_val= ;;
		*)	_bt_val=0 ;;
		esac
	fi
	return 0
}

_bt_expr_colon() {
	local lhs
	_bt_expr_primary || return 1
	while _bt_expr_peek && [ "$_bt_tok" = ':' ]; do
		lhs=$_bt_val
		_bt_i=$(( _bt_i + 1 ))
		_bt_expr_primary || return 1
		_bt_expr_match "$lhs" "$_bt_val"
	done
	return 0
}

_bt_expr_mul() {
	local lhs op
	_bt_expr_colon || return 1
	while _bt_expr_peek; do
		case $_bt_tok in
		'*'|'/'|'%')	op=$_bt_tok ;;
		*)		break ;;
		esac
		lhs=$_bt_val
		_bt_i=$(( _bt_i + 1 ))
		_bt_expr_colon || return 1
		if ! _bt_expr_int "$lhs" || ! _bt_expr_int "$_bt_val"; then
			_bt_err "expr: non-integer argument"
			_bt_bad=2
			return 1
		fi
		if [ "$op" != '*' ] && [ "$_bt_val" -eq 0 ]; then
			_bt_err "expr: division by zero"
			_bt_bad=2
			return 1
		fi
		case $op in
		'*')	_bt_val=$(( lhs * _bt_val )) ;;
		'/')	_bt_val=$(( lhs / _bt_val )) ;;
		'%')	_bt_val=$(( lhs % _bt_val )) ;;
		esac
	done
	return 0
}

_bt_expr_add() {
	local lhs op
	_bt_expr_mul || return 1
	while _bt_expr_peek; do
		case $_bt_tok in
		'+'|'-')	op=$_bt_tok ;;
		*)		break ;;
		esac
		lhs=$_bt_val
		_bt_i=$(( _bt_i + 1 ))
		_bt_expr_mul || return 1
		if ! _bt_expr_int "$lhs" || ! _bt_expr_int "$_bt_val"; then
			_bt_err "expr: non-integer argument"
			_bt_bad=2
			return 1
		fi
		if [ "$op" = '+' ]; then
			_bt_val=$(( lhs + _bt_val ))
		else
			_bt_val=$(( lhs - _bt_val ))
		fi
	done
	return 0
}

_bt_expr_cmp() {
	local lhs op r
	_bt_expr_add || return 1
	while _bt_expr_peek; do
		case $_bt_tok in
		'='|'>'|'>='|'<'|'<='|'!=')	op=$_bt_tok ;;
		*)				break ;;
		esac
		lhs=$_bt_val
		_bt_i=$(( _bt_i + 1 ))
		_bt_expr_add || return 1
		if _bt_expr_int "$lhs" && _bt_expr_int "$_bt_val"; then
			case $op in
			'=')	[ "$lhs" -eq "$_bt_val" ] && r=1 || r=0 ;;
			'!=')	[ "$lhs" -ne "$_bt_val" ] && r=1 || r=0 ;;
			'>')	[ "$lhs" -gt "$_bt_val" ] && r=1 || r=0 ;;
			'>=')	[ "$lhs" -ge "$_bt_val" ] && r=1 || r=0 ;;
			'<')	[ "$lhs" -lt "$_bt_val" ] && r=1 || r=0 ;;
			'<=')	[ "$lhs" -le "$_bt_val" ] && r=1 || r=0 ;;
			esac
		else
			case $op in
			'=')	[ "$lhs" = "$_bt_val" ] && r=1 || r=0 ;;
			'!=')	[ "$lhs" != "$_bt_val" ] && r=1 || r=0 ;;
			'>')	[[ $lhs > $_bt_val ]] && r=1 || r=0 ;;
			'>=')	[[ ! $lhs < $_bt_val ]] && r=1 || r=0 ;;
			'<')	[[ $lhs < $_bt_val ]] && r=1 || r=0 ;;
			'<=')	[[ ! $lhs > $_bt_val ]] && r=1 || r=0 ;;
			esac
		fi
		_bt_val=$r
	done
	return 0
}

_bt_expr_and() {
	local lhs
	_bt_expr_cmp || return 1
	while _bt_expr_peek && [ "$_bt_tok" = '&' ]; do
		lhs=$_bt_val
		_bt_i=$(( _bt_i + 1 ))
		_bt_expr_cmp || return 1
		if [ -z "$lhs" ] || [ "$lhs" = 0 ] || [ -z "$_bt_val" ] || [ "$_bt_val" = 0 ]; then
			_bt_val=0
		else
			_bt_val=$lhs
		fi
	done
	return 0
}

_bt_expr_or() {
	local lhs
	_bt_expr_and || return 1
	while _bt_expr_peek && [ "$_bt_tok" = '|' ]; do
		lhs=$_bt_val
		_bt_i=$(( _bt_i + 1 ))
		_bt_expr_and || return 1
		if [ -n "$lhs" ] && [ "$lhs" != 0 ]; then
			_bt_val=$lhs
		fi
	done
	return 0
}

expr () {
	local LC_ALL=C
	local -a _bt_A=("$@")
	local _bt_i=0 _bt_n=$# _bt_val= _bt_tok _bt_re _bt_bad=0

	if [ "$#" -eq 0 ]; then
		_bt_err "usage: expr operand..."
		return 2
	fi
	if ! _bt_expr_or; then
		return "$_bt_bad"
	fi
	if [ "$_bt_i" -lt "$_bt_n" ]; then
		_bt_err "expr: syntax error: unexpected ${_bt_A[_bt_i]}"
		return 2
	fi
	printf '%s\n' "$_bt_val"
	case $_bt_val in
	''|0)	return 1 ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# od -- POSIX.1-2017:
#	od [-v] [-A address_base] [-j skip] [-N count] [-t type_string]...
#	   [file...]
# ---------------------------------------------------------------------------

_BT_OD_NAMES=(nul soh stx etx eot enq ack bel bs ht nl vt ff cr so si
	      dle dc1 dc2 dc3 dc4 nak syn etb can em sub esc fs gs rs us sp)

# Field width for a type letter and size, matching every other od.
_bt_od_width() {
	case $1$2 in
	o1)	_bt_w=3 ;;	o2)	_bt_w=6 ;;	o4)	_bt_w=11 ;;	o8)	_bt_w=22 ;;
	x1)	_bt_w=2 ;;	x2)	_bt_w=4 ;;	x4)	_bt_w=8 ;;	x8)	_bt_w=16 ;;
	d1)	_bt_w=4 ;;	d2)	_bt_w=6 ;;	d4)	_bt_w=11 ;;	d8)	_bt_w=20 ;;
	u1)	_bt_w=3 ;;	u2)	_bt_w=5 ;;	u4)	_bt_w=10 ;;	u8)	_bt_w=20 ;;
	*)	_bt_w=3 ;;
	esac
	return 0
}

# Render _bt_ngroup byte values from _bt_vals as type $1 of size $2, with the
# type's own width $3 and the shared column width $4, into _bt_line.
_bt_od_group() {
	local t=$1 sz=$2 w=$3 col=$4 i k v val neg f
	for (( i = 0; i + sz <= _bt_ngroup; i += sz )); do
		if [ "$sz" -eq 1 ]; then
			v=${_bt_vals[i]}
			case $t in
			c)	case $v in
				0)	f='\0' ;;
				7)	f='\a' ;;
				8)	f='\b' ;;
				9)	f='\t' ;;
				10)	f='\n' ;;
				11)	f='\v' ;;
				12)	f='\f' ;;
				13)	f='\r' ;;
				*)	if [ "$v" -ge 32 ] && [ "$v" -le 126 ]; then
						_bt_chr "$v"; f=$_bt_c
					else
						printf -v f '%03o' "$v"
					fi ;;
				esac
				printf -v f '%*s' "$col" "$f"
				_bt_line=$_bt_line' '$f
				continue ;;
			a)	k=$(( v & 0x7f ))
				if [ "$k" -le 32 ]; then
					f=${_BT_OD_NAMES[k]}
				elif [ "$k" -eq 127 ]; then
					f=del
				else
					_bt_chr "$k"; f=$_bt_c
				fi
				printf -v f '%*s' "$col" "$f"
				_bt_line=$_bt_line' '$f
				continue ;;
			esac
		fi
		# little-endian assembly
		val=0
		for (( k = sz - 1; k >= 0; k-- )); do
			val=$(( (val << 8) | _bt_vals[i+k] ))
		done
		case $t in
		d)	neg=$(( 1 << (sz * 8 - 1) ))
			[ "$val" -ge "$neg" ] && val=$(( val - (neg << 1) ))
			printf -v f '%*d' "$w" "$val" ;;
		u)	printf -v f '%*u' "$w" "$val" ;;
		x)	printf -v f '%0*x' "$w" "$val" ;;
		*)	printf -v f '%0*o' "$w" "$val" ;;
		esac
		# The value keeps its own zero padding; the column is what
		# lines several -t outputs up with each other.
		printf -v f '%*s' "$col" "$f"
		_bt_line=$_bt_line' '$f
	done
	# a trailing partial unit still shows the bytes that are there
	if [ "$sz" -gt 1 ] && [ $(( _bt_ngroup % sz )) -ne 0 ]; then
		val=0
		for (( k = _bt_ngroup - 1; k >= i; k-- )); do
			val=$(( (val << 8) | _bt_vals[k] ))
		done
		case $t in
		d|u)	printf -v f '%*u' "$w" "$val" ;;
		x)	printf -v f '%0*x' "$w" "$val" ;;
		*)	printf -v f '%0*o' "$w" "$val" ;;
		esac
		printf -v f '%*s' "$col" "$f"
		_bt_line=$_bt_line' '$f
	fi
	return 0
}

# Write the group currently at the front of _bt_vals.
_bt_od_emit() {
	local k first=1 sig
	if [ "$_bt_verbose" = 0 ] && [ "$_bt_ngroup" -eq 16 ]; then
		sig=${_bt_vals[*]:0:16}
		if [ "$sig" = "$_bt_prev" ]; then
			[ "$_bt_star" = 0 ] && { printf '*\n'; _bt_star=1; }
			_bt_off=$(( _bt_off + _bt_ngroup ))
			return 0
		fi
		_bt_prev=$sig
	fi
	_bt_star=0
	for (( k = 0; k < ${#_bt_types[@]}; k++ )); do
		_bt_line=
		_bt_od_group "${_bt_types[k]}" "${_bt_sizes[k]}" "${_bt_widths[k]}" "${_bt_cols[k]}"
		if [ "$_bt_abase" = n ]; then
			printf '%s\n' "$_bt_line"
		elif [ "$first" = 1 ]; then
			_bt_od_addr "$_bt_off"
			printf '%s%s\n' "$_bt_addr" "$_bt_line"
			first=0
		else
			printf '%*s%s\n' "${#_bt_addr}" '' "$_bt_line"
		fi
	done
	_bt_off=$(( _bt_off + _bt_ngroup ))
	return 0
}

_bt_od_addr() {
	case $_bt_abase in
	d)	printf -v _bt_addr '%07d' "$1" ;;
	x)	printf -v _bt_addr '%06x' "$1" ;;
	*)	printf -v _bt_addr '%07o' "$1" ;;
	esac
	return 0
}

od () {
	local LC_ALL=C
	local arg opt val file fd status=0 opened=0
	local i j n b rc len v skip=0 remaining=-1
	local _bt_w _bt_c _bt_line _bt_ngroup _bt_addr _bt_reason
	local _bt_buf _bt_nul
	local _bt_abase=o _bt_verbose=0 _bt_off=0 _bt_prev= _bt_star=0
	local -a _bt_types=() _bt_sizes=() _bt_widths=() _bt_cols=() _bt_vals=()

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
				v)	_bt_verbose=1 ;;
				b)	_bt_types+=(o); _bt_sizes+=(1) ;;
				c)	_bt_types+=(c); _bt_sizes+=(1) ;;
				d)	_bt_types+=(u); _bt_sizes+=(2) ;;
				o)	_bt_types+=(o); _bt_sizes+=(2) ;;
				s)	_bt_types+=(d); _bt_sizes+=(2) ;;
				x)	_bt_types+=(x); _bt_sizes+=(2) ;;
				A|j|N|t)
					if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "od: option requires an argument -- $opt"
						return 1
					fi
					case $opt in
					A)	case $val in
						d|o|x|n)	_bt_abase=$val ;;
						*)	_bt_err "od: invalid address base: $val"; return 1 ;;
						esac ;;
					j)	_bt_isnum "$val" || { _bt_err "od: invalid skip: $val"; return 1; }
						skip=$(( 10#$val )) ;;
					N)	_bt_isnum "$val" || { _bt_err "od: invalid count: $val"; return 1; }
						remaining=$(( 10#$val )) ;;
					t)	i=0
						while [ "$i" -lt "${#val}" ]; do
							case ${val:i:1} in
							a|c)	_bt_types+=("${val:i:1}"); _bt_sizes+=(1); i=$(( i + 1 )) ;;
							d|o|u|x)
								opt=${val:i:1}
								i=$(( i + 1 ))
								n=
								while [ "$i" -lt "${#val}" ]; do
									case ${val:i:1} in
									[0-9])	n=$n${val:i:1}; i=$(( i + 1 )) ;;
									C)	n=1; i=$(( i + 1 )); break ;;
									S)	n=2; i=$(( i + 1 )); break ;;
									I|L)	n=4; i=$(( i + 1 )); break ;;
									*)	break ;;
									esac
								done
								[ -n "$n" ] || n=4
								_bt_types+=("$opt"); _bt_sizes+=("$n") ;;
							*)	_bt_err "od: invalid type string: $val"; return 1 ;;
							esac
						done ;;
					esac ;;
				*)	_bt_err "od: illegal option -- $opt"
					_bt_err "usage: od [-v] [-A base] [-j skip] [-N count] [-t type]... [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "${#_bt_types[@]}" -eq 0 ]; then
		_bt_types=(o); _bt_sizes=(2)
	fi
	# Several -t specs are printed one under the other, so every line
	# has to come out the same width: each byte gets the same number of
	# columns, whatever the type covering it.
	b=1
	for (( i = 0; i < ${#_bt_types[@]}; i++ )); do
		_bt_od_width "${_bt_types[i]}" "${_bt_sizes[i]}"
		_bt_widths[i]=$_bt_w
		j=$(( (_bt_w + 1 + _bt_sizes[i] - 1) / _bt_sizes[i] ))
		[ "$j" -gt "$b" ] && b=$j
	done
	for (( i = 0; i < ${#_bt_types[@]}; i++ )); do
		if [ "${#_bt_types[@]}" -eq 1 ]; then
			# On its own a type just uses its own width.
			_bt_cols[i]=${_bt_widths[i]}
		else
			_bt_cols[i]=$(( b * _bt_sizes[i] - 1 ))
		fi
	done

	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "od: $file: $_bt_reason"
			status=1
			continue
		fi
		opened=1
		while :; do
			if _bt_read "$fd"; then rc=0; else rc=1; fi
			len=${#_bt_buf}
			for (( i = 0; i <= len; i++ )); do
				if [ "$i" -eq "$len" ]; then
					# the separating NUL, if there was one
					[ "$rc" = 0 ] && [ "$_bt_nul" = 1 ] || break
					v=0
				else
					printf -v v '%d' "'${_bt_buf:i:1}"
				fi
				# -j is applied here so that groups still start on
				# a sixteen byte boundary from the skip point.
				if [ "$skip" -gt 0 ]; then
					skip=$(( skip - 1 ))
					_bt_off=$(( _bt_off + 1 ))
					continue
				fi
				[ "$remaining" -eq 0 ] && break
				_bt_vals+=("$v")
				[ "$remaining" -gt 0 ] && remaining=$(( remaining - 1 ))
				if [ "${#_bt_vals[@]}" -eq 16 ]; then
					_bt_ngroup=16
					_bt_od_emit
					_bt_vals=()
				fi
			done
			[ "$rc" = 1 ] && break
			[ "$remaining" -eq 0 ] && break
		done
		[ "$fd" = 0 ] || exec {fd}<&-
		[ "$remaining" -eq 0 ] && break
	done
	if [ "${#_bt_vals[@]}" -gt 0 ]; then
		_bt_ngroup=${#_bt_vals[@]}
		_bt_od_emit
	fi
	# Skipping past the end of the input is an error, as it is
	# everywhere else.
	if [ "$skip" -gt 0 ] && [ "$opened" = 1 ]; then
		_bt_err "od: cannot skip past end of input"
		return 1
	fi
	if [ "$_bt_abase" != n ] && [ "$opened" = 1 ]; then
		_bt_od_addr "$_bt_off"
		printf '%s\n' "$_bt_addr"
	fi
	return "$status"
}

# ---------------------------------------------------------------------------
# sort -- POSIX.1-2017:
#	sort [-m] [-o output] [-bdfinru] [-t char] [-k keydef]... [file...]
#	sort -c [-bdfinru] [-t char] [-k keydef] [file]
# ---------------------------------------------------------------------------

# Character offsets at which each field of $1 begins, into _bt_fs.  Without a
# -t separator a field carries its own leading blanks, which is what makes
# -b meaningful.
_bt_sort_fields() {
	local s=$1 i=0 n=${#1}
	_bt_fs=(0)
	if [ -n "$_bt_sep" ]; then
		while [ "$i" -lt "$n" ]; do
			if [ "${s:i:1}" = "$_bt_sep" ]; then
				_bt_fs+=($(( i + 1 )))
			fi
			i=$(( i + 1 ))
		done
	else
		while [ "$i" -lt "$n" ]; do
			while [ "$i" -lt "$n" ]; do
				case ${s:i:1} in
				[[:blank:]])	i=$(( i + 1 )) ;;
				*)		break ;;
				esac
			done
			while [ "$i" -lt "$n" ]; do
				case ${s:i:1} in
				[[:blank:]])	break ;;
				*)		i=$(( i + 1 )) ;;
				esac
			done
			[ "$i" -lt "$n" ] && _bt_fs+=("$i")
		done
	fi
	return 0
}

# End offset (exclusive) of field $1 of the line whose starts are in _bt_fs.
_bt_sort_fend() {
	local f=$1
	if [ "$f" -lt "${#_bt_fs[@]}" ]; then
		if [ -n "$_bt_sep" ]; then
			# the separator itself is not part of the field
			_bt_fe=$(( _bt_fs[f] - 1 ))
		else
			_bt_fe=${_bt_fs[f]}
		fi
	else
		_bt_fe=$_bt_linelen
	fi
	return 0
}

# The key of line $1 under key spec index $2, into _bt_k.
_bt_sort_key() {
	local s=$1 k=$2 sf sc ef ec start end mods
	sf=${_bt_ksf[k]} sc=${_bt_ksc[k]} ef=${_bt_kef[k]} ec=${_bt_kec[k]} mods=${_bt_kmod[k]}
	_bt_linelen=${#s}
	_bt_sort_fields "$s"
	if [ "$sf" -gt "${#_bt_fs[@]}" ]; then
		_bt_k=
		return 0
	fi
	start=${_bt_fs[sf-1]}
	case $mods in
	*b*)	while [ "$start" -lt "$_bt_linelen" ]; do
			case ${s:start:1} in
			[[:blank:]])	start=$(( start + 1 )) ;;
			*)		break ;;
			esac
		done ;;
	esac
	start=$(( start + sc - 1 ))
	if [ "$ef" -eq 0 ]; then
		end=$_bt_linelen
	elif [ "$ef" -gt "${#_bt_fs[@]}" ]; then
		end=$_bt_linelen
	else
		_bt_sort_fend "$ef"
		end=$_bt_fe
		if [ "$ec" -gt 0 ]; then
			end=$(( _bt_fs[ef-1] + ec ))
			[ "$end" -gt "$_bt_linelen" ] && end=$_bt_linelen
		fi
	fi
	[ "$end" -lt "$start" ] && end=$start
	_bt_k=${s:start:end-start}
	return 0
}

# Apply -d, -f and -i to a key.
_bt_sort_fold() {
	local s=$1 mods=$2 out= i c
	case $mods in
	*[dfi]*)	;;
	*)		_bt_k=$s; return 0 ;;
	esac
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		case $mods in
		*i*)	case $c in
			[[:print:]])	;;
			*)		continue ;;
			esac ;;
		esac
		case $mods in
		*d*)	case $c in
			[[:alnum:][:blank:]])	;;
			*)			continue ;;
			esac ;;
		esac
		case $mods in
		*f*)	case $c in
			[[:lower:]])	c=${c^} ;;
			esac ;;
		esac
		out=$out$c
	done
	_bt_k=$out
	return 0
}

# Numeric comparison of $1 and $2 into _bt_c, as sort defines it.
_bt_sort_numcmp() {
	local a=$1 b=$2 sa=1 sb=1 ia fa ib fb
	a=${a#"${a%%[![:blank:]]*}"}
	b=${b#"${b%%[![:blank:]]*}"}
	case $a in -*) sa=-1; a=${a#-} ;; +*) a=${a#+} ;; esac
	case $b in -*) sb=-1; b=${b#-} ;; +*) b=${b#+} ;; esac
	ia=${a%%[!0-9]*}; fa=
	case $a in "$ia."*) fa=${a#"$ia."}; fa=${fa%%[!0-9]*} ;; esac
	ib=${b%%[!0-9]*}; fb=
	case $b in "$ib."*) fb=${b#"$ib."}; fb=${fb%%[!0-9]*} ;; esac
	# strip leading zeros so lengths can be compared
	while [ "${#ia}" -gt 1 ] && [ "${ia:0:1}" = 0 ]; do ia=${ia:1}; done
	while [ "${#ib}" -gt 1 ] && [ "${ib:0:1}" = 0 ]; do ib=${ib:1}; done
	[ -n "$ia" ] || ia=0
	[ -n "$ib" ] || ib=0
	# a value of zero has no sign
	if [ "$ia" = 0 ] && [ -z "${fa//0/}" ]; then sa=1; fi
	if [ "$ib" = 0 ] && [ -z "${fb//0/}" ]; then sb=1; fi
	if [ "$sa" != "$sb" ]; then
		[ "$sa" -lt "$sb" ] && _bt_c=-1 || _bt_c=1
		return 0
	fi
	_bt_c=0
	if [ "${#ia}" -ne "${#ib}" ]; then
		[ "${#ia}" -lt "${#ib}" ] && _bt_c=-1 || _bt_c=1
	elif [ "$ia" != "$ib" ]; then
		[[ $ia < $ib ]] && _bt_c=-1 || _bt_c=1
	else
		while [ "${#fa}" -lt "${#fb}" ]; do fa=${fa}0; done
		while [ "${#fb}" -lt "${#fa}" ]; do fb=${fb}0; done
		if [ "$fa" != "$fb" ]; then
			[[ $fa < $fb ]] && _bt_c=-1 || _bt_c=1
		fi
	fi
	[ "$sa" -lt 0 ] && _bt_c=$(( -_bt_c ))
	return 0
}

# Compare lines $1 and $2 on the keys alone, into _bt_c.
_bt_sort_keycmp() {
	local a=$1 b=$2 k ka kb mods
	local -a _bt_fs=()
	local _bt_fe _bt_linelen _bt_k
	for (( k = 0; k < ${#_bt_ksf[@]}; k++ )); do
		mods=${_bt_kmod[k]}
		_bt_sort_key "$a" "$k"; ka=$_bt_k
		_bt_sort_key "$b" "$k"; kb=$_bt_k
		_bt_sort_fold "$ka" "$mods"; ka=$_bt_k
		_bt_sort_fold "$kb" "$mods"; kb=$_bt_k
		case $mods in
		*n*)	_bt_sort_numcmp "$ka" "$kb" ;;
		*)	if [ "$ka" = "$kb" ]; then
				_bt_c=0
			elif [[ $ka < $kb ]]; then
				_bt_c=-1
			else
				_bt_c=1
			fi ;;
		esac
		if [ "$_bt_c" -ne 0 ]; then
			case $mods in
			*r*)	_bt_c=$(( -_bt_c )) ;;
			esac
			return 0
		fi
	done
	_bt_c=0
	return 0
}

# Full comparison: the keys, then the whole line as a last resort.
_bt_sort_cmp() {
	local a=$1 b=$2
	_bt_sort_keycmp "$a" "$b"
	[ "$_bt_c" -ne 0 ] && return 0
	# Under -u the whole-line tiebreak is dropped, so the merge being
	# stable is what decides which line of an equal run survives.
	[ "$_bt_nolast" = 1 ] && return 0
	if [ "$a" = "$b" ]; then
		_bt_c=0
	elif [[ $a < $b ]]; then
		_bt_c=-1
	else
		_bt_c=1
	fi
	[ "$_bt_rev" = 1 ] && _bt_c=$(( -_bt_c ))
	return 0
}

sort () {
	local LC_ALL=C
	local arg opt val file fd status=0 out= merge=0 check=0 uniq=0
	local gmods= i j n width lo mid hi a b line prev
	local _bt_sep= _bt_rev=0 _bt_nolast=0 _bt_c _bt_reason
	local -a _bt_ksf=() _bt_ksc=() _bt_kef=() _bt_kec=() _bt_kmod=()
	local -a lines=() idx=() tmp=()

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
				b|d|f|i|n)	gmods=$gmods$opt ;;
				r)	_bt_rev=1; gmods=${gmods}r ;;
				u)	uniq=1 ;;
				m)	merge=1 ;;
				c)	check=1 ;;
				o|t|k)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "sort: option requires an argument -- $opt"
						return 2
					fi
					case $opt in
					o)	out=$val ;;
					t)	_bt_sep=${val:0:1} ;;
					k)	_bt_sort_addkey "$val" || return 2 ;;
					esac ;;
				*)	_bt_err "sort: illegal option -- $opt"
					_bt_err "usage: sort [-m] [-o output] [-bdfinru] [-t char] [-k keydef]... [file...]"
					return 2 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	[ "$uniq" = 1 ] && _bt_nolast=1
	# With no -k the whole line is the key.
	if [ "${#_bt_ksf[@]}" -eq 0 ]; then
		_bt_ksf=(1); _bt_ksc=(1); _bt_kef=(0); _bt_kec=(0); _bt_kmod=("$gmods")
	else
		for (( i = 0; i < ${#_bt_kmod[@]}; i++ )); do
			[ -n "${_bt_kmod[i]}" ] || _bt_kmod[i]=$gmods
		done
	fi

	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "sort: $file: $_bt_reason"
			return 2
		fi
		line=
		while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
			lines+=("$line")
			line=
		done
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	n=${#lines[@]}

	if [ "$check" = 1 ]; then
		for (( i = 1; i < n; i++ )); do
			if [ "$uniq" = 1 ]; then
				_bt_sort_keycmp "${lines[i-1]}" "${lines[i]}"
			else
				_bt_sort_cmp "${lines[i-1]}" "${lines[i]}"
			fi
			if [ "$_bt_c" -gt 0 ] || { [ "$uniq" = 1 ] && [ "$_bt_c" -eq 0 ]; }; then
				_bt_err "sort: $file:$(( i + 1 )): disorder: ${lines[i]}"
				return 1
			fi
		done
		return 0
	fi

	# bottom-up merge sort over an index array
	for (( i = 0; i < n; i++ )); do idx[i]=$i; done
	width=1
	while [ "$width" -lt "$n" ]; do
		i=0
		while [ "$i" -lt "$n" ]; do
			lo=$i
			mid=$(( i + width )); [ "$mid" -gt "$n" ] && mid=$n
			hi=$(( i + 2 * width )); [ "$hi" -gt "$n" ] && hi=$n
			a=$lo b=$mid j=$lo
			while [ "$a" -lt "$mid" ] && [ "$b" -lt "$hi" ]; do
				_bt_sort_cmp "${lines[idx[a]]}" "${lines[idx[b]]}"
				if [ "$_bt_c" -le 0 ]; then
					tmp[j]=${idx[a]}; a=$(( a + 1 ))
				else
					tmp[j]=${idx[b]}; b=$(( b + 1 ))
				fi
				j=$(( j + 1 ))
			done
			while [ "$a" -lt "$mid" ]; do tmp[j]=${idx[a]}; a=$(( a + 1 )); j=$(( j + 1 )); done
			while [ "$b" -lt "$hi" ]; do tmp[j]=${idx[b]}; b=$(( b + 1 )); j=$(( j + 1 )); done
			i=$hi
		done
		for (( i = 0; i < n; i++ )); do idx[i]=${tmp[i]}; done
		width=$(( width * 2 ))
	done

	if [ -n "$out" ]; then
		if ! { exec {fd}>"$out"; } 2>/dev/null; then
			_bt_err "sort: cannot create $out"
			return 2
		fi
	else
		fd=1
	fi
	prev=
	for (( i = 0; i < n; i++ )); do
		line=${lines[idx[i]]}
		if [ "$uniq" = 1 ] && [ "$i" -gt 0 ]; then
			_bt_sort_keycmp "$prev" "$line"
			[ "$_bt_c" -eq 0 ] && continue
		fi
		printf '%s\n' "$line" >&"$fd"
		prev=$line
	done
	[ -n "$out" ] && exec {fd}>&-
	return "$status"
}

# Parse one -k keydef into the parallel key arrays.
_bt_sort_addkey() {
	local spec=$1 s e sf sc ef=0 ec=0 mods=
	s=${spec%%,*}
	case $spec in
	*,*)	e=${spec#*,} ;;
	*)	e= ;;
	esac
	sf=${s%%[!0-9]*}
	[ -n "$sf" ] || { _bt_err "sort: invalid key: $spec"; return 1; }
	s=${s#"$sf"}
	sc=1
	case $s in
	.*)	s=${s#.}
		sc=${s%%[!0-9]*}
		s=${s#"$sc"}
		[ -n "$sc" ] || sc=1 ;;
	esac
	mods=$mods$s
	if [ -n "$e" ]; then
		ef=${e%%[!0-9]*}
		[ -n "$ef" ] || { _bt_err "sort: invalid key: $spec"; return 1; }
		e=${e#"$ef"}
		case $e in
		.*)	e=${e#.}
			ec=${e%%[!0-9]*}
			e=${e#"$ec"}
			[ -n "$ec" ] || ec=0 ;;
		esac
		mods=$mods$e
	fi
	# Only the ordering options are valid inside a key definition.
	case $mods in
	*[!bdfinr]*)	_bt_err "sort: invalid key modifier in: $spec"; return 1 ;;
	esac
	_bt_ksf+=("$sf"); _bt_ksc+=("$sc"); _bt_kef+=("$ef"); _bt_kec+=("$ec")
	_bt_kmod+=("$mods")
	return 0
}

# ---------------------------------------------------------------------------
# join -- POSIX.1-2017:
#	join [-a file_number] [-e string] [-o list] [-t char] [-v file_number]
#	     [-1 field] [-2 field] file1 file2
# ---------------------------------------------------------------------------

# Split $1 into _bt_jf.  Without -t a field is a run of non-blanks and the
# leading blanks are dropped; with -t every separator starts a new field.
_bt_join_split() {
	local s=$1 hadf=0
	if [ -n "$_bt_jsep" ]; then
		_bt_fld=()
		_bt_split "$s" "$_bt_jsep"
		_bt_jf=(${_bt_fld[@]+"${_bt_fld[@]}"})
		return 0
	fi
	case $- in *f*) hadf=1 ;; esac
	set -f
	local IFS=$' \t'
	set -- $s
	_bt_jf=("$@")
	[ "$hadf" = 1 ] || set +f
	return 0
}

# Build one output line for the pair currently in _bt_a1/_bt_a2 (either may
# be empty for an unpaired line) into _bt_out.
_bt_join_line() {
	local which=$1 spec f n i first=1 v
	_bt_out=
	if [ -n "$_bt_olist" ]; then
		for spec in $_bt_olist; do
			case $spec in
			0)	v=$_bt_key ;;
			1.*)	n=${spec#1.}
				if [ "$which" = 2 ]; then v=$_bt_efill
				else
					v=${_bt_f1[n-1]-}
					[ -n "$v" ] || v=$_bt_efill
				fi ;;
			2.*)	n=${spec#2.}
				if [ "$which" = 1 ]; then v=$_bt_efill
				else
					v=${_bt_f2[n-1]-}
					[ -n "$v" ] || v=$_bt_efill
				fi ;;
			*)	v= ;;
			esac
			if [ "$first" = 1 ]; then _bt_out=$v; first=0
			else _bt_out=$_bt_out$_bt_osep$v; fi
		done
		return 0
	fi
	_bt_out=$_bt_key
	if [ "$which" != 2 ]; then
		for (( i = 0; i < ${#_bt_f1[@]}; i++ )); do
			[ $(( i + 1 )) -eq "$_bt_j1" ] && continue
			_bt_out=$_bt_out$_bt_osep${_bt_f1[i]}
		done
	fi
	if [ "$which" != 1 ]; then
		for (( i = 0; i < ${#_bt_f2[@]}; i++ )); do
			[ $(( i + 1 )) -eq "$_bt_j2" ] && continue
			_bt_out=$_bt_out$_bt_osep${_bt_f2[i]}
		done
	fi
	return 0
}

join () {
	local LC_ALL=C
	local arg opt val fd1 fd2 status=0 _bt_reason
	local a1=0 a2=0 v1=0 v2=0
	local _bt_jsep= _bt_osep=' ' _bt_olist= _bt_efill= _bt_j1=1 _bt_j2=1
	local _bt_key _bt_out
	local -a _bt_jf=() _bt_fld=() _bt_f1=() _bt_f2=() l1=() l2=() k1=() k2=()
	local i j n m gi gj ge1 ge2 c line

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
				a|e|o|t|v|1|2)
					if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "join: option requires an argument -- $opt"
						return 1
					fi
					case $opt in
					a)	case $val in
						1)	a1=1 ;;
						2)	a2=1 ;;
						*)	_bt_err "join: invalid file number: $val"; return 1 ;;
						esac ;;
					v)	case $val in
						1)	v1=1 ;;
						2)	v2=1 ;;
						*)	_bt_err "join: invalid file number: $val"; return 1 ;;
						esac ;;
					e)	_bt_efill=$val ;;
					o)	_bt_olist="${_bt_olist} ${val//,/ }" ;;
					t)	_bt_jsep=${val:0:1}; _bt_osep=$_bt_jsep ;;
					1)	_bt_isnum "$val" || { _bt_err "join: invalid field number: $val"; return 1; }
						_bt_j1=$(( 10#$val )) ;;
					2)	_bt_isnum "$val" || { _bt_err "join: invalid field number: $val"; return 1; }
						_bt_j2=$(( 10#$val )) ;;
					esac ;;
				*)	_bt_err "join: illegal option -- $opt"
					_bt_err "usage: join [-a n] [-e s] [-o list] [-t c] [-v n] [-1 f] [-2 f] file1 file2"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$#" -ne 2 ]; then
		_bt_err "usage: join [-a n] [-e s] [-o list] [-t c] [-v n] [-1 f] [-2 f] file1 file2"
		return 1
	fi

	if [ "$1" = - ]; then fd1=0
	elif [ -d "$1" ] || ! { exec {fd1}<"$1"; } 2>/dev/null; then
		_bt_why "$1"; _bt_err "join: $1: $_bt_reason"; return 1
	fi
	line=
	while IFS= read -r line <&"$fd1" || [ -n "$line" ]; do
		l1+=("$line")
		_bt_join_split "$line"
		k1+=("${_bt_jf[_bt_j1-1]-}")
		line=
	done
	[ "$fd1" = 0 ] || exec {fd1}<&-

	if [ "$2" = - ]; then fd2=0
	elif [ -d "$2" ] || ! { exec {fd2}<"$2"; } 2>/dev/null; then
		_bt_why "$2"; _bt_err "join: $2: $_bt_reason"; return 1
	fi
	line=
	while IFS= read -r line <&"$fd2" || [ -n "$line" ]; do
		l2+=("$line")
		_bt_join_split "$line"
		k2+=("${_bt_jf[_bt_j2-1]-}")
		line=
	done
	[ "$fd2" = 0 ] || exec {fd2}<&-

	n=${#l1[@]} m=${#l2[@]}
	i=0 j=0
	while [ "$i" -lt "$n" ] || [ "$j" -lt "$m" ]; do
		if [ "$i" -ge "$n" ]; then c=1
		elif [ "$j" -ge "$m" ]; then c=-1
		elif [ "${k1[i]}" = "${k2[j]}" ]; then c=0
		elif [[ ${k1[i]} < ${k2[j]} ]]; then c=-1
		else c=1
		fi
		if [ "$c" -lt 0 ]; then
			if [ "$a1" = 1 ] || [ "$v1" = 1 ]; then
				_bt_key=${k1[i]}
				_bt_join_split "${l1[i]}"; _bt_f1=(${_bt_jf[@]+"${_bt_jf[@]}"}); _bt_f2=()
				_bt_join_line 1
				printf '%s\n' "$_bt_out"
			fi
			i=$(( i + 1 ))
			continue
		fi
		if [ "$c" -gt 0 ]; then
			if [ "$a2" = 1 ] || [ "$v2" = 1 ]; then
				_bt_key=${k2[j]}
				_bt_join_split "${l2[j]}"; _bt_f2=(${_bt_jf[@]+"${_bt_jf[@]}"}); _bt_f1=()
				_bt_join_line 2
				printf '%s\n' "$_bt_out"
			fi
			j=$(( j + 1 ))
			continue
		fi
		# equal keys: every line of one group against every line of the other
		ge1=$i
		while [ "$ge1" -lt "$n" ] && [ "${k1[ge1]}" = "${k1[i]}" ]; do ge1=$(( ge1 + 1 )); done
		ge2=$j
		while [ "$ge2" -lt "$m" ] && [ "${k2[ge2]}" = "${k2[j]}" ]; do ge2=$(( ge2 + 1 )); done
		if [ "$v1" = 0 ] && [ "$v2" = 0 ]; then
			for (( gi = i; gi < ge1; gi++ )); do
				for (( gj = j; gj < ge2; gj++ )); do
					_bt_key=${k1[gi]}
					_bt_join_split "${l1[gi]}"; _bt_f1=(${_bt_jf[@]+"${_bt_jf[@]}"})
					_bt_join_split "${l2[gj]}"; _bt_f2=(${_bt_jf[@]+"${_bt_jf[@]}"})
					_bt_join_line 0
					printf '%s\n' "$_bt_out"
				done
			done
		fi
		i=$ge1 j=$ge2
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# csplit -- POSIX.1-2017: csplit [-ks] [-f prefix] [-n number] file arg...
#
# On an error csplit is supposed to remove the files it created; unlink() is
# out of reach, so they are truncated to nothing instead and named on stderr.
# ---------------------------------------------------------------------------
csplit () {
	local LC_ALL=C
	local arg opt val prefix=xx width=2 keep=0 silent=0 file fd status=0
	local i n cur=0 idx=0 target off spec rep name bytes line re _bt_re _bt_reason
	local -a lines=() made=()

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
				k)	keep=1 ;;
				s)	silent=1 ;;
				f|n)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "csplit: option requires an argument -- $opt"
						return 1
					fi
					if [ "$opt" = f ]; then
						prefix=$val
					else
						_bt_isnum "$val" || { _bt_err "csplit: invalid number: $val"; return 1; }
						width=$(( 10#$val ))
					fi ;;
				*)	_bt_err "csplit: illegal option -- $opt"
					_bt_err "usage: csplit [-ks] [-f prefix] [-n number] file arg..."
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$#" -lt 2 ]; then
		_bt_err "usage: csplit [-ks] [-f prefix] [-n number] file arg..."
		return 1
	fi
	file=$1
	shift

	if [ "$file" = - ]; then
		fd=0
	elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
		_bt_why "$file"
		_bt_err "csplit: $file: $_bt_reason"
		return 1
	fi
	line=
	while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
		lines+=("$line")
		line=
	done
	[ "$fd" = 0 ] || exec {fd}<&-
	n=${#lines[@]}

	# Write lines [cur, $1) to the next output file.
	_bt_csplit_write() {
		local upto=$1 quiet=$2 j
		printf -v name "%s%0*d" "$prefix" "$width" "$idx"
		if ! { exec {fd}>"$name"; } 2>/dev/null; then
			_bt_err "csplit: cannot create $name"
			return 1
		fi
		made+=("$name")
		bytes=0
		for (( j = cur; j < upto; j++ )); do
			printf '%s\n' "${lines[j]}" >&"$fd"
			bytes=$(( bytes + ${#lines[j]} + 1 ))
		done
		exec {fd}>&-
		[ "$silent" = 1 ] || [ "$quiet" = 1 ] || printf '%d\n' "$bytes"
		idx=$(( idx + 1 ))
		cur=$upto
		return 0
	}
	_bt_csplit_fail() {
		# The remainder is still written and counted before the error
		# is reported, which is what csplit does.
		_bt_csplit_write "$n" 0
		_bt_err "csplit: '$1': $2"
		if [ "$keep" = 0 ] && [ "${#made[@]}" -gt 0 ]; then
			for name in "${made[@]}"; do
				: > "$name" 2>/dev/null
			done
			_bt_err "csplit: could not remove ${made[*]} (no unlink from a builtin); truncated instead"
		fi
		unset -f _bt_csplit_write _bt_csplit_fail
		return 1
	}

	rep=1
	for spec in "$@"; do
		case $spec in
		'{'*'}')
			val=${spec#\{}; val=${val%\}}
			if ! _bt_isnum "$val"; then
				_bt_csplit_fail "$spec" "invalid repeat count"
				return 1
			fi
			rep=$(( 10#$val ))
			# repeat the previous operand
			for (( i = 0; i < rep; i++ )); do
				# A repeated line number means that many more lines
				# each time, not the same absolute line again.
				if ! _bt_csplit_apply "$_bt_last" 1; then
					return 1
				fi
			done
			rep=1
			continue ;;
		esac
		_bt_last=$spec
		if ! _bt_csplit_apply "$spec"; then
			return 1
		fi
	done

	_bt_csplit_write "$n" 0
	unset -f _bt_csplit_write _bt_csplit_fail
	return "$status"
}

# Apply one csplit operand.  Relies on the locals of its caller.
_bt_csplit_apply() {
	local spec=$1 rel=${2:-0} target off re skipit=0 j
	case $spec in
	/*)	re=${spec#/}
		case $re in
		*/*)	off=${re##*/}; re=${re%/*} ;;
		*)	off= ;;
		esac ;;
	%*)	skipit=1
		re=${spec#%}
		case $re in
		*%*)	off=${re##*%}; re=${re%\%*} ;;
		*)	off= ;;
		esac ;;
	*)	if ! _bt_isnum "$spec"; then
			_bt_csplit_fail "$spec" "invalid pattern"
			return 1
		fi
		if [ "$rel" = 1 ]; then
			target=$(( cur + 10#$spec ))
		else
			target=$(( 10#$spec - 1 ))
		fi
		if [ "$target" -lt "$cur" ] || [ "$target" -gt "$n" ]; then
			_bt_csplit_fail "$spec" "line number out of range"
			return 1
		fi
		_bt_csplit_write "$target" 0 || return 1
		return 0 ;;
	esac

	_bt_bre2ere "$re"
	re=$_bt_re
	target=-1
	for (( j = cur + 1; j < n; j++ )); do
		if [[ ${lines[j]} =~ $re ]]; then
			target=$j
			break
		fi
	done
	if [ "$target" -lt 0 ]; then
		_bt_csplit_fail "$spec" "match not found"
		return 1
	fi
	if [ -n "$off" ]; then
		target=$(( target + off ))
	fi
	if [ "$target" -lt "$cur" ] || [ "$target" -gt "$n" ]; then
		_bt_csplit_fail "$spec" "line number out of range"
		return 1
	fi
	if [ "$skipit" = 1 ]; then
		# %regexp% moves the position without writing anything
		cur=$target
		return 0
	fi
	_bt_csplit_write "$target" 0 || return 1
	return 0
}

# ---------------------------------------------------------------------------
# grep -- POSIX.1-2017:
#	grep [-E|-F] [-c|-l|-q] [-insvx] -e pattern_list... [-f pattern_file]...
#	     [file...]
#	grep [-E|-F] [-c|-l|-q] [-insvx] pattern_list [file...]
# ---------------------------------------------------------------------------

# Does $1 match any of the patterns?  Relies on the caller's locals.
_bt_grep_match() {
	local line=$1 p
	for p in ${_bt_pat[@]+"${_bt_pat[@]}"}; do
		if [ "$_bt_fixed" = 1 ]; then
			if [ "$_bt_whole" = 1 ]; then
				[[ $line == "$p" ]] && return 0
			else
				[[ $line == *"$p"* ]] && return 0
			fi
		else
			[[ $line =~ $p ]] && return 0
		fi
	done
	return 1
}

grep () {
	local LC_ALL=C
	local arg opt val file fd status=1 err=0 _bt_reason _bt_re
	local _bt_fixed=0 _bt_whole=0 ere=0 icase=0 count=0 listf=0 quiet=0
	local nums=0 quietfail=0 invert=0 havepat=0 prefix=0
	local line n hits total p saved_nocase
	local -a _bt_pat=() files=()

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
				E)	ere=1 ;;
				F)	_bt_fixed=1 ;;
				c)	count=1 ;;
				l)	listf=1 ;;
				q)	quiet=1 ;;
				i)	icase=1 ;;
				n)	nums=1 ;;
				s)	quietfail=1 ;;
				v)	invert=1 ;;
				x)	_bt_whole=1 ;;
				e|f)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "grep: option requires an argument -- $opt"
						return 2
					fi
					if [ "$opt" = e ]; then
						while [ -n "$val" ]; do
							_bt_pat+=("${val%%$'\n'*}")
							case $val in
							*$'\n'*)	val=${val#*$'\n'} ;;
							*)		val= ;;
							esac
						done
					else
						if ! { exec {fd}<"$val"; } 2>/dev/null; then
							_bt_err "grep: $val: No such file or directory"
							return 2
						fi
						line=
						while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
							_bt_pat+=("$line")
							line=
						done
						exec {fd}<&-
					fi
					havepat=1 ;;
				*)	_bt_err "grep: illegal option -- $opt"
					_bt_err "usage: grep [-E|-F] [-c|-l|-q] [-insvx] pattern [file...]"
					return 2 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	if [ "$havepat" = 0 ]; then
		if [ "$#" -eq 0 ]; then
			_bt_err "usage: grep [-E|-F] [-c|-l|-q] [-insvx] pattern [file...]"
			return 2
		fi
		val=$1
		shift
		while [ -n "$val" ]; do
			_bt_pat+=("${val%%$'\n'*}")
			case $val in
			*$'\n'*)	val=${val#*$'\n'} ;;
			*)		val= ;;
			esac
		done
	fi

	# A basic regular expression is turned into the extended one bash's =~
	# understands; -F patterns are left exactly as they are.
	if [ "$_bt_fixed" = 0 ]; then
		for (( n = 0; n < ${#_bt_pat[@]}; n++ )); do
			if [ "$ere" = 0 ]; then
				_bt_bre2ere "${_bt_pat[n]}"
				_bt_pat[n]=$_bt_re
			fi
			[ "$_bt_whole" = 1 ] && _bt_pat[n]='^('${_bt_pat[n]}')$'
		done
	fi

	saved_nocase=$(shopt -p nocasematch)
	[ "$icase" = 1 ] && shopt -s nocasematch

	[ "$#" -eq 0 ] && set -- -
	[ "$#" -gt 1 ] && prefix=1

	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			if [ "$quietfail" = 0 ]; then
				_bt_why "$file"
				_bt_err "grep: $file: $_bt_reason"
			fi
			err=2
			continue
		fi
		n=0 hits=0
		line=
		while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
			n=$(( n + 1 ))
			if _bt_grep_match "$line"; then p=1; else p=0; fi
			[ "$invert" = 1 ] && p=$(( 1 - p ))
			if [ "$p" = 1 ]; then
				hits=$(( hits + 1 ))
				status=0
				if [ "$quiet" = 1 ]; then
					eval "$saved_nocase"
					[ "$fd" = 0 ] || exec {fd}<&-
					return 0
				fi
				if [ "$listf" = 1 ]; then
					printf '%s\n' "$file"
					break
				fi
				if [ "$count" = 0 ]; then
					if [ "$prefix" = 1 ] && [ "$nums" = 1 ]; then
						printf '%s:%d:%s\n' "$file" "$n" "$line"
					elif [ "$prefix" = 1 ]; then
						printf '%s:%s\n' "$file" "$line"
					elif [ "$nums" = 1 ]; then
						printf '%d:%s\n' "$n" "$line"
					else
						printf '%s\n' "$line"
					fi
				fi
			fi
			line=
		done
		[ "$fd" = 0 ] || exec {fd}<&-
		if [ "$count" = 1 ] && [ "$listf" = 0 ]; then
			if [ "$prefix" = 1 ]; then
				printf '%s:%d\n' "$file" "$hits"
			else
				printf '%d\n' "$hits"
			fi
		fi
	done

	eval "$saved_nocase"
	[ "$err" = 2 ] && return 2
	return "$status"
}

# ---------------------------------------------------------------------------
# xargs -- POSIX.1-2017:
#	xargs [-t] [-E eofstr] [-I replstr] [-L number] [-n number] [-s size]
#	      [utility [argument...]]
# ---------------------------------------------------------------------------
xargs () {
	local LC_ALL=C
	local arg opt val eofstr= repl= maxargs=0 maxlines=0 maxsize=0 trace=0
	local i c q tok line status=0 rc
	local -a words=() cmd=() batch=()

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-*)	[ "$1" = - ] && break
			arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				t)	trace=1 ;;
				p)	;;	# prompting needs a terminal dialogue
				E|I|L|n|s)
					if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "xargs: option requires an argument -- $opt"
						return 1
					fi
					case $opt in
					E)	eofstr=$val ;;
					I)	repl=$val; maxlines=1 ;;
					L)	maxlines=$(( 10#$val )) ;;
					n)	maxargs=$(( 10#$val )) ;;
					s)	maxsize=$(( 10#$val )) ;;
					esac ;;
				*)	_bt_err "xargs: illegal option -- $opt"
					_bt_err "usage: xargs [-t] [-E eof] [-I repl] [-L n] [-n n] [-s size] [utility [arg...]]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$#" -eq 0 ]; then
		cmd=(echo)
	else
		cmd=("$@")
	fi

	if [ -n "$repl" ] || [ "$maxlines" -gt 0 ]; then
		# Line at a time: -I substitutes the whole line.
		line=
		while IFS= read -r line || [ -n "$line" ]; do
			if [ -n "$eofstr" ] && [ "$line" = "$eofstr" ]; then break; fi
			batch=()
			if [ -n "$repl" ]; then
				for tok in "${cmd[@]}"; do
					batch+=("${tok//"$repl"/$line}")
				done
			else
				batch=("${cmd[@]}")
				_bt_xargs_words "$line"
				batch+=(${words[@]+"${words[@]}"})
			fi
			[ "$trace" = 1 ] && printf '%s\n' "${batch[*]}" >&2
			"${batch[@]}" || status=$?
			line=
		done
		return "$status"
	fi

	# Otherwise the whole input is one stream of quoted words.
	line=
	words=()
	while IFS= read -r line || [ -n "$line" ]; do
		_bt_xargs_words "$line" append
		line=
	done
	if [ -n "$eofstr" ]; then
		for (( i = 0; i < ${#words[@]}; i++ )); do
			if [ "${words[i]}" = "$eofstr" ]; then
				words=("${words[@]:0:i}")
				break
			fi
		done
	fi
	if [ "${#words[@]}" -eq 0 ]; then
		[ "$trace" = 1 ] && printf '%s\n' "${cmd[*]}" >&2
		"${cmd[@]}"
		return $?
	fi
	i=0
	while [ "$i" -lt "${#words[@]}" ]; do
		if [ "$maxargs" -gt 0 ]; then
			batch=("${cmd[@]}" "${words[@]:i:maxargs}")
			i=$(( i + maxargs ))
		else
			batch=("${cmd[@]}" "${words[@]}")
			i=${#words[@]}
		fi
		[ "$trace" = 1 ] && printf '%s\n' "${batch[*]}" >&2
		"${batch[@]}" || status=$?
	done
	return "$status"
}

# Split $1 into words the way xargs does: blanks separate, quotes group, a
# backslash protects the next character.  Appends when $2 is given.
_bt_xargs_words() {
	local s=$1 append=$2 i=0 n=${#1} c tok= have=0 quote=
	[ -n "$append" ] || words=()
	while [ "$i" -lt "$n" ]; do
		c=${s:i:1}
		i=$(( i + 1 ))
		if [ -n "$quote" ]; then
			if [ "$c" = "$quote" ]; then
				quote=
			else
				tok=$tok$c
			fi
			have=1
			continue
		fi
		case $c in
		\\)	if [ "$i" -lt "$n" ]; then
				tok=$tok${s:i:1}
				i=$(( i + 1 ))
				have=1
			fi ;;
		\'|\")	quote=$c; have=1 ;;
		[$' \t'])
			if [ "$have" = 1 ]; then
				words+=("$tok")
				tok= have=0
			fi ;;
		*)	tok=$tok$c; have=1 ;;
		esac
	done
	[ "$have" = 1 ] && words+=("$tok")
	return 0
}

# ---------------------------------------------------------------------------
# nohup -- POSIX.1-2017: nohup utility [argument...]
#
# The file it creates should be mode 0600; without chmod() it lands on
# whatever the umask allows.
# ---------------------------------------------------------------------------
nohup () {
	local LC_ALL=C prog out rc
	if [ "$#" -eq 0 ]; then
		_bt_err "usage: nohup utility [argument...]"
		return 127
	fi
	prog=$1
	case $prog in
	*/*)	if [ ! -e "$prog" ]; then
			_bt_err "nohup: cannot run $prog: No such file or directory"
			return 127
		fi
		if [ ! -x "$prog" ] || [ -d "$prog" ]; then
			_bt_err "nohup: cannot run $prog: Permission denied"
			return 126
		fi ;;
	*)	prog=$(command -v "$1" 2>/dev/null)
		if [ -z "$prog" ]; then
			_bt_err "nohup: cannot run $1: No such file or directory"
			return 127
		fi ;;
	esac
	(
		trap '' HUP
		if [ -t 1 ]; then
			out=nohup.out
			if ! { exec >> "$out"; } 2>/dev/null; then
				out=${HOME:-.}/nohup.out
				exec >> "$out" || exit 127
			fi
			_bt_err "nohup: appending output to '$out'"
			[ -t 2 ] && exec 2>&1
		fi
		"$prog" "${@:2}"
	)
	return $?
}

# ---------------------------------------------------------------------------
# pr -- POSIX.1-2017:
#	pr [+page] [-column] [-adFmrt] [-e[char][gap]] [-h header] [-i[char][gap]]
#	   [-l lines] [-n[char][width]] [-o offset] [-s[char]] [-w width] [file...]
# ---------------------------------------------------------------------------

# Move from column $1 to column $2 with tabs where they fit, then spaces.
_bt_pr_pad() {
	local at=$1 to=$2 nxt out=
	while :; do
		nxt=$(( at / 8 * 8 + 8 ))
		[ "$nxt" -le "$to" ] || break
		out=$out$'\t'
		at=$nxt
	done
	if [ "$at" -lt "$to" ]; then
		printf -v nxt '%*s' $(( to - at )) ''
		out=$out$nxt
	fi
	_bt_pad=$out
	return 0
}

pr () {
	local LC_ALL=C
	local arg opt val file fd status=0 _bt_reason _bt_pad
	local cols=1 across=0 dbl=0 formfeed=0 merge=0 noheader=0 numbered=0
	local numwidth=5 numchar=$'\t' header= offset=0 width=72 startpage=1
	local sepchar= usesep=0 pagelen=66 bodylen line n i j c
	local -a lines=() out=()
	local page total colw row rows idx now

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-)	break ;;
		+*)	startpage=${1#+}
			_bt_isnum "$startpage" || { _bt_err "pr: invalid page: $startpage"; return 1; }
			startpage=$(( 10#$startpage ))
			shift ;;
		-[0-9]*)	cols=${1#-}
			_bt_isnum "$cols" || { _bt_err "pr: invalid column count"; return 1; }
			cols=$(( 10#$cols ))
			shift ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				a)	across=1 ;;
				d)	dbl=1 ;;
				F|f)	formfeed=1 ;;
				m)	merge=1 ;;
				r)	;;	# quiet about files that cannot be opened
				t)	noheader=1 ;;
				n)	numbered=1
					if [ -n "$arg" ]; then
						case ${arg:0:1} in
						[0-9])	numwidth=${arg%%[!0-9]*}; arg=${arg#"$numwidth"} ;;
						*)	numchar=${arg:0:1}; arg=${arg:1}
							case $arg in
							[0-9]*)	numwidth=${arg%%[!0-9]*}; arg=${arg#"$numwidth"} ;;
							esac ;;
						esac
					fi
					numwidth=$(( 10#$numwidth )) ;;
				s)	usesep=1
					if [ -n "$arg" ]; then
						sepchar=${arg:0:1}; arg=${arg:1}
					else
						sepchar=$'\t'
					fi ;;
				h|l|o|w)
					if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "pr: option requires an argument -- $opt"
						return 1
					fi
					case $opt in
					h)	header=$val ;;
					l)	pagelen=$(( 10#$val )) ;;
					o)	offset=$(( 10#$val )) ;;
					w)	width=$(( 10#$val )) ;;
					esac ;;
				e|i)	arg= ;;	# tab expansion: accepted, input is left as is
				*)	_bt_err "pr: illegal option -- $opt"
					_bt_err "usage: pr [+page] [-column] [-adFmrt] [-h header] [-l lines] [-o offset] [-w width] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	[ "$cols" -ge 1 ] || cols=1
	[ "$pagelen" -ge 1 ] || pagelen=66

	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "pr: $file: $_bt_reason"
			status=1
			continue
		fi
		lines=()
		line=
		while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
			lines+=("$line")
			line=
		done
		[ "$fd" = 0 ] || exec {fd}<&-

		if [ "$dbl" = 1 ]; then
			out=()
			for line in ${lines[@]+"${lines[@]}"}; do
				out+=("$line" '')
			done
			lines=(${out[@]+"${out[@]}"})
		fi
		if [ "$numbered" = 1 ]; then
			out=()
			for (( i = 0; i < ${#lines[@]}; i++ )); do
				printf -v val '%*d' "$numwidth" $(( i + 1 ))
				out+=("$val$numchar${lines[i]}")
			done
			lines=(${out[@]+"${out[@]}"})
		fi

		total=${#lines[@]}
		if [ "$noheader" = 1 ]; then
			bodylen=$pagelen
		else
			bodylen=$(( pagelen - 10 ))
			[ "$bodylen" -ge 1 ] || bodylen=1
		fi
		colw=$(( width / cols ))
		page=1
		idx=0
		printf -v now '%(%Y-%m-%d %H:%M)T' -1
		while [ "$idx" -lt "$total" ] || { [ "$page" -eq 1 ] && [ "$total" -eq 0 ]; }; do
			# Rows are balanced against what is left, so a short page
			# does not stretch to the full length; without -t the page
			# is padded out to its length afterwards.
			rows=$(( (total - idx + cols - 1) / cols ))
			[ "$rows" -gt "$bodylen" ] && rows=$bodylen
			[ "$rows" -lt 1 ] && rows=1
			[ "$noheader" = 0 ] && rows=$bodylen
			if [ "$page" -ge "$startpage" ] && [ "$noheader" = 0 ]; then
				printf '\n\n'
				printf '%s %*s%s%*s Page %d\n' "$now" \
					$(( (width - ${#now} - ${#file} - 8) / 2 )) '' \
					"${header:-$file}" \
					$(( (width - ${#now} - ${#file} - 8) / 2 )) '' "$page"
				printf '\n\n'
			fi
			for (( row = 0; row < rows; row++ )); do
				line= c=0
				for (( j = 0; j < cols; j++ )); do
					if [ "$across" = 1 ]; then
						i=$(( idx + row * cols + j ))
					else
						i=$(( idx + j * rows + row ))
					fi
					[ "$i" -ge "$total" ] && continue
					[ $(( idx + rows * cols )) -le "$i" ] && continue
					if [ "$j" -gt 0 ]; then
						if [ "$usesep" = 1 ]; then
							line=$line$sepchar
							c=$(( c + 1 ))
						else
							_bt_pr_pad "$c" $(( j * colw ))
							line=$line$_bt_pad
							c=$(( j * colw ))
						fi
					elif [ "$offset" -gt 0 ]; then
						printf -v val '%*s' "$offset" ''
						line=$val
						c=$offset
					fi
					line=$line${lines[i]}
					c=$(( c + ${#lines[i]} ))
				done
				[ "$page" -ge "$startpage" ] && printf '%s\n' "$line"
			done
			idx=$(( idx + rows * cols ))
			if [ "$page" -ge "$startpage" ] && [ "$noheader" = 0 ]; then
				if [ "$formfeed" = 1 ]; then
					printf '\f'
				else
					printf '\n\n\n\n\n'
				fi
			fi
			page=$(( page + 1 ))
			[ "$total" -eq 0 ] && break
		done
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# dd -- POSIX.1-2017: dd [operand...]
#
# Records are counted in bytes, not in whatever the NUL-delimited reader
# happens to hand back, so the pending input is held in the same segment form
# tail uses and sliced to ibs.
# ---------------------------------------------------------------------------

# Write the first $1 bytes of _bt_seg to $fdout, applying conv, and count the
# output record.
_bt_dd_out() {
	local want=$1 wrote=0 i n=${#_bt_seg[@]} piece
	for (( i = 0; i < n && want > 0; i++ )); do
		if [ "$i" -gt 0 ]; then
			printf '\000' >&"$fdout"
			want=$(( want - 1 ))
			wrote=$(( wrote + 1 ))
			[ "$want" -gt 0 ] || break
		fi
		piece=${_bt_seg[i]}
		[ "${#piece}" -gt "$want" ] && piece=${piece:0:want}
		case $conv in
		*ucase*)	piece=${piece^^} ;;
		*lcase*)	piece=${piece,,} ;;
		esac
		case $conv in
		*swab*)	# byte pairs are swapped within a NUL free run
			local sw= j
			for (( j = 0; j + 1 < ${#piece}; j += 2 )); do
				sw=$sw${piece:j+1:1}${piece:j:1}
			done
			[ $(( ${#piece} % 2 )) -eq 1 ] && sw=$sw${piece:${#piece}-1:1}
			piece=$sw ;;
		esac
		printf '%s' "$piece" >&"$fdout"
		want=$(( want - ${#piece} ))
		wrote=$(( wrote + ${#piece} ))
	done
	total=$(( total + wrote ))
	if [ "$wrote" -eq "$obs" ]; then
		rout=$(( rout + 1 ))
	elif [ "$wrote" -gt 0 ]; then
		pout=$(( pout + 1 ))
	fi
	return 0
}

dd () {
	local LC_ALL=C
	local a name val infile= outfile= ibs=512 obs=512 cbs=0 _bt_reason
	local count=-1 skip=0 seek=0 conv= fdin fdout status=0
	local _bt_buf _bt_nul _bt_total rc
	local rin=0 pin=0 rout=0 pout=0 total=0
	local -a _bt_seg=("")

	for a in "$@"; do
		case $a in
		*=*)	;;
		*)	_bt_err "dd: unrecognized operand: $a"; return 1 ;;
		esac
		name=${a%%=*}
		val=${a#*=}
		case $name in
		if)	infile=$val ;;
		of)	outfile=$val ;;
		ibs|obs|bs)
			i=$(( 10#${val%[kKbB]} ))
			case $val in
			*k|*K)	i=$(( i * 1024 )) ;;
			*b|*B)	i=$(( i * 512 )) ;;
			esac
			case $name in
			ibs)	ibs=$i ;;
			obs)	obs=$i ;;
			bs)	ibs=$i; obs=$i ;;
			esac ;;
		cbs)	cbs=$(( 10#$val )) ;;
		count)	count=$(( 10#$val )) ;;
		skip)	skip=$(( 10#$val )) ;;
		seek)	seek=$(( 10#$val )) ;;
		conv)	conv=$val ;;
		*)	_bt_err "dd: unrecognized operand: $name"; return 1 ;;
		esac
	done
	[ "$ibs" -ge 1 ] || ibs=512
	[ "$obs" -ge 1 ] || obs=512

	if [ -n "$infile" ]; then
		if ! { exec {fdin}<"$infile"; } 2>/dev/null; then
			_bt_why "$infile"
			_bt_err "dd: failed to open '$infile': $_bt_reason"
			return 1
		fi
	else
		fdin=0
	fi
	if [ -n "$outfile" ]; then
		case $conv in
		*notrunc*)	{ exec {fdout}>>"$outfile"; } 2>/dev/null ||
				{ _bt_err "dd: failed to open '$outfile'"; return 1; } ;;
		*)		{ exec {fdout}>"$outfile"; } 2>/dev/null ||
				{ _bt_err "dd: failed to open '$outfile'"; return 1; } ;;
		esac
	else
		fdout=1
	fi

	local _BT_BLOCK=$ibs
	local done=0
	while [ "$done" = 0 ]; do
		if _bt_read "$fdin"; then rc=0; else rc=1; fi
		_bt_append "$_bt_buf" "$_bt_nul"
		_bt_len
		while [ "$_bt_total" -ge "$ibs" ]; do
			if [ "$skip" -gt 0 ]; then
				skip=$(( skip - 1 ))
			elif [ "$count" -ge 0 ] && [ "$rin" -ge "$count" ]; then
				done=1
				break
			else
				rin=$(( rin + 1 ))
				_bt_dd_out "$ibs"
			fi
			_bt_drop "$ibs"
			_bt_len
		done
		[ "$rc" = 1 ] && done=1
	done
	# whatever is left is a partial record
	_bt_len
	if [ "$_bt_total" -gt 0 ] && [ "$skip" -eq 0 ] &&
	   { [ "$count" -lt 0 ] || [ "$rin" -lt "$count" ]; }; then
		pin=$(( pin + 1 ))
		_bt_dd_out "$_bt_total"
	fi

	[ -n "$infile" ] && exec {fdin}<&-
	[ -n "$outfile" ] && exec {fdout}>&-
	_bt_err "$rin+$pin records in"
	_bt_err "$rout+$pout records out"
	_bt_err "$total bytes copied"
	return "$status"
}

# ---------------------------------------------------------------------------
# sed -- POSIX.1-2017:
#	sed [-n] script [file...]
#	sed [-n] [-e script]... [-f script_file]... [file...]
# ---------------------------------------------------------------------------

# Read one address at _bt_i of the script in _bt_s.  Sets _bt_a to "" (none),
# "N<number>", "$", or "R<regex>", and advances _bt_i.
_bt_sed_addr() {
	local c d re=
	_bt_a=
	c=${_bt_s:_bt_i:1}
	case $c in
	[0-9])	_bt_a=N
		while :; do
			c=${_bt_s:_bt_i:1}
			case $c in
			[0-9])	_bt_a=$_bt_a$c; _bt_i=$(( _bt_i + 1 )) ;;
			*)	break ;;
			esac
		done ;;
	'$')	_bt_a='$'; _bt_i=$(( _bt_i + 1 )) ;;
	'/'|'\')
		if [ "$c" = '\' ]; then
			d=${_bt_s:_bt_i+1:1}
			_bt_i=$(( _bt_i + 2 ))
		else
			d=/
			_bt_i=$(( _bt_i + 1 ))
		fi
		while [ "$_bt_i" -lt "${#_bt_s}" ]; do
			c=${_bt_s:_bt_i:1}
			if [ "$c" = '\' ] && [ "${_bt_s:_bt_i+1:1}" = "$d" ]; then
				re=$re$d
				_bt_i=$(( _bt_i + 2 ))
				continue
			fi
			[ "$c" = "$d" ] && { _bt_i=$(( _bt_i + 1 )); break; }
			re=$re$c
			_bt_i=$(( _bt_i + 1 ))
		done
		_bt_a=R$re ;;
	esac
	return 0
}

# Read a delimited piece (a regex, replacement or transliteration operand)
# ending at the unescaped delimiter $1.  Sets _bt_piece.
_bt_sed_piece() {
	local d=$1 c
	_bt_piece=
	while [ "$_bt_i" -lt "${#_bt_s}" ]; do
		c=${_bt_s:_bt_i:1}
		if [ "$c" = '\' ]; then
			if [ "${_bt_s:_bt_i+1:1}" = "$d" ]; then
				_bt_piece=$_bt_piece$d
			else
				_bt_piece=$_bt_piece'\'${_bt_s:_bt_i+1:1}
			fi
			_bt_i=$(( _bt_i + 2 ))
			continue
		fi
		[ "$c" = "$d" ] && { _bt_i=$(( _bt_i + 1 )); return 0; }
		_bt_piece=$_bt_piece$c
		_bt_i=$(( _bt_i + 1 ))
	done
	return 1
}

# Take the rest of the current line as an argument.
_bt_sed_rest() {
	local out=
	while [ "$_bt_i" -lt "${#_bt_s}" ]; do
		case ${_bt_s:_bt_i:1} in
		$'\n')	break ;;
		esac
		out=$out${_bt_s:_bt_i:1}
		_bt_i=$(( _bt_i + 1 ))
	done
	_bt_piece=$out
	return 0
}

# Parse the whole script in _bt_s into the command arrays.
_bt_sed_parse() {
	local c d lbl i
	local -a stack=()
	while [ "$_bt_i" -lt "${#_bt_s}" ]; do
		c=${_bt_s:_bt_i:1}
		case $c in
		$'\n'|';'|' '|$'\t')	_bt_i=$(( _bt_i + 1 )); continue ;;
		'#')	while [ "$_bt_i" -lt "${#_bt_s}" ] && [ "${_bt_s:_bt_i:1}" != $'\n' ]; do
				_bt_i=$(( _bt_i + 1 ))
			done
			continue ;;
		esac
		_bt_sed_addr
		_sa1+=("$_bt_a")
		_bt_a=
		if [ "${_bt_s:_bt_i:1}" = ',' ]; then
			_bt_i=$(( _bt_i + 1 ))
			_bt_sed_addr
		fi
		_sa2+=("$_bt_a")
		if [ "${_bt_s:_bt_i:1}" = '!' ]; then
			_sneg+=(1)
			_bt_i=$(( _bt_i + 1 ))
		else
			_sneg+=(0)
		fi
		c=${_bt_s:_bt_i:1}
		_bt_i=$(( _bt_i + 1 ))
		_scmd+=("$c")
		_sactive+=(0)
		case $c in
		s)	d=${_bt_s:_bt_i:1}
			_bt_i=$(( _bt_i + 1 ))
			_bt_sed_piece "$d"; _sarg+=("$_bt_piece")
			_bt_sed_piece "$d"; _sarg2+=("$_bt_piece")
			_bt_piece=
			while [ "$_bt_i" -lt "${#_bt_s}" ]; do
				case ${_bt_s:_bt_i:1} in
				[gpGP0-9])	_bt_piece=$_bt_piece${_bt_s:_bt_i:1}; _bt_i=$(( _bt_i + 1 )) ;;
				w)	_bt_i=$(( _bt_i + 1 ))
					_bt_sed_rest
					_bt_piece=w$_bt_piece
					break ;;
				*)	break ;;
				esac
			done
			_sflag+=("$_bt_piece") ;;
		y)	d=${_bt_s:_bt_i:1}
			_bt_i=$(( _bt_i + 1 ))
			_bt_sed_piece "$d"; _sarg+=("$_bt_piece")
			_bt_sed_piece "$d"; _sarg2+=("$_bt_piece")
			_sflag+=('') ;;
		a|i|c)	# both the "a\" + newline form and the one-line form
			[ "${_bt_s:_bt_i:1}" = '\' ] && _bt_i=$(( _bt_i + 1 ))
			[ "${_bt_s:_bt_i:1}" = $'\n' ] && _bt_i=$(( _bt_i + 1 ))
			while [ "${_bt_s:_bt_i:1}" = ' ' ]; do _bt_i=$(( _bt_i + 1 )); done
			_bt_piece=
			while [ "$_bt_i" -lt "${#_bt_s}" ]; do
				if [ "${_bt_s:_bt_i:1}" = '\' ] && [ "${_bt_s:_bt_i+1:1}" = $'\n' ]; then
					_bt_piece=$_bt_piece$'\n'
					_bt_i=$(( _bt_i + 2 ))
					continue
				fi
				[ "${_bt_s:_bt_i:1}" = $'\n' ] && break
				_bt_piece=$_bt_piece${_bt_s:_bt_i:1}
				_bt_i=$(( _bt_i + 1 ))
			done
			_sarg+=("$_bt_piece"); _sarg2+=(''); _sflag+=('') ;;
		r|w)	while [ "${_bt_s:_bt_i:1}" = ' ' ]; do _bt_i=$(( _bt_i + 1 )); done
			_bt_sed_rest
			_sarg+=("$_bt_piece"); _sarg2+=(''); _sflag+=('') ;;
		b|t|:)	_bt_piece=
			while [ "$_bt_i" -lt "${#_bt_s}" ]; do
				case ${_bt_s:_bt_i:1} in
				$'\n'|';'|'}')	break ;;
				' ')	[ -z "$_bt_piece" ] && { _bt_i=$(( _bt_i + 1 )); continue; }
					break ;;
				esac
				_bt_piece=$_bt_piece${_bt_s:_bt_i:1}
				_bt_i=$(( _bt_i + 1 ))
			done
			_sarg+=("$_bt_piece"); _sarg2+=(''); _sflag+=('') ;;
		'{')	stack+=($(( ${#_scmd[@]} - 1 )))
			_sarg+=(''); _sarg2+=(''); _sflag+=('') ;;
		'}')	if [ "${#stack[@]}" -gt 0 ]; then
				i=${stack[${#stack[@]}-1]}
				stack=("${stack[@]:0:${#stack[@]}-1}")
				_sarg[i]=$(( ${#_scmd[@]} ))
			fi
			_sarg+=(''); _sarg2+=(''); _sflag+=('') ;;
		*)	_sarg+=(''); _sarg2+=(''); _sflag+=('') ;;
		esac
	done
	return 0
}

# A sed regular expression, with \n and \t meaning the characters they
# name, converted to the ERE bash matches with.  grep does not do this:
# in its BRE \n is a literal n.
_bt_sed_re() {
	local s=$1 out= i c
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		if [ "$c" = '\' ] && [ $(( i + 1 )) -lt "${#s}" ]; then
			case ${s:i+1:1} in
			n)	out=$out$'\n'; i=$(( i + 1 )); continue ;;
			t)	out=$out$'\t'; i=$(( i + 1 )); continue ;;
			esac
		fi
		out=$out$c
	done
	_bt_bre2ere "$out"
	return 0
}

# Does address $1 select the current line?
_bt_sed_matchaddr() {
	local re
	case $1 in
	'')	return 0 ;;
	N*)	[ "$lineno" -eq "${1#N}" ] && return 0
		return 1 ;;
	'$')	[ "$lineno" -eq "$nlines" ] && return 0
		return 1 ;;
	R*)	re=${1#R}
		[ -n "$re" ] || re=$_bt_lastre
		_bt_lastre=$re
		_bt_sed_re "$re"
		[[ $pat =~ $_bt_re ]] && return 0
		return 1 ;;
	esac
	return 1
}

# s/$1/$2/$3 over the pattern space.  Sets subflag when anything changed.
_bt_sed_sub() {
	local re=$1 rep=$2 flags=$3
	local global=0 which=1 doprint=0 wfile= digits
	local ere out= i=0 count=0 len m mlen r c j lastend=-1
	case $flags in *g*) global=1 ;; esac
	digits=${flags//[!0-9]/}
	[ -n "$digits" ] && which=$(( 10#$digits ))
	case $flags in *p*) doprint=1 ;; esac
	case $flags in w*) wfile=${flags#w} ;; esac
	[ -n "$re" ] || re=$_bt_lastre
	_bt_lastre=$re
	_bt_sed_re "$re"
	ere=$_bt_re
	len=${#pat}
	while [ "$i" -le "$len" ]; do
		if [[ ${pat:i} =~ ^($ere) ]]; then
			m=${BASH_REMATCH[1]}
			mlen=${#m}
			# An empty match sitting where the last one ended is not a
			# second match; step over a character first.
			if [ "$mlen" -eq 0 ] && [ "$i" -eq "$lastend" ]; then
				[ "$i" -lt "$len" ] && out=$out${pat:i:1}
				i=$(( i + 1 ))
				continue
			fi
			lastend=$(( i + mlen ))
			count=$(( count + 1 ))
			if { [ "$global" = 1 ] && [ "$count" -ge "$which" ]; } ||
			   [ "$count" -eq "$which" ]; then
				r=
				for (( j = 0; j < ${#rep}; j++ )); do
					c=${rep:j:1}
					if [ "$c" = '\' ]; then
						j=$(( j + 1 ))
						case ${rep:j:1} in
						[1-9])	r=$r${BASH_REMATCH[${rep:j:1} + 1]} ;;
						n)	r=$r$'\n' ;;
						t)	r=$r$'\t' ;;
						*)	r=$r${rep:j:1} ;;
						esac
					elif [ "$c" = '&' ]; then
						r=$r$m
					else
						r=$r$c
					fi
				done
				out=$out$r
				subflag=1
			else
				out=$out$m
			fi
			if [ "$mlen" -eq 0 ]; then
				[ "$i" -lt "$len" ] && out=$out${pat:i:1}
				i=$(( i + 1 ))
			else
				i=$(( i + mlen ))
			fi
			if [ "$global" = 0 ] && [ "$count" -ge "$which" ]; then
				out=$out${pat:i}
				break
			fi
		else
			[ "$i" -lt "$len" ] && out=$out${pat:i:1}
			i=$(( i + 1 ))
		fi
	done
	pat=$out
	if [ "$subflag" = 1 ]; then
		[ "$doprint" = 1 ] && printf '%s\n' "$pat"
		if [ -n "$wfile" ]; then
			printf '%s\n' "$pat" >> "$wfile"
		fi
	fi
	return 0
}

# The pattern space as `l` writes it.
_bt_sed_visible() {
	local s=$1 i c out= v
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		case $c in
		'\')	out=$out'\\' ;;
		$'\a')	out=$out'\a' ;;
		$'\b')	out=$out'\b' ;;
		$'\f')	out=$out'\f' ;;
		$'\n')	out=$out'\n' ;;
		$'\r')	out=$out'\r' ;;
		$'\t')	out=$out'\t' ;;
		$'\v')	out=$out'\v' ;;
		[[:print:]])	out=$out$c ;;
		*)	printf -v v '%03o' "'$c"
			out=$out'\'$v ;;
		esac
	done
	_bt_vis=$out
	return 0
}

sed () {
	local LC_ALL=C
	local quiet=0 havescript=0 arg opt val file fd status=0
	local -a _sa1=() _sa2=() _sneg=() _scmd=() _sarg=() _sarg2=() _sflag=() _sactive=()
	local -a lines=()
	local _bt_s= _bt_i=0 _bt_a _bt_piece _bt_re _bt_lastre= _bt_vis _bt_reason
	local pat hold= lineno nlines pc sel ncmds line
	local deleted restart quitflag=0 subflag=0 appendq= i j lbl

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
				n)	quiet=1 ;;
				e|f)	if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "sed: option requires an argument -- $opt"
						return 1
					fi
					if [ "$opt" = e ]; then
						[ -n "$_bt_s" ] && _bt_s=$_bt_s$'\n'
						_bt_s=$_bt_s$val
					else
						if ! { exec {fd}<"$val"; } 2>/dev/null; then
							_bt_err "sed: couldn't open file $val"
							return 1
						fi
						line=
						while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
							[ -n "$_bt_s" ] && _bt_s=$_bt_s$'\n'
							_bt_s=$_bt_s$line
							line=
						done
						exec {fd}<&-
					fi
					havescript=1 ;;
				*)	_bt_err "sed: illegal option -- $opt"
					_bt_err "usage: sed [-n] script [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$havescript" = 0 ]; then
		if [ "$#" -eq 0 ]; then
			_bt_err "usage: sed [-n] script [file...]"
			return 1
		fi
		_bt_s=$1
		shift
	fi
	_bt_i=0
	_bt_sed_parse
	ncmds=${#_scmd[@]}

	[ "$#" -eq 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			fd=0
		elif [ -d "$file" ] || ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "sed: can't read $file: $_bt_reason"
			status=2
			continue
		fi
		line=
		while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
			lines+=("$line")
			line=
		done
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	nlines=${#lines[@]}

	lineno=0
	while [ "$lineno" -lt "$nlines" ]; do
		lineno=$(( lineno + 1 ))
		pat=${lines[lineno-1]}
		subflag=0 appendq= deleted=0
		restart=1
		while [ "$restart" = 1 ]; do
			restart=0
			pc=0
			while [ "$pc" -lt "$ncmds" ]; do
				sel=0
				if [ -z "${_sa1[pc]}" ]; then
					sel=1
				elif [ -z "${_sa2[pc]}" ]; then
					_bt_sed_matchaddr "${_sa1[pc]}" && sel=1
				elif [ "${_sactive[pc]}" = 0 ]; then
					if _bt_sed_matchaddr "${_sa1[pc]}"; then
						sel=1
						_sactive[pc]=1
						case ${_sa2[pc]} in
						N*)	[ "${_sa2[pc]#N}" -le "$lineno" ] && _sactive[pc]=0 ;;
						esac
					fi
				else
					sel=1
					case ${_sa2[pc]} in
					N*)	[ "$lineno" -ge "${_sa2[pc]#N}" ] && _sactive[pc]=0 ;;
					*)	_bt_sed_matchaddr "${_sa2[pc]}" && _sactive[pc]=0 ;;
					esac
				fi
				[ "${_sneg[pc]}" = 1 ] && sel=$(( 1 - sel ))
				if [ "$sel" = 0 ]; then
					if [ "${_scmd[pc]}" = '{' ]; then
						pc=${_sarg[pc]}
					else
						pc=$(( pc + 1 ))
					fi
					continue
				fi
				case ${_scmd[pc]} in
				'{'|'}'|':')	;;
				s)	_bt_sed_sub "${_sarg[pc]}" "${_sarg2[pc]}" "${_sflag[pc]}" ;;
				y)	val=${_sarg[pc]}; arg=${_sarg2[pc]}
					line=
					for (( i = 0; i < ${#pat}; i++ )); do
						j=0
						while [ "$j" -lt "${#val}" ]; do
							[ "${pat:i:1}" = "${val:j:1}" ] && break
							j=$(( j + 1 ))
						done
						if [ "$j" -lt "${#val}" ]; then
							line=$line${arg:j:1}
						else
							line=$line${pat:i:1}
						fi
					done
					pat=$line ;;
				p)	printf '%s\n' "$pat" ;;
				P)	printf '%s\n' "${pat%%$'\n'*}" ;;
				d)	deleted=1; break ;;
				D)	case $pat in
					*$'\n'*)	pat=${pat#*$'\n'}; restart=1; deleted=1 ;;
					*)		deleted=1 ;;
					esac
					break ;;
				n)	[ "$quiet" = 0 ] && printf '%s\n' "$pat"
					if [ "$lineno" -ge "$nlines" ]; then
						deleted=1
						quitflag=1
						break
					fi
					lineno=$(( lineno + 1 ))
					pat=${lines[lineno-1]} ;;
				N)	if [ "$lineno" -ge "$nlines" ]; then
						quitflag=1
						break
					fi
					lineno=$(( lineno + 1 ))
					pat=$pat$'\n'${lines[lineno-1]} ;;
				g)	pat=$hold ;;
				G)	pat=$pat$'\n'$hold ;;
				h)	hold=$pat ;;
				H)	hold=$hold$'\n'$pat ;;
				x)	line=$pat; pat=$hold; hold=$line ;;
				a)	appendq=$appendq${_sarg[pc]}$'\n' ;;
				i)	printf '%s\n' "${_sarg[pc]}" ;;
				c)	if [ -z "${_sa2[pc]}" ] || [ "${_sactive[pc]}" = 0 ]; then
						printf '%s\n' "${_sarg[pc]}"
					fi
					deleted=1
					break ;;
				r)	if [ -r "${_sarg[pc]}" ]; then
						line=
						{ exec {fd}<"${_sarg[pc]}"; } 2>/dev/null &&
						while IFS= read -r line <&"$fd" || [ -n "$line" ]; do
							appendq=$appendq$line$'\n'
							line=
						done
						exec {fd}<&-
					fi ;;
				w)	printf '%s\n' "$pat" >> "${_sarg[pc]}" ;;
				'=')	printf '%d\n' "$lineno" ;;
				l)	_bt_sed_visible "$pat"
					printf '%s$\n' "$_bt_vis" ;;
				q)	quitflag=1; break ;;
				b)	lbl=${_sarg[pc]}
					if [ -z "$lbl" ]; then
						pc=$ncmds
						continue
					fi
					for (( i = 0; i < ncmds; i++ )); do
						if [ "${_scmd[i]}" = ':' ] && [ "${_sarg[i]}" = "$lbl" ]; then
							pc=$i
							break
						fi
					done
					continue ;;
				t)	if [ "$subflag" = 1 ]; then
						subflag=0
						lbl=${_sarg[pc]}
						if [ -z "$lbl" ]; then
							pc=$ncmds
							continue
						fi
						for (( i = 0; i < ncmds; i++ )); do
							if [ "${_scmd[i]}" = ':' ] && [ "${_sarg[i]}" = "$lbl" ]; then
								pc=$i
								break
							fi
						done
						continue
					fi ;;
				esac
				pc=$(( pc + 1 ))
			done
		done
		[ "$deleted" = 0 ] && [ "$quiet" = 0 ] && printf '%s\n' "$pat"
		[ -n "$appendq" ] && printf '%s' "$appendq"
		[ "$quitflag" = 1 ] && break
	done
	return "$status"
}
