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

# ---------------------------------------------------------------------------
# who / logname -- POSIX.1-2017:
#	who [-mTu] [file]
#	logname
#
# Both read the login records database.  There is no getutent() to call, so
# the binary records are parsed directly: on Linux each is 384 bytes, with
# ut_type at 0, ut_pid at 4, ut_line at 8, ut_user at 44, ut_host at 76 and
# ut_tv.tv_sec at 340.
# ---------------------------------------------------------------------------
_BT_UTMP=/var/run/utmp

# Read every byte of $1 into the _bt_b array as numbers.
# Read every byte of file $1 into the array _bt_b, NUL bytes included.
_bt_file_bytes() {
	local fd
	{ exec {fd}<"$1"; } 2>/dev/null || return 1
	_bt_fd_bytes "$fd"
	exec {fd}<&-
	return 0
}

# The same, for whatever is already open on fd $1.
_bt_fd_bytes() {
	local i len rc
	local _bt_buf _bt_nul v
	_bt_b=()
	while :; do
		if _bt_read "$1"; then rc=0; else rc=1; fi
		len=${#_bt_buf}
		for (( i = 0; i < len; i++ )); do
			printf -v v '%d' "'${_bt_buf:i:1}"
			_bt_b+=("$v")
		done
		[ "$rc" = 0 ] && [ "$_bt_nul" = 1 ] && _bt_b+=(0)
		[ "$rc" = 1 ] && break
	done
	return 0
}

# The NUL terminated string of $2 bytes starting at offset $1 of _bt_b.
_bt_b_str() {
	local off=$1 max=$2 i out= _bt_c
	for (( i = 0; i < max; i++ )); do
		[ "${_bt_b[off+i]}" -eq 0 ] && break
		_bt_chr "${_bt_b[off+i]}"
		out=$out$_bt_c
	done
	_bt_str=$out
	return 0
}

# The little-endian 32-bit number at offset $1.
_bt_b_int() {
	_bt_int=$(( _bt_b[$1] | _bt_b[$1+1] << 8 | _bt_b[$1+2] << 16 | _bt_b[$1+3] << 24 ))
	return 0
}

who () {
	local LC_ALL=C
	local arg opt file=$_BT_UTMP mine=0 idle=0 showpid=0 status=0
	local n r off type pid line user host sec when me
	local -a _bt_b=()
	local _bt_str _bt_int _bt_c

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
				m)	mine=1 ;;
				u)	idle=1 showpid=1 ;;
				T)	;;	# the terminal's writability needs its mode
				*)	_bt_err "who: illegal option -- $opt"
					_bt_err "usage: who [-mTu] [file]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	[ "$#" -ge 1 ] && file=$1

	if [ "$mine" = 1 ]; then
		me=
		for r in /dev/pts/[0-9]* /dev/tty[0-9]* /dev/console; do
			[ -c "$r" ] || continue
			if [ "$r" -ef /proc/self/fd/0 ] 2>/dev/null; then
				me=${r#/dev/}
				break
			fi
		done
		[ -n "$me" ] || return 0
	fi

	_bt_file_bytes "$file" || return 0
	n=$(( ${#_bt_b[@]} / 384 ))
	for (( r = 0; r < n; r++ )); do
		off=$(( r * 384 ))
		type=$(( _bt_b[off] | _bt_b[off+1] << 8 ))
		# USER_PROCESS only
		[ "$type" -eq 7 ] || continue
		_bt_b_str $(( off + 8 )) 32;  line=$_bt_str
		_bt_b_str $(( off + 44 )) 32; user=$_bt_str
		_bt_b_str $(( off + 76 )) 256; host=$_bt_str
		_bt_b_int $(( off + 340 ));   sec=$_bt_int
		_bt_b_int $(( off + 4 ));     pid=$_bt_int
		[ -n "$user" ] || continue
		if [ "$mine" = 1 ] && [ "$line" != "$me" ]; then
			continue
		fi
		printf -v when '%(%b %e %H:%M)T' "$sec"
		if [ "$idle" = 1 ]; then
			printf '%-8s %-12s %s   ?          %d' "$user" "$line" "$when" "$pid"
		else
			printf '%-8s %-12s %s' "$user" "$line" "$when"
		fi
		if [ -n "$host" ]; then
			printf ' (%s)' "$host"
		fi
		printf '\n'
	done
	return "$status"
}

logname () {
	local LC_ALL=C
	local n r off type line user me
	local -a _bt_b=()
	local _bt_str _bt_int _bt_c

	if [ "$#" -gt 0 ]; then
		_bt_err "logname: extra operand: $1"
		return 1
	fi
	me=
	for r in /dev/pts/[0-9]* /dev/tty[0-9]* /dev/console; do
		[ -c "$r" ] || continue
		if [ "$r" -ef /proc/self/fd/0 ] 2>/dev/null; then
			me=${r#/dev/}
			break
		fi
	done
	if [ -n "$me" ] && _bt_file_bytes "$_BT_UTMP"; then
		n=$(( ${#_bt_b[@]} / 384 ))
		for (( r = 0; r < n; r++ )); do
			off=$(( r * 384 ))
			type=$(( _bt_b[off] | _bt_b[off+1] << 8 ))
			[ "$type" -eq 7 ] || continue
			_bt_b_str $(( off + 8 )) 32; line=$_bt_str
			[ "$line" = "$me" ] || continue
			_bt_b_str $(( off + 44 )) 32; user=$_bt_str
			if [ -n "$user" ]; then
				printf '%s\n' "$user"
				return 0
			fi
		done
	fi
	# getlogin() would fail here too, and this is what it prints.
	_bt_err "logname: no login name"
	return 1
}

# ---------------------------------------------------------------------------
# diff -- POSIX.1-2017: diff [-bi] [-e] file1 file2
#
# The -c and -u formats put the files' modification times in their headers,
# and stat() is not reachable from a builtin, so they are not offered.
# ---------------------------------------------------------------------------

# The key a line is compared by, honouring -b and -i.
_bt_diff_key() {
	local s=$1
	if [ "$_bt_d_blank" = 1 ]; then
		s=${s//$'\t'/ }
		while :; do
			case $s in
			*'  '*)	s=${s//  / } ;;
			*)	break ;;
			esac
		done
		s=${s%"${s##*[![:blank:]]}"}
	fi
	[ "$_bt_d_icase" = 1 ] && s=${s,,}
	_bt_key=$s
	return 0
}

# A line range as the normal format writes it.
_bt_diff_range() {
	if [ "$1" -eq "$2" ]; then
		_bt_rng=$1
	else
		_bt_rng=$1,$2
	fi
	return 0
}

diff () {
	local LC_ALL=C
	local arg opt f1 f2 fd status=0 edscript=0 _bt_reason
	local _bt_d_blank=0 _bt_d_icase=0 _bt_key _bt_rng
	local -a A=() B=() KA=() KB=() L=() rev=() ops=() hunks=()
	local i j k n m w best ai bi as ae bs be dela addb r1 r2

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
				b)	_bt_d_blank=1 ;;
				i)	_bt_d_icase=1 ;;
				e)	edscript=1 ;;
				c|u)	_bt_err "diff: -$opt needs the files' modification times, which no builtin can read"
					return 2 ;;
				*)	_bt_err "diff: illegal option -- $opt"
					_bt_err "usage: diff [-bi] [-e] file1 file2"
					return 2 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$#" -ne 2 ]; then
		_bt_err "usage: diff [-bi] [-e] file1 file2"
		return 2
	fi
	f1=$1 f2=$2

	for i in 1 2; do
		if [ "$i" = 1 ]; then w=$f1; else w=$f2; fi
		if [ "$w" = - ]; then
			fd=0
		elif [ -d "$w" ] || ! { exec {fd}<"$w"; } 2>/dev/null; then
			_bt_why "$w"
			_bt_err "diff: $w: $_bt_reason"
			return 2
		fi
		w=
		while IFS= read -r w <&"$fd" || [ -n "$w" ]; do
			_bt_diff_key "$w"
			if [ "$i" = 1 ]; then
				A+=("$w"); KA+=("$_bt_key")
			else
				B+=("$w"); KB+=("$_bt_key")
			fi
			w=
		done
		[ "$fd" = 0 ] || exec {fd}<&-
	done
	n=${#A[@]} m=${#B[@]}

	# Myers' algorithm, so that when several edit scripts are equally
	# short the one produced is the one diff itself settles on; walking an
	# LCS table back gives a different, equally minimal, answer.
	local maxd=$(( n + m )) d x y kk px py pk
	local -a V=() trace=() Vp=()
	for (( i = 0; i <= 2 * maxd + 1; i++ )); do V[i]=0; done
	local found=-1
	for (( d = 0; d <= maxd; d++ )); do
		trace[d]=${V[*]}
		for (( k = -d; k <= d; k += 2 )); do
			if [ "$k" -eq $(( -d )) ] ||
			   { [ "$k" -ne "$d" ] && [ "${V[maxd+k-1]}" -lt "${V[maxd+k+1]}" ]; }; then
				x=${V[maxd+k+1]}
			else
				x=$(( V[maxd+k-1] + 1 ))
			fi
			y=$(( x - k ))
			while [ "$x" -lt "$n" ] && [ "$y" -lt "$m" ] && [ "${KA[x]}" = "${KB[y]}" ]; do
				x=$(( x + 1 )); y=$(( y + 1 ))
			done
			V[maxd+k]=$x
			if [ "$x" -ge "$n" ] && [ "$y" -ge "$m" ]; then
				found=$d
				break
			fi
		done
		[ "$found" -ge 0 ] && break
	done

	x=$n y=$m
	for (( d = found; d > 0; d-- )); do
		read -ra Vp <<< "${trace[d]}"
		kk=$(( x - y ))
		if [ "$kk" -eq $(( -d )) ] ||
		   { [ "$kk" -ne "$d" ] && [ "${Vp[maxd+kk-1]}" -lt "${Vp[maxd+kk+1]}" ]; }; then
			pk=$(( kk + 1 ))
		else
			pk=$(( kk - 1 ))
		fi
		px=${Vp[maxd+pk]}
		py=$(( px - pk ))
		while [ "$x" -gt "$px" ] && [ "$y" -gt "$py" ]; do
			rev+=('='); x=$(( x - 1 )); y=$(( y - 1 ))
		done
		if [ "$x" -gt "$px" ]; then
			rev+=('-'); x=$(( x - 1 ))
		else
			rev+=('+'); y=$(( y - 1 ))
		fi
	done
	while [ "$x" -gt 0 ] && [ "$y" -gt 0 ]; do
		rev+=('='); x=$(( x - 1 )); y=$(( y - 1 ))
	done
	for (( k = ${#rev[@]} - 1; k >= 0; k-- )); do ops+=("${rev[k]}"); done

	# group runs of changes into hunks
	ai=0 bi=0 k=0
	while [ "$k" -lt "${#ops[@]}" ]; do
		if [ "${ops[k]}" = '=' ]; then
			ai=$(( ai + 1 )); bi=$(( bi + 1 )); k=$(( k + 1 ))
			continue
		fi
		as=$(( ai + 1 )); bs=$(( bi + 1 )); dela=0; addb=0
		while [ "$k" -lt "${#ops[@]}" ] && [ "${ops[k]}" != '=' ]; do
			if [ "${ops[k]}" = '-' ]; then
				ai=$(( ai + 1 )); dela=$(( dela + 1 ))
			else
				bi=$(( bi + 1 )); addb=$(( addb + 1 ))
			fi
			k=$(( k + 1 ))
		done
		hunks+=("$as $ai $bs $bi $dela $addb")
	done

	[ "${#hunks[@]}" -eq 0 ] && return 0
	status=1

	if [ "$edscript" = 1 ]; then
		# an ed script is applied back to front
		for (( k = ${#hunks[@]} - 1; k >= 0; k-- )); do
			set -- ${hunks[k]}
			as=$1 ae=$2 bs=$3 be=$4 dela=$5 addb=$6
			if [ "$dela" -eq 0 ]; then
				printf '%da\n' $(( as - 1 ))
			elif [ "$addb" -eq 0 ]; then
				_bt_diff_range "$as" "$ae"
				printf '%sd\n' "$_bt_rng"
			else
				_bt_diff_range "$as" "$ae"
				printf '%sc\n' "$_bt_rng"
			fi
			if [ "$addb" -gt 0 ]; then
				for (( i = bs; i <= be; i++ )); do
					printf '%s\n' "${B[i-1]}"
				done
				printf '.\n'
			fi
		done
		return "$status"
	fi

	for (( k = 0; k < ${#hunks[@]}; k++ )); do
		set -- ${hunks[k]}
		as=$1 ae=$2 bs=$3 be=$4 dela=$5 addb=$6
		if [ "$dela" -eq 0 ]; then
			_bt_diff_range "$bs" "$be"
			printf '%da%s\n' $(( as - 1 )) "$_bt_rng"
			for (( i = bs; i <= be; i++ )); do printf '> %s\n' "${B[i-1]}"; done
		elif [ "$addb" -eq 0 ]; then
			_bt_diff_range "$as" "$ae"
			r1=$_bt_rng
			printf '%sd%d\n' "$r1" $(( bs - 1 ))
			for (( i = as; i <= ae; i++ )); do printf '< %s\n' "${A[i-1]}"; done
		else
			_bt_diff_range "$as" "$ae"; r1=$_bt_rng
			_bt_diff_range "$bs" "$be"; r2=$_bt_rng
			printf '%sc%s\n' "$r1" "$r2"
			for (( i = as; i <= ae; i++ )); do printf '< %s\n' "${A[i-1]}"; done
			printf -- '---\n'
			for (( i = bs; i <= be; i++ )); do printf '> %s\n' "${B[i-1]}"; done
		fi
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# cal -- POSIX.1-2017: cal [[month] year]
#
# Dates before September 1752 are Julian, as every cal has it: that month
# lost eleven days when the calendar changed.
# ---------------------------------------------------------------------------

_BT_CAL_MONTHS=(January February March April May June July
		August September October November December)

# Is $1 a leap year, on whichever calendar applies?
_bt_cal_leap() {
	if [ "$1" -gt 1752 ]; then
		[ $(( $1 % 4 )) -eq 0 ] && { [ $(( $1 % 100 )) -ne 0 ] || [ $(( $1 % 400 )) -eq 0 ]; }
		return $?
	fi
	[ $(( $1 % 4 )) -eq 0 ]
	return $?
}

# Days in month $1 of year $2.
_bt_cal_mdays() {
	case $1 in
	1|3|5|7|8|10|12)	_bt_days=31 ;;
	4|6|9|11)		_bt_days=30 ;;
	2)	if _bt_cal_leap "$2"; then _bt_days=29; else _bt_days=28; fi ;;
	esac
	# the eleven days that never happened
	if [ "$2" -eq 1752 ] && [ "$1" -eq 9 ]; then
		_bt_days=30
	fi
	return 0
}

# Day of week for year $1, month $2, day $3.  0 is Sunday.
_bt_cal_dow() {
	local y=$1 m=$2 d=$3 k j
	if [ "$m" -lt 3 ]; then
		m=$(( m + 12 ))
		y=$(( y - 1 ))
	fi
	k=$(( y % 100 ))
	j=$(( y / 100 ))
	if [ "$1" -gt 1752 ] || { [ "$1" -eq 1752 ] && [ "$2" -gt 9 ]; } ||
	   { [ "$1" -eq 1752 ] && [ "$2" -eq 9 ] && [ "$3" -ge 14 ]; }; then
		# Gregorian
		_bt_dow=$(( (d + (13 * (m + 1)) / 5 + k + k / 4 + j / 4 + 5 * j) % 7 ))
	else
		# Julian
		_bt_dow=$(( (d + (13 * (m + 1)) / 5 + k + k / 4 + 5 - j + 700) % 7 ))
	fi
	# Zeller counts Saturday as zero; shift so Sunday is zero
	_bt_dow=$(( (_bt_dow + 6) % 7 ))
	return 0
}

# Build the lines of one month into the _bt_cal array (header, day names,
# then up to six week rows), each padded to twenty columns.
_bt_cal_month() {
	local y=$1 m=$2 withyear=$3 title col d row line skip
	local _bt_days _bt_dow
	_bt_cal_mdays "$m" "$y"
	_bt_cal_dow "$y" "$m" 1
	if [ "$withyear" = 1 ]; then
		title="${_BT_CAL_MONTHS[m-1]} $y"
	else
		title=${_BT_CAL_MONTHS[m-1]}
	fi
	skip=$(( (20 - ${#title}) / 2 ))
	printf -v line '%*s%s' "$skip" '' "$title"
	printf -v line '%-20s' "$line"
	_bt_cal=("$line")
	_bt_cal+=("Su Mo Tu We Th Fr Sa")
	col=$_bt_dow
	printf -v line '%*s' $(( col * 3 )) ''
	d=1
	while [ "$d" -le "$_bt_days" ]; do
		printf -v line '%s%2d ' "$line" "$d"
		col=$(( col + 1 ))
		if [ "$col" -eq 7 ]; then
			_bt_cal+=("${line% }")
			line=
			col=0
		fi
		# September 1752 jumps from the 2nd to the 14th
		if [ "$y" -eq 1752 ] && [ "$m" -eq 9 ] && [ "$d" -eq 2 ]; then
			d=13
		fi
		d=$(( d + 1 ))
	done
	[ -n "$line" ] && _bt_cal+=("${line% }")
	while [ "${#_bt_cal[@]}" -lt 8 ]; do
		_bt_cal+=("")
	done
	return 0
}

cal () {
	local LC_ALL=C
	local y m i j r line now
	local -a _bt_cal=() c1=() c2=() c3=()

	if [ "$#" -gt 2 ]; then
		_bt_err "usage: cal [[month] year]"
		return 1
	fi
	for i in "$@"; do
		_bt_isnum "$i" || { _bt_err "cal: invalid argument: $i"; return 1; }
	done
	if [ "$#" -eq 0 ]; then
		printf -v now '%(%Y %m)T' -1
		set -- ${now}
		m=$(( 10#$2 )); y=$(( 10#$1 ))
	elif [ "$#" -eq 1 ]; then
		y=$(( 10#$1 ))
		m=0
	else
		m=$(( 10#$1 )); y=$(( 10#$2 ))
	fi
	if [ "$m" -ne 0 ] && { [ "$m" -lt 1 ] || [ "$m" -gt 12 ]; }; then
		_bt_err "cal: $m is not a month number (1..12)"
		return 1
	fi
	if [ "$y" -lt 1 ] || [ "$y" -gt 9999 ]; then
		_bt_err "cal: year $y not in range 1..9999"
		return 1
	fi

	if [ "$m" -ne 0 ]; then
		_bt_cal_month "$y" "$m" 1
		# The eight-line padding is only there to line up the columns
		# of a whole year; a single month stops at its last week.
		j=${#_bt_cal[@]}
		while [ "$j" -gt 0 ] && [ -z "${_bt_cal[j-1]}" ]; do j=$(( j - 1 )); done
		for (( i = 0; i < j; i++ )); do
			line=${_bt_cal[i]}
			printf '%s\n' "${line%"${line##*[![:space:]]}"}"
		done
		return 0
	fi

	# a whole year, three months to a row
	printf -v line '%*s%d' $(( (64 - ${#y}) / 2 )) '' "$y"
	printf '%s\n\n' "$line"
	for (( r = 0; r < 4; r++ )); do
		_bt_cal_month "$y" $(( r * 3 + 1 )) 0; c1=("${_bt_cal[@]}")
		_bt_cal_month "$y" $(( r * 3 + 2 )) 0; c2=("${_bt_cal[@]}")
		_bt_cal_month "$y" $(( r * 3 + 3 )) 0; c3=("${_bt_cal[@]}")
		for (( i = 0; i < 8; i++ )); do
			printf -v line '%-20s  %-20s  %-20s' "${c1[i]}" "${c2[i]}" "${c3[i]}"
			printf '%s\n' "${line%"${line##*[![:space:]]}"}"
		done
		[ "$r" -lt 3 ] && printf '\n'
	done
	return 0
}

# ---------------------------------------------------------------------------
# fuser -- POSIX.1-2017: fuser [-cfu] file...
#
# /proc is walked and each entry compared with -ef: stat() is not reachable,
# so the device and inode cannot be read and compared directly.
# ---------------------------------------------------------------------------

# The owning uid of process $1, from /proc/PID/status.
_bt_proc_uid() {
	local line
	_bt_puid=0
	while IFS= read -r line; do
		case $line in
		Uid:*)	set -- $line
			_bt_puid=$2
			return 0 ;;
		esac
	done < /proc/"$1"/status 2>/dev/null
	return 0
}

fuser () {
	local LC_ALL=C
	local arg opt file status=1 p pid l code i
	local showuser=0 _bt_puid _bt_name _bt_uid _bt_gid
	local -a pids=() codes=()

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
				c|f)	;;	# accepted; /proc is walked either way
				u)	showuser=1 ;;
				*)	_bt_err "fuser: illegal option -- $opt"
					_bt_err "usage: fuser [-cfu] file..."
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$#" -eq 0 ]; then
		_bt_err "usage: fuser [-cfu] file..."
		return 1
	fi

	for file in "$@"; do
		pids=() codes=()
		for p in /proc/[0-9]*; do
			pid=${p#/proc/}
			code=
			for l in cwd root exe; do
				[ -e "$p/$l" ] || continue
				if [ "$p/$l" -ef "$file" ] 2>/dev/null; then
					case $l in
					cwd)	code=${code}c ;;
					root)	code=${code}r ;;
					exe)	code=${code}e ;;
					esac
				fi
			done
			if [ -z "$code" ]; then
				for l in "$p"/fd/*; do
					[ -e "$l" ] || continue
					if [ "$l" -ef "$file" ] 2>/dev/null; then
						pids+=("$pid"); codes+=("")
						code=done
						break
					fi
				done
				[ "$code" = done ] && continue
			else
				pids+=("$pid"); codes+=("$code")
			fi
		done
		[ "${#pids[@]}" -gt 0 ] || continue
		status=0
		printf '%s:' "$file" >&2
		for (( i = 0; i < ${#pids[@]}; i++ )); do
			printf '%6d' "${pids[i]}"
			if [ "$showuser" = 1 ]; then
				_bt_proc_uid "${pids[i]}"
				_bt_passwd "$_bt_puid" uid
				printf '%s(%s)' "${codes[i]}" "${_bt_name:-$_bt_puid}" >&2
			else
				printf '%s' "${codes[i]}" >&2
			fi
		done
		printf '\n' >&2
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# ipcs -- POSIX.1-2017: ipcs [-qms] [-a|-bcopt]
#
# Reads what the kernel publishes in /proc/sysvipc.  ipcrm is the other half
# of this pair and is not here: removing an object needs a syscall.
# ---------------------------------------------------------------------------

# Owner name for uid $1, falling back to the number.
_bt_ipcs_owner() {
	local _bt_name _bt_uid _bt_gid
	if _bt_passwd "$1" uid; then
		_bt_owner=$_bt_name
	else
		_bt_owner=$1
	fi
	return 0
}

ipcs () {
	local LC_ALL=C
	local arg opt want= line first=1 fd
	local key id perms rest owner _bt_owner
	local -a f=()

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
				q)	want=${want}q ;;
				m)	want=${want}m ;;
				s)	want=${want}s ;;
				a|b|c|o|p|t)	;;	# accepted; the default listing is what is produced
				*)	_bt_err "ipcs: illegal option -- $opt"
					_bt_err "usage: ipcs [-qms]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	[ -n "$want" ] || want=qms

	case $want in
	*q*)	printf '\n------ Message Queues --------\n'
		printf '%-10s %-10s %-10s %-10s %-12s %-12s\n' key msqid owner perms used-bytes messages
		if { exec {fd}</proc/sysvipc/msg; } 2>/dev/null; then
			first=1
			while IFS= read -r line <&"$fd"; do
				if [ "$first" = 1 ]; then first=0; continue; fi
				set -- $line
				_bt_ipcs_owner "$8"
				printf '0x%08x %-10s %-10s %-10s %-12s %-12s\n' \
					$(( $1 & 0xFFFFFFFF )) "$2" "$_bt_owner" "$3" "$4" "$5"
			done
			exec {fd}<&-
		fi ;;
	esac
	case $want in
	*m*)	printf '\n------ Shared Memory Segments --------\n'
		printf '%-10s %-10s %-10s %-10s %-10s %-10s %-12s\n' key shmid owner perms bytes nattch status
		if { exec {fd}</proc/sysvipc/shm; } 2>/dev/null; then
			first=1
			while IFS= read -r line <&"$fd"; do
				if [ "$first" = 1 ]; then first=0; continue; fi
				set -- $line
				_bt_ipcs_owner "$8"
				# the status column is one wider in a row than in the header
				printf '0x%08x %-10s %-10s %-10s %-10s %-10s %-13s\n' \
					$(( $1 & 0xFFFFFFFF )) "$2" "$_bt_owner" "$3" "$4" "$7" ''
			done
			exec {fd}<&-
		fi ;;
	esac
	case $want in
	*s*)	printf '\n------ Semaphore Arrays --------\n'
		printf '%-10s %-10s %-10s %-10s %-10s\n' key semid owner perms nsems
		if { exec {fd}</proc/sysvipc/sem; } 2>/dev/null; then
			first=1
			while IFS= read -r line <&"$fd"; do
				if [ "$first" = 1 ]; then first=0; continue; fi
				set -- $line
				_bt_ipcs_owner "$5"
				printf '0x%08x %-10s %-10s %-10s %-10s\n' \
					$(( $1 & 0xFFFFFFFF )) "$2" "$_bt_owner" "$3" "$4"
			done
			exec {fd}<&-
		fi ;;
	esac
	printf '\n'
	return 0
}

# ---------------------------------------------------------------------------
# patch -- POSIX.1-2017:
#	patch [-blNR] [-c|-e|-n|-u] [-D define] [-i patchfile] [-o outfile]
#	      [-p num] [-r rejectfile] [file]
#
# The normal and unified formats are understood.  A hunk that does not sit
# exactly where its header says is searched for nearby, as patch does.
# ---------------------------------------------------------------------------

# Strip $1 leading path components from $2 into _bt_stripped; a negative $1
# means the caller gave no -p, in which case only the basename is used.  Asking
# for more
# components than the name has is an error, the way it is for patch: that is how
# a wrong -p is caught rather than silently applied to the bare basename.
_bt_patch_strip() {
	local num=$1 p=$2
	# no -p at all: only the basename is used
	if [ "$num" -lt 0 ]; then _bt_stripped=${p##*/}; return 0; fi
	while [ "$num" -gt 0 ]; do
		case $p in
		*/*)	p=${p#*/} ;;
		*)	_bt_stripped=; return 1 ;;
		esac
		num=$(( num - 1 ))
	done
	_bt_stripped=$p
	return 0
}

patch () {
	local LC_ALL=C
	local arg opt val patchfile= outfile= target= strip=-1 reverse=0 backup=0
	local status=0 fd i j k n line _bt_reason _bt_stripped _bt_at
	local -a P=() T=() out=()
	local pi hstart lhs rhs delta failed=0 hunk=0 name prev
	local nonl=0 orig_nonl=0 sawhdr=0 revskip=0 lastoff=0
	local ctx=0 pre suf lead hnonl anchor_start anchor_end

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
				R)	reverse=1 ;;
				b)	backup=1 ;;
				l|N|n|u|c|e)	;;	# the format is detected from the patch itself
				i|o|p|d|D|r)
					if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "patch: option requires an argument -- $opt"
						return 2
					fi
					case $opt in
					i)	patchfile=$val ;;
					o)	outfile=$val ;;
					p)	strip=$(( 10#$val )) ;;
					esac ;;
				*)	_bt_err "patch: illegal option -- $opt"
					_bt_err "usage: patch [-blNR] [-i patchfile] [-o outfile] [-p num] [file]"
					return 2 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	[ "$#" -ge 1 ] && target=$1

	if [ -n "$patchfile" ]; then
		if ! { exec {fd}<"$patchfile"; } 2>/dev/null; then
			_bt_why "$patchfile"
			_bt_err "patch: $patchfile: $_bt_reason"
			return 2
		fi
	else
		fd=0
	fi
	line=
	while IFS= read -r line <&"$fd"; do P+=("$line"); line=; done
	[ -n "$line" ] && P+=("$line")
	[ -n "$patchfile" ] && exec {fd}<&-

	# The name comes from the headers when the caller did not give one.  The
	# "+++" name wins if it exists on disk, which is what patch settles on for
	# the common case of a diff between two copies of the same file.
	if [ -z "$target" ]; then
		for (( i = 0; i < ${#P[@]}; i++ )); do
			case ${P[i]} in
			'--- '*)	name=${P[i]#--- }
					name=${name%%$'\t'*}
					name=${name%% *}
					sawhdr=1
					_bt_patch_strip "$strip" "$name" &&
					[ -e "$_bt_stripped" ] && target=$_bt_stripped ;;
			'+++ '*)	name=${P[i]#+++ }
					name=${name%%$'\t'*}
					name=${name%% *}
					sawhdr=1
					if [ -z "$target" ]; then
						_bt_patch_strip "$strip" "$name" &&
						[ -e "$_bt_stripped" ] && target=$_bt_stripped
					fi
					break ;;
			esac
		done
	fi
	if [ -z "$target" ]; then
		if [ "$sawhdr" = 1 ]; then
			_bt_err "patch: can't find file to patch"
			_bt_err "patch: perhaps you used the wrong -p option?"
			return 1
		fi
		_bt_err "patch: **** Only garbage was found in the patch input."
		return 2
	fi
	if [ -d "$target" ] || ! { exec {fd}<"$target"; } 2>/dev/null; then
		_bt_why "$target"
		_bt_err "patch: $target: $_bt_reason"
		return 2
	fi
	line=
	while IFS= read -r line <&"$fd"; do T+=("$line"); line=; done
	if [ -n "$line" ]; then T+=("$line"); orig_nonl=1; fi
	exec {fd}<&-
	nonl=$orig_nonl

	# How much context the patch was made with decides which hunks are pinned in
	# place: a hunk short of context at one end is the one that sits at that end
	# of the file, and looking for it elsewhere would be wrong.  Two lines of
	# slack are allowed, which is the fuzz patch permits by default.
	pre=0 suf=0
	for (( i = 0; i < ${#P[@]}; i++ )); do
		case ${P[i]} in
		'@@ -'*)	pre=0 suf=0 lead=1
				for (( j = i + 1; j < ${#P[@]}; j++ )); do
					case ${P[j]} in
					' '*|'')	suf=$(( suf + 1 ))
							[ "$lead" = 1 ] && pre=$suf ;;
					-*|+*|'\'*)	lead=0; suf=0 ;;
					*)		break ;;
					esac
				done
				[ "$pre" -gt "$ctx" ] && ctx=$pre
				[ "$suf" -gt "$ctx" ] && ctx=$suf ;;
		esac
	done

	printf 'patching file %s\n' "$target"
	out=( ${T[@]+"${T[@]}"} )
	delta=0
	pi=0
	while [ "$pi" -lt "${#P[@]}" ]; do
		line=${P[pi]}
		case $line in
		'@@ -'*)
			hunk=$(( hunk + 1 ))
			# @@ -oldstart,oldcount +newstart,newcount @@
			val=${line#@@ -}
			lhs=${val%% *}
			rhs=${val#* +}
			rhs=${rhs%% *}
			if [ "$reverse" = 1 ]; then
				hstart=${rhs%%,*}
			else
				hstart=${lhs%%,*}
			fi
			pi=$(( pi + 1 ))
			local -a want=() repl=()
			prev= pre=0 suf=0 lead=1 hnonl=-1
			while [ "$pi" -lt "${#P[@]}" ]; do
				line=${P[pi]}
				case $line in
				' '*)	want+=("${line:1}"); repl+=("${line:1}"); prev=' '
					suf=$(( suf + 1 ))
					[ "$lead" = 1 ] && pre=$suf ;;
				'-'*)	if [ "$reverse" = 1 ]; then repl+=("${line:1}"); else want+=("${line:1}"); fi
					prev='-'; suf=0 lead=0 ;;
				'+'*)	if [ "$reverse" = 1 ]; then want+=("${line:1}"); else repl+=("${line:1}"); fi
					prev='+'; suf=0 lead=0 ;;
				'\'*)	_bt_patch_nonl ;;
				'')	want+=(''); repl+=(''); prev=' '
					suf=$(( suf + 1 ))
					[ "$lead" = 1 ] && pre=$suf ;;
				*)	break ;;
				esac
				pi=$(( pi + 1 ))
			done
			_bt_patch_apply || failed=$(( failed + 1 ))
			[ "$revskip" = 1 ] && break
			continue ;;
		[0-9]*)
			# normal format: l1[,l2]a l3[,l4], likewise c and d
			case $line in
			*[acd]*)	;;
			*)		pi=$(( pi + 1 )); continue ;;
			esac
			hunk=$(( hunk + 1 ))
			opt=${line//[0-9,]/}
			opt=${opt:0:1}
			lhs=${line%%[acd]*}
			rhs=${line#*[acd]}
			pi=$(( pi + 1 ))
			want=() repl=()
			prev= pre=0 suf=0 lead=1 hnonl=-1
			while [ "$pi" -lt "${#P[@]}" ]; do
				case ${P[pi]} in
				'< '*)	want+=("${P[pi]:2}"); prev='-' ;;
				'> '*)	repl+=("${P[pi]:2}"); prev='+' ;;
				'---')	prev= ;;
				'\'*)	_bt_patch_nonl ;;
				*)	break ;;
				esac
				pi=$(( pi + 1 ))
			done
			if [ "$reverse" = 1 ]; then
				local -a tmp=( ${want[@]+"${want[@]}"} )
				want=( ${repl[@]+"${repl[@]}"} )
				repl=( ${tmp[@]+"${tmp[@]}"} )
				# reversed, the hunk sits at its right-hand line numbers, and
				# an addition becomes the deletion it undoes (and vice versa)
				hstart=${rhs%%,*}
				[ "$opt" = d ] && hstart=$(( hstart + 1 ))
			else
				hstart=${lhs%%,*}
				[ "$opt" = a ] && hstart=$(( hstart + 1 ))
			fi
			_bt_patch_apply || failed=$(( failed + 1 ))
			[ "$revskip" = 1 ] && break
			continue ;;
		esac
		pi=$(( pi + 1 ))
	done

	# A patch whose very first hunk is already in place is the patch someone
	# just applied, or one they meant to hand -R.  Either way nothing good comes
	# of applying the rest of it, so the file is left as it was.
	if [ "$revskip" = 1 ]; then
		_bt_err "patch: Reversed (or previously applied) patch detected!  Skipping patch."
		_bt_err "patch: $hunk out of $hunk hunks ignored"
		return 1
	fi

	if [ -n "$outfile" ]; then
		if ! { exec {fd}>"$outfile"; } 2>/dev/null; then
			_bt_err "patch: cannot create $outfile"
			return 2
		fi
	else
		if [ "$backup" = 1 ] && { exec {j}>"$target.orig"; } 2>/dev/null; then
			n=${#T[@]}
			for (( i = 0; i < n; i++ )); do
				if [ "$i" = $(( n - 1 )) ] && [ "$orig_nonl" = 1 ]
				then printf '%s' "${T[i]}" >&"$j"
				else printf '%s\n' "${T[i]}" >&"$j"
				fi
			done
			exec {j}>&-
		fi
		if ! { exec {fd}>"$target"; } 2>/dev/null; then
			_bt_err "patch: cannot write $target"
			return 2
		fi
	fi
	n=${#out[@]}
	for (( i = 0; i < n; i++ )); do
		if [ "$i" = $(( n - 1 )) ] && [ "$nonl" = 1 ]
		then printf '%s' "${out[i]}" >&"$fd"
		else printf '%s\n' "${out[i]}" >&"$fd"
		fi
	done
	exec {fd}>&-

	if [ "$failed" -gt 0 ]; then
		_bt_err "patch: $failed out of $hunk hunks FAILED"
		return 1
	fi
	return "$status"
}

# A "\ No newline at end of file" marker refers to the line just before it, so
# whether the patched file ends in a newline depends on which side that was.
# Relies on its caller's locals.
_bt_patch_nonl() {
	case $prev in
	' ')	hnonl=1 ;;
	'+')	[ "$reverse" = 1 ] || hnonl=1 ;;
	'-')	[ "$reverse" = 1 ] && hnonl=1 ;;
	esac
	return 0
}

# Place the pending hunk: `want` is what should be there, `repl` what replaces
# it, `hstart` where the patch says it is.  Relies on its caller's locals.
_bt_patch_apply() {
	local at best oldlen=${#out[@]}
	# a hunk short of context at one end belongs at that end of the file
	if [ $(( pre + 2 )) -lt "$ctx" ]; then anchor_start=1; else anchor_start=0; fi
	if [ $(( suf + 2 )) -lt "$ctx" ]; then anchor_end=1; else anchor_end=0; fi
	# earlier hunks that landed off their stated line move this one along too
	at=$(( hstart - 1 + delta + lastoff ))
	_bt_patch_find "$at" want
	best=$_bt_at
	if [ "$best" -lt 0 ]; then
		# already there in its patched form?  then this is a reversed patch
		if [ "$hunk" = 1 ]; then
			_bt_patch_find "$at" repl
			[ "$_bt_at" -ge 0 ] && revskip=1
		fi
		[ "$revskip" = 1 ] || _bt_err "patch: Hunk #$hunk FAILED at $hstart"
		return 1
	fi
	lastoff=$(( best - ( hstart - 1 + delta ) ))
	out=( ${out[@]+"${out[@]:0:best}"} ${repl[@]+"${repl[@]}"} \
	      ${out[@]+"${out[@]:best+${#want[@]}}"} )
	delta=$(( delta + ${#repl[@]} - ${#want[@]} ))
	# a "no newline" marker only decides anything for the hunk that runs to the
	# end of the file; anywhere else the line it belongs to gets one after all
	if [ $(( best + ${#want[@]} )) -eq "$oldlen" ]; then
		if [ "$hnonl" = 1 ]; then nonl=1; else nonl=0; fi
	fi
	return 0
}

# Look for the lines of array $2 in `out` at or near index $1, nearest first,
# and leave where they start in _bt_at (-1 when they are nowhere to be found).
_bt_patch_find() {
	local at=$1 d=0 i k n ok lim
	local -n lines=$2
	n=${#lines[@]}
	lim=${#out[@]}
	# a hunk pinned to the top of the file has only the one place to go
	[ "$anchor_start" = 1 ] && at=0
	while :; do
		for i in $(( at + d )) $(( at - d )); do
			if [ "$i" -ge 0 ] && [ $(( i + n )) -le "$lim" ] &&
			   { [ "$anchor_start" != 1 ] || [ "$i" = 0 ]; } &&
			   { [ "$anchor_end" != 1 ] || [ $(( i + n )) = "$lim" ]; }
			then
				ok=1
				for (( k = 0; k < n; k++ )); do
					if [ "${out[i+k]}" != "${lines[k]}" ]; then ok=0; break; fi
				done
				if [ "$ok" = 1 ]; then _bt_at=$i; return 0; fi
			fi
			[ "$d" = 0 ] && break
		done
		[ "$anchor_start" = 1 ] && break
		d=$(( d + 1 ))
		if [ $(( at + d + n )) -gt "$lim" ] && [ $(( at - d )) -lt 0 ]; then break; fi
	done
	_bt_at=-1
	return 1
}

# ---------------------------------------------------------------------------
# tput -- POSIX.1-2017: tput [-T type] operand [parm...]
#
# A terminfo entry is a small binary file: a header of six 16-bit counts, the
# terminal's names, one byte per boolean, one 16-bit (or, in the newer format,
# 32-bit) word per number, one 16-bit offset per string into a string table,
# and then whatever user-defined capabilities were compiled in after that.  The
# names belonging to each slot are not in the file, only their order, so the
# three lists below are that order.
# ---------------------------------------------------------------------------
# The entry that is loaded, and what came out of it.
declare -A _BT_TI=() _BT_TI_KIND=()
_BT_TI_TERM=

_BT_TI_BOOLS='bw am xsb xhp xenl eo gn hc km hs in da db mir msgr os eslok xt hz
	ul xon nxon mc5i chts nrrmc npc ndscr ccc bce hls xhpa crxm daisy
	xvpa sam cpix lpix OTbs OTns OTnc OTMT OTNL OTpt OTxr'

_BT_TI_NUMS='cols it lines lm xmc pb vt wsl nlab lh lw ma wnum colors pairs ncv
	bufsz spinv spinh maddr mjump mcs mls npins orc orl orhi orvi cps
	widcs btns bitwin bitype OTug OTdC OTdN OTdB OTdT OTkn'

_BT_TI_STRS='cbt bel cr csr tbc clear el ed hpa cmdch cup cud1 home civis cub1
	mrcup cnorm cuf1 ll cuu1 cvvis dch1 dl1 dsl hd smacs blink bold
	smcup smdc dim smir invis prot rev smso smul ech rmacs sgr0 rmcup
	rmdc rmir rmso rmul flash ff fsl is1 is2 is3 if ich1 il1 ip kbs
	ktbc kclr kctab kdch1 kdl1 kcud1 krmir kel ked kf0 kf1 kf10 kf2
	kf3 kf4 kf5 kf6 kf7 kf8 kf9 khome kich1 kil1 kcub1 kll knp kpp
	kcuf1 kind kri khts kcuu1 rmkx smkx lf0 lf1 lf10 lf2 lf3 lf4 lf5
	lf6 lf7 lf8 lf9 rmm smm nel pad dch dl cud ich indn il cub cuf rin
	cuu pfkey pfloc pfx mc0 mc4 mc5 rep rs1 rs2 rs3 rf rc vpa sc ind
	ri sgr hts wind ht tsl uc hu iprog ka1 ka3 kb2 kc1 kc3 mc5p rmp
	acsc pln kcbt smxon rmxon smam rmam xonc xoffc enacs smln rmln
	kbeg kcan kclo kcmd kcpy kcrt kend kent kext kfnd khlp kmrk kmsg
	kmov knxt kopn kopt kprv kprt krdo kref krfr krpl krst kres ksav
	kspd kund kBEG kCAN kCMD kCPY kCRT kDC kDL kslt kEND kEOL kEXT
	kFND kHLP kHOM kIC kLFT kMSG kMOV kNXT kOPT kPRV kPRT kRDO kRPL
	kRIT kRES kSAV kSPD kUND rfi kf11 kf12 kf13 kf14 kf15 kf16 kf17
	kf18 kf19 kf20 kf21 kf22 kf23 kf24 kf25 kf26 kf27 kf28 kf29 kf30
	kf31 kf32 kf33 kf34 kf35 kf36 kf37 kf38 kf39 kf40 kf41 kf42 kf43
	kf44 kf45 kf46 kf47 kf48 kf49 kf50 kf51 kf52 kf53 kf54 kf55 kf56
	kf57 kf58 kf59 kf60 kf61 kf62 kf63 el1 mgc smgl smgr fln sclk dclk
	rmclk cwin wingo hup dial qdial tone pulse hook pause wait u0 u1
	u2 u3 u4 u5 u6 u7 u8 u9 op oc initc initp scp setf setb cpi lpi
	chr cvr defc swidm sdrfq sitm slm smicm snlq snrmq sshm ssubm
	ssupm sum rwidm ritm rlm rmicm rshm rsubm rsupm rum mhpa mcud1
	mcub1 mcuf1 mvpa mcuu1 porder mcud mcub mcuf mcuu scs smgb smgbp
	smglp smgrp smgt smgtp sbim scsd rbim rcsd subcs supcs docr zerom
	csnm kmous minfo reqmp getm setaf setab pfxl devt csin s0ds s1ds
	s2ds s3ds smglr smgtb birep binel bicr colornm defbi endbi
	setcolor slines dispc smpch rmpch smsc rmsc pctrm scesc scesa
	ehhlm elhlm elohlm erhlm ethlm evhlm sgr1 slength OTi2 OTrs OTnl
	OTbc OTko OTma OTG2 OTG3 OTG1 OTG4 OTGR OTGL OTGU OTGD OTGH OTGV
	OTGC meml memu box1'

# Read a 16-bit little-endian word out of _bt_b at $1 into _bt_int, signed the
# way terminfo means it: -1 for absent, -2 for cancelled.
_bt_ti_short() {
	_bt_int=$(( _bt_b[$1] | _bt_b[$1+1] << 8 ))
	[ "$_bt_int" -ge 32768 ] && _bt_int=$(( _bt_int - 65536 ))
	return 0
}

# The same, for the 32-bit numbers of the newer terminfo format.
_bt_ti_long() {
	_bt_int=$(( _bt_b[$1] | _bt_b[$1+1] << 8 | _bt_b[$1+2] << 16 | _bt_b[$1+3] << 24 ))
	[ "$_bt_int" -ge 2147483648 ] && _bt_int=$(( _bt_int - 4294967296 ))
	return 0
}

# Load the entry for terminal $1 into _BT_TI (name -> value) and _BT_TI_KIND
# (name -> b, n or s).  Anything already loaded for the same terminal stays.
_bt_ti_load() {
	local term=$1 d h f= i j off nsz nb nn ns stsz wide=0 nw=2
	local xb xn xs xoff xsz base
	local -a bools=() nums=() strs=()
	[ "${_BT_TI_TERM-}" = "$term" ] && return 0
	[ -n "$term" ] || return 1
	case $term in */*|.|..) return 1 ;; esac

	printf -v h '%02x' "'${term:0:1}"
	for d in ${TERMINFO:+"$TERMINFO"} ${HOME:+"$HOME/.terminfo"} \
		 ${TERMINFO_DIRS:+${TERMINFO_DIRS//:/ }} \
		 /etc/terminfo /lib/terminfo /usr/share/terminfo; do
		if [ -f "$d/${term:0:1}/$term" ]; then f=$d/${term:0:1}/$term; break; fi
		if [ -f "$d/$h/$term" ]; then f=$d/$h/$term; break; fi
	done
	[ -n "$f" ] || return 1
	_bt_file_bytes "$f" || return 1
	[ "${#_bt_b[@]}" -gt 12 ] || return 1

	_bt_ti_short 0
	case $_bt_int in
	282)	wide=0 nw=2 ;;
	542)	wide=1 nw=4 ;;
	*)	return 1 ;;
	esac
	_bt_ti_short 2;  nsz=$_bt_int
	_bt_ti_short 4;  nb=$_bt_int
	_bt_ti_short 6;  nn=$_bt_int
	_bt_ti_short 8;  ns=$_bt_int
	_bt_ti_short 10; stsz=$_bt_int

	_BT_TI=() _BT_TI_KIND=()
	bools=($_BT_TI_BOOLS) nums=($_BT_TI_NUMS) strs=($_BT_TI_STRS)
	# every capability the standard names exists whether or not this entry
	# fills it in; only then is an unknown name really unknown
	for i in "${bools[@]}"; do _BT_TI_KIND[$i]=b; done
	for i in "${nums[@]}"; do _BT_TI_KIND[$i]=n; done
	for i in "${strs[@]}"; do _BT_TI_KIND[$i]=s; done

	off=12
	_bt_b_str "$off" "$nsz"
	_BT_TI[.names]=$_bt_str
	off=$(( off + nsz ))

	for (( i = 0; i < nb; i++ )); do
		[ "$i" -lt "${#bools[@]}" ] || break
		[ "${_bt_b[off+i]}" = 1 ] && _BT_TI[${bools[i]}]=1
	done
	off=$(( off + nb ))
	[ $(( off % 2 )) = 1 ] && off=$(( off + 1 ))

	for (( i = 0; i < nn; i++ )); do
		[ "$i" -lt "${#nums[@]}" ] || break
		if [ "$wide" = 1 ]; then _bt_ti_long $(( off + i * 4 ))
		else _bt_ti_short $(( off + i * 2 )); fi
		[ "$_bt_int" -ge 0 ] && _BT_TI[${nums[i]}]=$_bt_int
	done
	off=$(( off + nn * nw ))

	base=$(( off + ns * 2 ))
	for (( i = 0; i < ns; i++ )); do
		[ "$i" -lt "${#strs[@]}" ] || break
		_bt_ti_short $(( off + i * 2 ))
		[ "$_bt_int" -lt 0 ] && continue
		_bt_b_str $(( base + _bt_int )) "$stsz"
		_BT_TI[${strs[i]}]=$_bt_str
	done
	off=$(( base + stsz ))

	# The user-defined capabilities live past the standard ones, and there the
	# names are in the file: first the values, then a name for every one of the
	# three kinds, all pointing into a second string table.
	[ $(( off % 2 )) = 1 ] && off=$(( off + 1 ))
	if [ $(( off + 10 )) -le "${#_bt_b[@]}" ]; then
		_bt_ti_short "$off";        xb=$_bt_int
		_bt_ti_short $(( off + 2 )); xn=$_bt_int
		_bt_ti_short $(( off + 4 )); xs=$_bt_int
		_bt_ti_short $(( off + 6 )); xoff=$_bt_int
		_bt_ti_short $(( off + 8 )); xsz=$_bt_int
		off=$(( off + 10 ))
		if [ "$xb" -ge 0 ] && [ "$xn" -ge 0 ] && [ "$xs" -ge 0 ] &&
		   [ "$xoff" -ge 0 ] && [ "$xsz" -ge 0 ]; then
			bools=() nums=() strs=()
			for (( i = 0; i < xb; i++ )); do bools+=("${_bt_b[off+i]}"); done
			off=$(( off + xb ))
			[ $(( off % 2 )) = 1 ] && off=$(( off + 1 ))
			for (( i = 0; i < xn; i++ )); do
				if [ "$wide" = 1 ]; then _bt_ti_long $(( off + i * 4 ))
				else _bt_ti_short $(( off + i * 2 )); fi
				nums+=("$_bt_int")
			done
			off=$(( off + xn * nw ))
			# The value strings come first; the names that follow are
			# offset from where those left off, not from the table.
			base=$(( off + xoff * 2 ))
			j=0
			for (( i = 0; i < xs; i++ )); do
				_bt_ti_short $(( off + i * 2 ))
				if [ "$_bt_int" -lt 0 ]; then strs+=(""); continue; fi
				_bt_b_str $(( base + _bt_int )) "$xsz"
				strs+=("$_bt_str")
				[ $(( _bt_int + ${#_bt_str} + 1 )) -gt "$j" ] &&
					j=$(( _bt_int + ${#_bt_str} + 1 ))
			done
			for (( i = xs; i < xoff; i++ )); do
				_bt_ti_short $(( off + i * 2 ))
				if [ "$_bt_int" -lt 0 ]; then strs+=(""); continue; fi
				_bt_b_str $(( base + j + _bt_int )) "$xsz"
				strs+=("$_bt_str")
			done
			for (( i = 0; i < xb + xn + xs; i++ )); do
				j=$(( xs + i ))
				[ "$j" -lt "${#strs[@]}" ] || break
				[ -n "${strs[j]}" ] || continue
				if [ "$i" -lt "$xb" ]; then
					_BT_TI_KIND[${strs[j]}]=b
					[ "${bools[i]}" = 1 ] && _BT_TI[${strs[j]}]=1
				elif [ "$i" -lt $(( xb + xn )) ]; then
					_BT_TI_KIND[${strs[j]}]=n
					[ "${nums[i-xb]}" -ge 0 ] &&
						_BT_TI[${strs[j]}]=${nums[i-xb]}
				else
					_BT_TI_KIND[${strs[j]}]=s
					_BT_TI[${strs[j]}]=${strs[i-xb-xn]}
				fi
			done
		fi
	fi

	_BT_TI_TERM=$term
	return 0
}

# Pop the parameter stack into _bt_v.  Relies on its caller's `st`.
_bt_ti_pop() {
	local k=$(( ${#st[@]} - 1 ))
	if [ "$k" -lt 0 ]; then
		# the older capabilities take their parameters in order rather
		# than naming them with %p, so an empty stack means "the next one"
		_bt_v=${P[pnext]-0}
		pnext=$(( pnext + 1 ))
		return 0
	fi
	_bt_v=${st[k]}
	unset "st[$k]"
	return 0
}

# Skip forward past a conditional: to the matching %e when $1 is e, otherwise
# to the matching %;.  Relies on its caller's `s`, `i` and `n`.
_bt_ti_skip() {
	local depth=0 ch
	while [ "$i" -lt "$n" ]; do
		if [ "${s:i:1}" != % ]; then i=$(( i + 1 )); continue; fi
		ch=${s:i+1:1}
		i=$(( i + 2 ))
		case $ch in
		'?')	depth=$(( depth + 1 )) ;;
		';')	[ "$depth" = 0 ] && return 0
			depth=$(( depth - 1 )) ;;
		e)	[ "$depth" = 0 ] && [ "$1" = e ] && return 0 ;;
		esac
	done
	return 0
}

# Run a capability string through the terminfo parameter machine: $1 is the
# string, the rest are its parameters, and the result lands in _bt_out.
_bt_tparm() {
	local s=$1
	shift
	local -a st=() P=("$@")
	local i=0 n=${#1} c f v x y pnext=0 _bt_v _bt_c
	local -A dyn=()
	n=${#s}
	_bt_out=
	while [ "$i" -lt "$n" ]; do
		c=${s:i:1}
		if [ "$c" != % ]; then _bt_out=$_bt_out$c; i=$(( i + 1 )); continue; fi
		i=$(( i + 1 ))
		c=${s:i:1}
		i=$(( i + 1 ))
		case $c in
		%)	_bt_out=$_bt_out% ;;
		p)	x=${s:i:1}; i=$(( i + 1 ))
			st+=("${P[x-1]-0}") ;;
		P)	x=${s:i:1}; i=$(( i + 1 ))
			_bt_ti_pop; dyn[$x]=$_bt_v ;;
		g)	x=${s:i:1}; i=$(( i + 1 ))
			st+=("${dyn[$x]-0}") ;;
		"'")	x=${s:i:1}; i=$(( i + 2 ))
			_bt_ord "$x"; st+=("$_bt_n") ;;
		'{')	x=
			while [ "$i" -lt "$n" ] && [ "${s:i:1}" != '}' ]; do
				x=$x${s:i:1}; i=$(( i + 1 ))
			done
			i=$(( i + 1 ))
			st+=("$(( x ))") ;;
		l)	_bt_ti_pop; st+=("${#_bt_v}") ;;
		'+'|'-'|'*'|'/'|m|'&'|'|'|'^'|=|'>'|'<'|A|O)
			_bt_ti_pop; y=$_bt_v
			_bt_ti_pop; x=$_bt_v
			case $c in
			'+')	st+=("$(( x + y ))") ;;
			'-')	st+=("$(( x - y ))") ;;
			'*')	st+=("$(( x * y ))") ;;
			'/')	if [ "$y" = 0 ]; then st+=(0); else st+=("$(( x / y ))"); fi ;;
			m)	if [ "$y" = 0 ]; then st+=(0); else st+=("$(( x % y ))"); fi ;;
			'&')	st+=("$(( x & y ))") ;;
			'|')	st+=("$(( x | y ))") ;;
			'^')	st+=("$(( x ^ y ))") ;;
			=)	st+=("$(( x == y ))") ;;
			'>')	st+=("$(( x > y ))") ;;
			'<')	st+=("$(( x < y ))") ;;
			A)	st+=("$(( x != 0 && y != 0 ))") ;;
			O)	st+=("$(( x != 0 || y != 0 ))") ;;
			esac ;;
		'!')	_bt_ti_pop; st+=("$(( _bt_v == 0 ))") ;;
		'~')	_bt_ti_pop; st+=("$(( ~_bt_v ))") ;;
		i)	P[0]=$(( ${P[0]-0} + 1 )); P[1]=$(( ${P[1]-0} + 1 )) ;;
		'?')	;;
		t)	_bt_ti_pop
			[ "$_bt_v" = 0 ] && _bt_ti_skip e ;;
		e)	_bt_ti_skip ';' ;;
		';')	;;
		*)	# whatever is left is a printf-style conversion
			f=%
			[ "$c" = : ] && { c=${s:i:1}; i=$(( i + 1 )); }
			while :; do
				case $c in
				[-+\ #0-9.])	f=$f$c; c=${s:i:1}; i=$(( i + 1 )) ;;
				*)		break ;;
				esac
			done
			case $c in
			d|o|x|X)	_bt_ti_pop; printf -v v "$f$c" "$_bt_v"
					_bt_out=$_bt_out$v ;;
			s)		_bt_ti_pop; printf -v v "${f}s" "$_bt_v"
					_bt_out=$_bt_out$v ;;
			c)		_bt_ti_pop
					# a string cannot hold a NUL, so terminfo
					# spells that character 0200 instead
					[ "$_bt_v" = 0 ] && _bt_v=128
					_bt_chr "$_bt_v"; _bt_out=$_bt_out$_bt_c ;;
			esac ;;
		esac
	done
	return 0
}

# Strip the padding out of a capability string: with no terminal to be slow,
# the delays a curses program would sit through mean nothing here.
_bt_ti_unpad() {
	local s=$1 out= pre post d
	while [ -n "$s" ]; do
		case $s in
		*'$<'*)	pre=${s%%'$<'*}
			post=${s#*'$<'}
			case $post in
			*'>'*)	d=${post%%'>'*}
				case $d in
				''|*[!0-9.*/]*)	out=$out$pre'$<'; s=$post ;;
				*)		out=$out$pre; s=${post#*'>'} ;;
				esac ;;
			*)	out=$out$s; s= ;;
			esac ;;
		*)	out=$out$s; s= ;;
		esac
	done
	_bt_out=$out
	return 0
}

# Expand a capability for output: with parameters it goes through the parameter
# machine, without them it is written as it stands, which is what tput does.
_bt_ti_out() {
	local cap=$1
	shift
	if [ "$#" -gt 0 ]; then
		_bt_tparm "$cap" "$@"
	else
		_bt_out=$cap
	fi
	_bt_ti_unpad "$_bt_out"
	printf '%s' "$_bt_out"
	return 0
}

tput () {
	local LC_ALL=C
	local arg opt term=${TERM-} op kind val useenv=1
	local _bt_out _bt_str _bt_int _bt_c _bt_n
	local -a _bt_b=()

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-T)	shift
			if [ "$#" = 0 ]; then
				_bt_err "tput: option requires an argument -- T"
				return 2
			fi
			term=$1 useenv=0; shift ;;
		-T*)	term=${1#-T} useenv=0; shift ;;
		-*)	_bt_err "tput: illegal option -- ${1#-}"
			_bt_err "usage: tput [-T term] capname [parm...]"
			return 2 ;;
		*)	break ;;
		esac
	done
	if [ "$#" = 0 ]; then
		_bt_err "usage: tput [-T term] capname [parm...]"
		return 2
	fi

	if ! _bt_ti_load "$term"; then
		_bt_err "tput: unknown terminal \"$term\""
		return 3
	fi
	op=$1
	shift

	case $op in
	longname)	printf '%s' "${_BT_TI[.names]##*|}"
			return 0 ;;
	init)		for op in is1 is2 is3; do
				[ -n "${_BT_TI[$op]-}" ] || continue
				_bt_ti_out "${_BT_TI[$op]}"
			done
			return 0 ;;
	reset)		for op in rs1 rs2 rs3; do
				[ -n "${_BT_TI[$op]-}" ] || continue
				_bt_ti_out "${_BT_TI[$op]}"
			done
			return 0 ;;
	clear)		# a terminal with no way to clear its screen is an error,
			# not just an empty answer
			[ -n "${_BT_TI[clear]-}" ] || return 2
			_bt_ti_out "${_BT_TI[clear]}"
			# the scrollback-clearing string goes out with it when the
			# terminal has one, which is what curses does
			[ -n "${_BT_TI[E3]-}" ] && _bt_ti_out "${_BT_TI[E3]}"
			return 0 ;;
	esac

	kind=${_BT_TI_KIND[$op]-}
	if [ -z "$kind" ]; then
		_bt_err "tput: unknown terminfo capability '$op'"
		return 4
	fi
	val=${_BT_TI[$op]-}
	case $kind in
	b)	[ "$val" = 1 ] && return 0
		return 1 ;;
	n)	# a number nobody filled in still gets an answer, as -1
		if [ "$useenv" = 1 ]; then
			# without -T the size of the window wins, the way it does
			# for the curses programs this stands in for
			case $op in
			cols)	[ -n "${COLUMNS-}" ] && val=$COLUMNS
				[ -n "$val" ] || val=80 ;;
			lines)	[ -n "${LINES-}" ] && val=$LINES
				[ -n "$val" ] || val=24 ;;
			esac
		fi
		printf '%s\n' "${val:--1}"
		return 0 ;;
	s)	# a capability can be present and still be the empty string, which
		# is not the same thing as the terminal not having it at all
		[ -n "${_BT_TI[$op]+set}" ] || return 1
		_bt_ti_out "$val" "$@"
		return 0 ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# what -- POSIX.1-2017: what [-s] file...
#
# Looks for the marker SCCS substitutes for %Z%, which is @(#), and prints what
# follows it up to the first of " > \ <newline> or NUL.
# ---------------------------------------------------------------------------

# Print every identification string in $1.  Relies on its caller's `one` and
# sets `found` when it prints anything.
_bt_what_scan() {
	local seg=$1 rest out ch nl=$'\n'
	while [ -n "$seg" ]; do
		case $seg in
		*'@(#)'*)	rest=${seg#*'@(#)'} ;;
		*)		return 0 ;;
		esac
		out=$rest
		for ch in '"' '>' '\' "$nl"; do
			out=${out%%"$ch"*}
		done
		printf '\t%s\n' "$out"
		found=1
		[ "$one" = 1 ] && return 0
		seg=$rest
	done
	return 0
}

what () {
	local LC_ALL=C
	local arg opt one=0 file fd found=0 any=0 carry
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
				s)	one=1 ;;
				*)	_bt_err "what: illegal option -- $opt"
					_bt_err "usage: what [-s] file..."
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	if [ "$#" = 0 ]; then
		_bt_err "usage: what [-s] file..."
		return 1
	fi

	for file in "$@"; do
		if ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "what: $file: $_bt_reason"
			continue
		fi
		printf '%s:\n' "$file"
		# a NUL ends an identification string, so a block that stopped at
		# one carries nothing over; a block that merely filled up does
		found=0
		carry=
		while _bt_read "$fd"; do
			_bt_what_scan "$carry$_bt_buf"
			[ "$one" = 1 ] && [ "$found" = 1 ] && break
			if [ "$_bt_nul" = 1 ]; then carry=; else carry=${_bt_buf: -3}; fi
		done
		[ "$one" = 1 ] && [ "$found" = 1 ] || _bt_what_scan "$carry$_bt_buf"
		exec {fd}<&-
		[ "$found" = 1 ] && any=1
	done
	[ "$any" = 1 ] && return 0
	return 1
}

# ---------------------------------------------------------------------------
# uuencode, uudecode -- POSIX.1-2017:
#	uuencode [-m] [file] decode_pathname
#	uudecode [-o outfile] [file]
#
# Both formats are handled: the historical one, where every six bits become a
# printable character by adding 32, and the base64 one behind -m.
#
# The mode in the header is a guess.  Nothing in a shell can read the mode bits
# of a file -- there is no stat -- so what goes out is 0755 for something this
# user can execute and 0644 otherwise, and uudecode cannot chmod what it writes
# in any case.
# ---------------------------------------------------------------------------
_BT_B64=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/

# Encode $1 (0..63) the historical way, into _bt_c.
_bt_uu_c() {
	if [ "$1" = 0 ]; then _bt_c='`'; else _bt_chr $(( $1 + 32 )); fi
	return 0
}

uuencode () {
	local LC_ALL=C
	local arg opt b64=0 file= name mode=644 i j n cnt line
	local b0 b1 b2 _bt_c _bt_reason
	local -a _bt_b=()

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
				m)	b64=1 ;;
				*)	_bt_err "uuencode: illegal option -- $opt"
					_bt_err "usage: uuencode [-m] [file] decode_pathname"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	case $# in
	1)	name=$1 ;;
	2)	file=$1 name=$2 ;;
	*)	_bt_err "usage: uuencode [-m] [file] decode_pathname"
		return 1 ;;
	esac

	if [ -n "$file" ]; then
		if [ ! -r "$file" ] || ! _bt_file_bytes "$file"; then
			_bt_why "$file"
			_bt_err "uuencode: $file: $_bt_reason"
			return 1
		fi
		[ -x "$file" ] && mode=755
	else
		_bt_fd_bytes 0
	fi

	n=${#_bt_b[@]}
	i=0
	if [ "$b64" = 1 ]; then
		printf 'begin-base64 %s %s\n' "$mode" "$name"
		while [ "$i" -lt "$n" ]; do
			cnt=$(( n - i ))
			[ "$cnt" -gt 45 ] && cnt=45
			line=
			for (( j = i; j < i + cnt; j += 3 )); do
				b0=${_bt_b[j]} b1=${_bt_b[j+1]-0} b2=${_bt_b[j+2]-0}
				line=$line${_BT_B64:$(( b0 >> 2 )):1}
				line=$line${_BT_B64:$(( (b0 & 3) << 4 | b1 >> 4 )):1}
				if [ $(( j + 1 )) -lt $(( i + cnt )) ]
				then line=$line${_BT_B64:$(( (b1 & 15) << 2 | b2 >> 6 )):1}
				else line=$line=
				fi
				if [ $(( j + 2 )) -lt $(( i + cnt )) ]
				then line=$line${_BT_B64:$(( b2 & 63 )):1}
				else line=$line=
				fi
			done
			printf '%s\n' "$line"
			i=$(( i + cnt ))
		done
		printf '====\n'
		return 0
	fi

	printf 'begin %s %s\n' "$mode" "$name"
	while [ "$i" -lt "$n" ]; do
		cnt=$(( n - i ))
		[ "$cnt" -gt 45 ] && cnt=45
		_bt_uu_c "$cnt"
		line=$_bt_c
		for (( j = i; j < i + cnt; j += 3 )); do
			b0=${_bt_b[j]} b1=${_bt_b[j+1]-0} b2=${_bt_b[j+2]-0}
			_bt_uu_c $(( b0 >> 2 )); line=$line$_bt_c
			_bt_uu_c $(( (b0 & 3) << 4 | b1 >> 4 )); line=$line$_bt_c
			_bt_uu_c $(( (b1 & 15) << 2 | b2 >> 6 )); line=$line$_bt_c
			_bt_uu_c $(( b2 & 63 )); line=$line$_bt_c
		done
		printf '%s\n' "$line"
		i=$(( i + cnt ))
	done
	printf '\140\nend\n'
	return 0
}

uudecode () {
	local LC_ALL=C
	local arg opt out= file= fd=0 ofd line name mode b64=0 started=0
	local i n cnt c v acc bits _bt_n _bt_reason

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-o)	shift
			if [ "$#" = 0 ]; then
				_bt_err "uudecode: option requires an argument -- o"
				return 1
			fi
			out=$1; shift ;;
		-o*)	out=${1#-o}; shift ;;
		-*)	[ "$1" = - ] && break
			_bt_err "uudecode: illegal option -- ${1#-}"
			_bt_err "usage: uudecode [-o outfile] [file]"
			return 1 ;;
		*)	break ;;
		esac
	done
	[ "$#" -ge 1 ] && file=$1

	if [ -n "$file" ]; then
		if ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_why "$file"
			_bt_err "uudecode: $file: $_bt_reason"
			return 1
		fi
	fi

	while IFS= read -r line <&"$fd"; do
		case $line in
		'begin-base64 '*)	b64=1 ;;
		'begin '*)		b64=0 ;;
		*)			continue ;;
		esac
		line=${line#* }
		mode=${line%% *}
		name=${line#* }
		started=1
		break
	done
	if [ "$started" = 0 ]; then
		[ -n "$file" ] && exec {fd}<&-
		_bt_err "uudecode: no begin line"
		return 1
	fi
	[ -n "$out" ] || out=$name
	if [ -z "$out" ]; then
		[ -n "$file" ] && exec {fd}<&-
		_bt_err "uudecode: no output name"
		return 1
	fi
	if [ "$out" = /dev/stdout ] || [ "$out" = - ]; then
		ofd=1
	elif ! { exec {ofd}>"$out"; } 2>/dev/null; then
		[ -n "$file" ] && exec {fd}<&-
		_bt_err "uudecode: cannot create $out"
		return 1
	fi

	acc=0 bits=0
	while IFS= read -r line <&"$fd"; do
		if [ "$b64" = 1 ]; then
			case $line in
			'===='*)	break ;;
			esac
			n=${#line}
			for (( i = 0; i < n; i++ )); do
				c=${line:i:1}
				[ "$c" = '=' ] && break
				v=${_BT_B64%%"$c"*}
				[ "${#v}" = "${#_BT_B64}" ] && continue
				acc=$(( acc << 6 | ${#v} ))
				bits=$(( bits + 6 ))
				if [ "$bits" -ge 8 ]; then
					bits=$(( bits - 8 ))
					printf -v c '%03o' $(( (acc >> bits) & 255 ))
					printf "\\$c" >&"$ofd"
				fi
			done
			continue
		fi
		case $line in
		end)	break ;;
		''|'`')	continue ;;
		esac
		_bt_ord "${line:0:1}"
		cnt=$(( _bt_n - 32 ))
		[ "$cnt" -lt 0 ] && cnt=0
		[ "$cnt" = 0 ] && continue
		n=0
		for (( i = 1; i + 3 < ${#line} + 1 && n < cnt; i += 4 )); do
			acc=0
			for (( v = 0; v < 4; v++ )); do
				_bt_ord "${line:i+v:1}"
				acc=$(( acc << 6 | ( ( _bt_n - 32 ) & 63 ) ))
			done
			for (( v = 16; v >= 0 && n < cnt; v -= 8 )); do
				printf -v c '%03o' $(( (acc >> v) & 255 ))
				printf "\\$c" >&"$ofd"
				n=$(( n + 1 ))
			done
		done
	done

	[ "$ofd" = 1 ] || exec {ofd}>&-
	[ -n "$file" ] && exec {fd}<&-
	return 0
}

# ---------------------------------------------------------------------------
# write -- POSIX.1-2017: write user_name [terminal]
#
# The recipient's terminal comes out of utmp, and whether they are willing to
# be written to is settled by whether the terminal can be opened for writing --
# which is exactly what the group-write bit mesg(1) turns on and off.
# ---------------------------------------------------------------------------
write () {
	local LC_ALL=C
	local user term= n r off type line me sender now fd l
	local -a _bt_b=() found=() _bt_supp=()
	local _bt_str _bt_int _bt_c _bt_name _bt_uid _bt_gid
	local _bt_ruid _bt_euid _bt_rgid _bt_egid

	case $# in
	1)	user=$1 ;;
	2)	user=$1 term=${2#/dev/} ;;
	*)	_bt_err "usage: write user_name [terminal]"
		return 1 ;;
	esac

	if _bt_file_bytes "$_BT_UTMP"; then
		n=$(( ${#_bt_b[@]} / 384 ))
		for (( r = 0; r < n; r++ )); do
			off=$(( r * 384 ))
			type=$(( _bt_b[off] | _bt_b[off+1] << 8 ))
			[ "$type" -eq 7 ] || continue
			_bt_b_str $(( off + 44 )) 32
			[ "$_bt_str" = "$user" ] || continue
			_bt_b_str $(( off + 8 )) 32
			line=$_bt_str
			[ -n "$line" ] || continue
			[ -n "$term" ] && [ "$line" != "$term" ] && continue
			found+=("$line")
		done
	fi
	if [ "${#found[@]}" = 0 ]; then
		if [ -n "$term" ]; then
			_bt_err "write: $user is not logged in on $term"
		else
			_bt_err "write: $user is not logged in"
		fi
		return 1
	fi
	# the most recent session wins, which is the last record written
	line=${found[${#found[@]} - 1]}

	_bt_self_ids
	if _bt_passwd "$_bt_euid" uid; then sender=$_bt_name; else sender=$_bt_euid; fi
	me=
	for r in /dev/pts/[0-9]* /dev/tty[0-9]* /dev/console; do
		[ -c "$r" ] || continue
		if [ "$r" -ef /proc/self/fd/0 ] 2>/dev/null; then
			me=${r#/dev/}
			break
		fi
	done
	printf -v now '%(%H:%M)T' -1

	if ! { exec {fd}>"/dev/$line"; } 2>/dev/null; then
		_bt_err "write: permission denied on /dev/$line"
		return 1
	fi
	printf '\007\nMessage from %s (%s) [%s]...\n' "$sender" "${me:-?}" "$now" >&"$fd"
	while IFS= read -r l; do
		printf '%s\n' "$l" >&"$fd"
	done
	[ -n "$l" ] && printf '%s\n' "$l" >&"$fd"
	printf 'EOF\n' >&"$fd"
	exec {fd}>&-
	return 0
}

# ---------------------------------------------------------------------------
# ps -- POSIX.1-2017:
#	ps [-aA] [-defl] [-G grouplist] [-o format]... [-p proclist]
#	   [-t termlist] [-U userlist] [-g grouplist] [-n namelist]
#	   [-u userlist]
#
# Everything here comes out of /proc: one line of stat per process for most of
# it, status for the identities and the locked pages, cmdline for the arguments
# and wchan for what a sleeping process is waiting on.
#
# Columns are laid out the way ps lays them out: each one is as wide as its
# heading or its widest value, whichever is more, and never narrower than the
# width that belongs to the field.
# ---------------------------------------------------------------------------

# name:heading:minimum width:alignment
_BT_PS_FIELDS='
pid:PID:5:r ppid:PPID:5:r pgid:PGID:5:r pgrp:PGID:5:r sid:SID:5:r
sess:SID:5:r uid:UID:5:r gid:GID:5:r ruid:RUID:5:r rgid:RGID:5:r
user:USER:8:l euser:EUSER:8:l ruser:RUSER:8:l group:GROUP:8:l
egroup:EGROUP:8:l rgroup:RGROUP:8:l comm:COMMAND:15:l ucmd:COMMAND:15:l
args:COMMAND:27:l command:COMMAND:27:l tty:TT:8:l tname:TT:8:l
stat:STAT:4:l state:S:1:l s:S:1:l wchan:WCHAN:6:l stime:STIME:5:l
start_time:START:5:l f:F:1:r flag:F:1:r flags:F:1:r time:TIME:8:r
cputime:TIME:8:r etime:ELAPSED:11:r nice:NI:3:r ni:NI:3:r pri:PRI:3:r
pcpu:%CPU:4:r c:C:2:r vsz:VSZ:6:r vsize:VSZ:6:r rss:RSS:5:r rssize:RSS:5:r
sz:SZ:5:r thcount:THCNT:5:r nlwp:NLWP:4:r addr:ADDR:4:l opri:PRI:3:r'

# The fixed layouts, as field:heading:heading width:value width.  The two
# widths differ only where ps itself lets them: the ADDR column of -l is four
# wide in the heading and holds a single dash underneath, and the SZ beside it
# takes the room back.
_BT_PS_DEFAULT='pid:PID:5:5 tty:TTY:8:8 time:TIME:8:8 ucmd:CMD:3:3'
_BT_PS_FULL='user:UID:8:8 pid:PID:5:5 ppid:PPID:5:5 c:C:2:2 stime:STIME:5:5
	     tty:TTY:8:8 time:TIME:8:8 args:CMD:3:3'
_BT_PS_LONG='f:F:1:1 state:S:1:1 uid:UID:5:5 pid:PID:5:5 ppid:PPID:5:5 c:C:2:2
	     opri:PRI:3:3 nice:NI:3:3 addr:ADDR:4:1 sz:SZ:2:5 wchan:WCHAN:6:6
	     tty:TTY:8:8 time:TIME:8:8 ucmd:CMD:3:3'

# The device name for the tty device number $1, in _bt_str.
_bt_ps_tty() {
	local dev=$1 maj min
	if [ "$dev" = 0 ]; then _bt_str='?'; return 0; fi
	maj=$(( (dev >> 8) & 0xfff ))
	min=$(( (dev & 0xff) | ((dev >> 12) & 0xfff00) ))
	case $maj in
	136|137|138|139|140|141|142|143)
		_bt_str=pts/$(( min + (maj - 136) * 256 )) ;;
	4)	if [ "$min" -lt 64 ]; then _bt_str=tty$min
		else _bt_str=ttyS$(( min - 64 )); fi ;;
	5)	case $min in
		0)	_bt_str=tty ;;
		1)	_bt_str=console ;;
		*)	_bt_str=? ;;
		esac ;;
	*)	_bt_str='?' ;;
	esac
	return 0
}

# Clock ticks $1 as ps writes a cpu time.
_bt_ps_time() {
	local t=$(( $1 / 100 )) d h
	h=$(( t / 3600 ))
	d=$(( h / 24 ))
	if [ "$d" -gt 0 ]; then
		printf -v _bt_str '%d-%02d:%02d:%02d' "$d" $(( h % 24 )) \
			$(( t / 60 % 60 )) $(( t % 60 ))
	else
		printf -v _bt_str '%02d:%02d:%02d' "$h" $(( t / 60 % 60 )) $(( t % 60 ))
	fi
	return 0
}

# Seconds $1 as ps writes an elapsed time.
_bt_ps_etime() {
	local t=$1 d h
	[ "$t" -lt 0 ] && t=0
	h=$(( t / 3600 ))
	d=$(( h / 24 ))
	if [ "$d" -gt 0 ]; then
		printf -v _bt_str '%d-%02d:%02d:%02d' "$d" $(( h % 24 )) \
			$(( t / 60 % 60 )) $(( t % 60 ))
	elif [ "$h" -gt 0 ]; then
		printf -v _bt_str '%02d:%02d:%02d' "$h" $(( t / 60 % 60 )) $(( t % 60 ))
	else
		printf -v _bt_str '%02d:%02d' $(( t / 60 )) $(( t % 60 ))
	fi
	return 0
}

ps () {
	local LC_ALL=C
	local arg opt val i j k n fd line rest w hdr ttyname oldifs
	local noheader=1
	local IFS=$' \t\n'
	local pid comm state ppid pgrp sess ttynr tpgid flags utime stime_t
	local cutime cstime prio nice_v threads starttime vsize rss_p policy
	local ruid_v euid_v rgid_v egid_v vmlck vmrss wch cmdline now boot=0
	local sel_all=0 sel_a=0 sel_d=0 sel_f=0 sel_l=0 mytty= myeuid
	local -a pids=() ttys=() users=() rusers=() sess_g=() rgroups=()
	local -a cols=() rows=() cw=() vals=()
	local _bt_str _bt_int _bt_name _bt_uid _bt_gid _bt_grname _bt_reason
	local _bt_ruid _bt_euid _bt_rgid _bt_egid
	local -a _bt_supp=()

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
				A|e)	sel_all=1 ;;
				a)	sel_a=1 ;;
				d)	sel_d=1 ;;
				f)	sel_f=1 ;;
				l)	sel_l=1 ;;
				o|p|t|u|U|g|G|n)
					if [ -n "$arg" ]; then
						val=$arg; arg=
					elif [ "$#" -gt 0 ]; then
						val=$1; shift
					else
						_bt_err "ps: option requires an argument -- $opt"
						return 1
					fi
					case $opt in
					o)	cols+=(${val//,/ }) ;;
					p)	pids+=(${val//,/ }) ;;
					t)	ttys+=(${val//,/ }) ;;
					u)	users+=(${val//,/ }) ;;
					U)	rusers+=(${val//,/ }) ;;
					g)	sess_g+=(${val//,/ }) ;;
					G)	rgroups+=(${val//,/ }) ;;
					n)	;;	# a namelist means nothing here
					esac ;;
				*)	_bt_err "ps: illegal option -- $opt"
					_bt_err "usage: ps [-aAdefl] [-G grouplist] [-o format] [-p proclist]"
					_bt_err "          [-t termlist] [-U userlist] [-g grouplist] [-u userlist]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	# what to print
	if [ "${#cols[@]}" = 0 ]; then
		noheader=0
		if [ "$sel_l" = 1 ]; then cols=($_BT_PS_LONG)
		elif [ "$sel_f" = 1 ]; then cols=($_BT_PS_FULL)
		else cols=($_BT_PS_DEFAULT); fi
	else
		# an -o name carries its own heading after an = sign; a name given
		# without one gets the standard heading, and a listing where every
		# name was given an empty heading has no heading line at all
		local -a spec=()
		local usedef
		for i in "${cols[@]}"; do
			case $i in
			*=*)	hdr=${i#*=}; i=${i%%=*} usedef=0
				[ -n "$hdr" ] && noheader=0 ;;
			*)	hdr= usedef=1 noheader=0 ;;
			esac
			w=0
			for j in $_BT_PS_FIELDS; do
				case $j in
				"$i":*)	rest=${j#*:}
					[ "$usedef" = 1 ] && hdr=${rest%%:*}
					rest=${rest#*:}
					w=${rest%%:*}
					break ;;
				esac
			done
			if [ "$w" = 0 ]; then
				_bt_err "ps: unknown user-defined format specifier \"$i\""
				return 1
			fi
			[ "${#hdr}" -gt "$w" ] && w=${#hdr}
			spec+=("$i:$hdr:$w:$w")
		done
		cols=("${spec[@]}")
	fi

	_bt_self_ids
	myeuid=$_bt_euid
	for i in /dev/pts/[0-9]* /dev/tty[0-9]* /dev/console; do
		[ -c "$i" ] || continue
		if [ "$i" -ef /proc/self/fd/0 ] 2>/dev/null; then
			mytty=${i#/dev/}
			break
		fi
	done

	printf -v now '%(%s)T' -1
	if { exec {fd}</proc/stat; } 2>/dev/null; then
		while read -r arg val rest <&"$fd"; do
			[ "$arg" = btime ] && boot=$val && break
		done
		exec {fd}<&-
	fi

	# ps lists processes in numeric order.  The glob gives them in the order a
	# sort would put strings in, so grouping by how many digits they have and
	# taking the shorter groups first is the same thing without a sort.
	local -a bylen=()
	local plist=
	for i in /proc/[0-9]*; do
		[ -d "$i" ] || continue
		pid=${i#/proc/}
		bylen[${#pid}]="${bylen[${#pid}]-} $pid"
	done
	for (( n = 1; n < 12; n++ )); do
		plist="$plist${bylen[n]-}"
	done

	for pid in $plist; do
		i=/proc/$pid
		{ exec {fd}<"$i/stat"; } 2>/dev/null || continue
		IFS= read -r line <&"$fd"
		exec {fd}<&-
		[ -n "$line" ] || continue
		rest=${line#*(}
		comm=${rest%)*}
		rest=${rest##*") "}
		# shellcheck disable=SC2086
		set -- $rest
		state=$1 ppid=$2 pgrp=$3 sess=$4 ttynr=$5 tpgid=$6 flags=$7
		utime=${12} stime_t=${13} cutime=${14} cstime=${15}
		prio=${16} nice_v=${17} threads=${18} starttime=${20}
		vsize=${21} rss_p=${22} policy=${39}

		ruid_v= euid_v= rgid_v= egid_v= vmlck=0 vmrss=0
		if { exec {fd}<"$i/status"; } 2>/dev/null; then
			while IFS= read -r arg <&"$fd"; do
				case $arg in
				'Uid:'*)	set -- $arg; ruid_v=$2 euid_v=$3 ;;
				'Gid:'*)	set -- $arg; rgid_v=$2 egid_v=$3 ;;
				'VmLck:'*)	set -- $arg; vmlck=$2 ;;
				# the resident size in stat counts differently
				# from the one ps reports; this is ps's
				'VmRSS:'*)	set -- $arg; vmrss=$2 ;;
				esac
			done
			exec {fd}<&-
		fi
		[ -n "$euid_v" ] || euid_v=0
		[ -n "$ruid_v" ] || ruid_v=$euid_v
		[ -n "$egid_v" ] || egid_v=0
		[ -n "$rgid_v" ] || rgid_v=$egid_v

		_bt_ps_tty "$ttynr"
		ttyname=$_bt_str

		# selection
		if [ "${#pids[@]}" -gt 0 ] || [ "${#ttys[@]}" -gt 0 ] ||
		   [ "${#users[@]}" -gt 0 ] || [ "${#rusers[@]}" -gt 0 ] ||
		   [ "${#sess_g[@]}" -gt 0 ] || [ "${#rgroups[@]}" -gt 0 ]; then
			k=0
			for j in ${pids[@]+"${pids[@]}"}; do
				[ "$j" = "$pid" ] && k=1
			done
			for j in ${ttys[@]+"${ttys[@]}"}; do
				j=${j#/dev/}
				[ "$j" = "$ttyname" ] && k=1
			done
			for j in ${users[@]+"${users[@]}"}; do
				if _bt_isnum "$j"; then
					[ "$j" = "$euid_v" ] && k=1
				elif _bt_passwd "$j" name && [ "$_bt_uid" = "$euid_v" ]; then
					k=1
				fi
			done
			for j in ${rusers[@]+"${rusers[@]}"}; do
				if _bt_isnum "$j"; then
					[ "$j" = "$ruid_v" ] && k=1
				elif _bt_passwd "$j" name && [ "$_bt_uid" = "$ruid_v" ]; then
					k=1
				fi
			done
			for j in ${sess_g[@]+"${sess_g[@]}"}; do
				[ "$j" = "$sess" ] && k=1
			done
			for j in ${rgroups[@]+"${rgroups[@]}"}; do
				if _bt_isnum "$j"; then
					[ "$j" = "$rgid_v" ] && k=1
				else
					_bt_group_name "$rgid_v"
					[ "$_bt_grname" = "$j" ] && k=1
				fi
			done
			[ "$k" = 1 ] || continue
		elif [ "$sel_all" = 1 ]; then
			:
		elif [ "$sel_d" = 1 ]; then
			[ "$sess" = "$pid" ] && continue
		elif [ "$sel_a" = 1 ]; then
			[ "$ttyname" = '?' ] && continue
			[ "$sess" = "$pid" ] && continue
		else
			[ "$euid_v" = "$myeuid" ] || continue
			[ "$ttyname" = "${mytty:-?}" ] || continue
		fi

		# the values this listing actually asks for
		vals=()
		for j in "${cols[@]}"; do
			arg=${j%%:*}
			case $arg in
			pid)	val=$pid ;;
			ppid)	val=$ppid ;;
			pgid|pgrp)	val=$pgrp ;;
			sid|sess)	val=$sess ;;
			uid)	val=$euid_v ;;
			ruid)	val=$ruid_v ;;
			gid)	val=$egid_v ;;
			rgid)	val=$rgid_v ;;
			user|euser)
				if _bt_passwd "$euid_v" uid; then val=$_bt_name
				else val=$euid_v; fi ;;
			ruser)	if _bt_passwd "$ruid_v" uid; then val=$_bt_name
				else val=$ruid_v; fi ;;
			group|egroup)
				_bt_group_name "$egid_v"
				val=${_bt_grname:-$egid_v} ;;
			rgroup)	_bt_group_name "$rgid_v"
				val=${_bt_grname:-$rgid_v} ;;
			comm|ucmd)	val=$comm ;;
			args|command)
				cmdline=
				if { exec {fd}<"$i/cmdline"; } 2>/dev/null; then
					while IFS= read -r -d '' arg <&"$fd"; do
						cmdline=${cmdline:+$cmdline }$arg
					done
					exec {fd}<&-
				fi
				if [ -n "$cmdline" ]; then val=$cmdline
				else val="[$comm]"; fi ;;
			tty|tname)	val=$ttyname ;;
			state|s)	val=$state ;;
			stat)	val=$state
				[ "$nice_v" -lt 0 ] && val=$val'<'
				[ "$nice_v" -gt 0 ] && val=${val}N
				[ "$vmlck" -gt 0 ] && val=${val}L
				[ "$sess" = "$pid" ] && val=${val}s
				[ "$threads" -gt 1 ] && val=${val}l
				[ "$tpgid" = "$pgrp" ] && val=$val'+' ;;
			wchan)	wch=
				if { exec {fd}<"$i/wchan"; } 2>/dev/null; then
					IFS= read -r wch <&"$fd"
					exec {fd}<&-
				fi
				case $wch in
				''|0)	val='-' ;;
				*)	val=$wch ;;
				esac ;;
			stime|start_time)
				val=$(( boot + starttime / 100 ))
				if [ $(( now - val )) -lt 86400 ]; then
					printf -v val '%(%H:%M)T' "$val"
				else
					printf -v val '%(%b%d)T' "$val"
				fi ;;
			f|flag|flags)
				val=0
				[ $(( flags & 0x40 )) != 0 ] && val=$(( val | 1 ))
				[ $(( flags & 0x100 )) != 0 ] && val=$(( val | 4 )) ;;
			time|cputime)
				_bt_ps_time $(( utime + stime_t ))
				val=$_bt_str ;;
			etime)	_bt_ps_etime $(( now - boot - starttime / 100 ))
				val=$_bt_str ;;
			nice|ni)	# a process on a real-time policy has no nice
					# value to speak of, and ps says so
					case ${policy:-0} in
					0|3)	val=$nice_v ;;
					*)	val='-' ;;
					esac ;;
			pri)	val=$(( 39 - prio )) ;;
			opri)	val=$(( prio + 60 )) ;;
			pcpu|c)	k=$(( now - boot - starttime / 100 ))
				[ "$k" -lt 1 ] && k=1
				n=$(( ( utime + stime_t ) * 10 / k ))
				[ "$n" -gt 999 ] && n=999
				if [ "$arg" = c ]; then val=$(( n / 10 ))
				else printf -v val '%d.%d' $(( n / 10 )) $(( n % 10 )); fi ;;
			vsz|vsize)	val=$(( vsize / 1024 )) ;;
			rss|rssize)	val=$vmrss ;;
			sz)	val=$(( vsize / 4096 )) ;;
			thcount|nlwp)	val=$threads ;;
			addr)	val='-' ;;
			*)	val= ;;
			esac
			vals+=("$val")
		done
		printf -v line '%s\037' "${vals[@]}"
		rows+=("$line")
	done

	# The columns sit at fixed places on the line.  A value too wide for its
	# column pushes what follows to the right, and the padding of the next
	# column that has any to spare takes the shift back -- which is how ps
	# keeps a listing lined up despite the odd enormous number.
	local -a hw=() ht=() dt=()
	local pos pad sp
	n=0
	for (( i = 0; i < ${#cols[@]}; i++ )); do
		arg=${cols[i]}
		rest=${arg#*:}
		hdr=${rest%%:*}
		rest=${rest#*:}
		w=${rest%%:*}
		[ "${#hdr}" -gt "$w" ] && w=${#hdr}
		hw+=("$w")
		ht+=("$n")
		n=$(( n + w + 1 ))
		cw+=("${arg##*:}")
	done
	n=0
	for (( i = 0; i < ${#cols[@]}; i++ )); do
		dt+=("$n")
		n=$(( n + cw[i] + 1 ))
	done

	if [ "$noheader" = 0 ]; then
		line= pos=0
		for (( i = 0; i < ${#cols[@]}; i++ )); do
			arg=${cols[i]#*:}; hdr=${arg%%:*}
			arg=${cols[i]%%:*}
			if [ "$pos" -lt "${ht[i]}" ]; then pad=$(( ht[i] - pos ))
			elif [ "$i" -gt 0 ]; then pad=1
			else pad=0; fi
			printf -v sp '%*s' "$pad" ''
			if _bt_ps_right "$arg"; then
				printf -v val '%*s' "${hw[i]}" "$hdr"
			else
				val=$hdr
			fi
			line=$line$sp$val
			pos=$(( pos + pad + ${#val} ))
		done
		while [ "${line% }" != "$line" ]; do line=${line% }; done
		printf '%s\n' "$line"
	fi
	for line in ${rows[@]+"${rows[@]}"}; do
		oldifs=$IFS; IFS=$'\037'
		# shellcheck disable=SC2206
		vals=($line)
		IFS=$oldifs
		rest= pos=0
		for (( i = 0; i < ${#cols[@]}; i++ )); do
			arg=${cols[i]%%:*}
			val=${vals[i]}
			if [ "$pos" -lt "${dt[i]}" ]; then pad=$(( dt[i] - pos ))
			elif [ "$i" -gt 0 ]; then pad=1
			else pad=0; fi
			printf -v sp '%*s' "$pad" ''
			if _bt_ps_right "$arg"; then
				printf -v val '%*s' "${cw[i]}" "$val"
			elif [ $(( i + 1 )) -lt "${#cols[@]}" ] &&
			     [ "${#val}" -gt "${cw[i]}" ]; then
				# text too wide for its column is cut, but only
				# where there is another column after it
				val=${val:0:${cw[i]}}
			fi
			rest=$rest$sp$val
			pos=$(( pos + pad + ${#val} ))
		done
		while [ "${rest% }" != "$rest" ]; do rest=${rest% }; done
		printf '%s\n' "$rest"
	done
	# the heading still goes out, but selecting nothing is a failure
	[ "${#rows[@]}" = 0 ] && return 1
	return 0
}

# Whether field $1 is one of the ones ps writes right up against its column.
_bt_ps_right() {
	case $1 in
	pid|ppid|pgid|pgrp|sid|sess|uid|gid|ruid|rgid|time|cputime|etime|nice|ni|\
	pri|opri|pcpu|c|vsz|vsize|rss|rssize|sz|thcount|nlwp|f|flag|flags|addr)
		return 0 ;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# ed -- POSIX.1-2017: ed [-p string] [-s] [file]
#
# The buffer is one array of lines; a line number is its index plus one.  The
# regular expressions and the s command borrow sed's machinery, which is the
# same machinery ed's own description asks for.
#
# The ? that marks an error goes to standard output, as the standard says, and
# the message behind it only when H has asked for it.
# ---------------------------------------------------------------------------

# Report an error: the caller decides what to do next.
_bt_ed_oops() {
	_bt_ed_msg=$1
	_bt_ed_bad=1
	printf '?\n'
	[ "$_bt_ed_help" = 1 ] && printf '%s\n' "$_bt_ed_msg"
	return 1
}

# Parse one address out of `cmd` at `ci` into _bt_ed_addr, -1 when there is
# none.  Relies on its caller's locals.
_bt_ed_addr1() {
	local n c re dir sign i found
	_bt_ed_addr=-1
	while [ "${cmd:ci:1}" = ' ' ] || [ "${cmd:ci:1}" = $'\t' ]; do
		ci=$(( ci + 1 ))
	done
	c=${cmd:ci:1}
	case $c in
	.)	_bt_ed_addr=$cur; ci=$(( ci + 1 )) ;;
	'$')	_bt_ed_addr=${#buf[@]}; ci=$(( ci + 1 )) ;;
	[0-9])	n=
		while :; do
			case ${cmd:ci:1} in
			[0-9])	n=$n${cmd:ci:1}; ci=$(( ci + 1 )) ;;
			*)	break ;;
			esac
		done
		_bt_ed_addr=$(( 10#$n )) ;;
	"'")	ci=$(( ci + 1 ))
		c=${cmd:ci:1}
		ci=$(( ci + 1 ))
		_bt_ed_addr=${_bt_ed_mark[$c]--1}
		[ "$_bt_ed_addr" -lt 0 ] && { _bt_ed_oops "Invalid mark"; return 1; } ;;
	'/'|'?')
		dir=$c
		ci=$(( ci + 1 ))
		re=
		while [ "$ci" -lt "${#cmd}" ] && [ "${cmd:ci:1}" != "$dir" ]; do
			if [ "${cmd:ci:1}" = '\' ]; then
				re=$re${cmd:ci:1}
				ci=$(( ci + 1 ))
			fi
			re=$re${cmd:ci:1}
			ci=$(( ci + 1 ))
		done
		[ "${cmd:ci:1}" = "$dir" ] && ci=$(( ci + 1 ))
		[ -n "$re" ] || re=$_bt_lastre
		if [ -z "$re" ]; then _bt_ed_oops "No previous pattern"; return 1; fi
		_bt_lastre=$re
		_bt_sed_re "$re"
		found=-1
		if [ "$dir" = / ]; then
			for (( i = 1; i <= ${#buf[@]}; i++ )); do
				n=$(( (cur + i - 1) % ${#buf[@]} ))
				if [[ ${buf[n]} =~ $_bt_re ]]; then found=$(( n + 1 )); break; fi
			done
		else
			for (( i = 1; i <= ${#buf[@]}; i++ )); do
				n=$(( (cur - i - 1 + 2 * ${#buf[@]}) % ${#buf[@]} ))
				if [[ ${buf[n]} =~ $_bt_re ]]; then found=$(( n + 1 )); break; fi
			done
		fi
		if [ "$found" -lt 0 ]; then _bt_ed_oops "No match"; return 1; fi
		_bt_ed_addr=$found ;;
	esac
	while :; do
		case ${cmd:ci:1} in
		'+'|'-')
			sign=${cmd:ci:1}
			ci=$(( ci + 1 ))
			n=
			while :; do
				case ${cmd:ci:1} in
				[0-9])	n=$n${cmd:ci:1}; ci=$(( ci + 1 )) ;;
				*)	break ;;
				esac
			done
			[ -n "$n" ] || n=1
			[ "$_bt_ed_addr" -lt 0 ] && _bt_ed_addr=$cur
			if [ "$sign" = + ]; then _bt_ed_addr=$(( _bt_ed_addr + 10#$n ))
			else _bt_ed_addr=$(( _bt_ed_addr - 10#$n )); fi ;;
		*)	break ;;
		esac
	done
	return 0
}

# Parse a whole address range into a1 and a2, and say in `nad` how many
# addresses were actually given.  Relies on its caller's locals.
_bt_ed_range() {
	nad=0
	if [ "${cmd:ci:1}" = '%' ]; then
		ci=$(( ci + 1 ))
		a1=1 a2=${#buf[@]} nad=2
		return 0
	fi
	_bt_ed_addr1 || return 1
	if [ "$_bt_ed_addr" -ge 0 ]; then a1=$_bt_ed_addr a2=$_bt_ed_addr nad=1; fi
	while [ "${cmd:ci:1}" = ',' ] || [ "${cmd:ci:1}" = ';' ]; do
		if [ "${cmd:ci:1}" = ';' ] && [ "$nad" -gt 0 ]; then cur=$a2; fi
		ci=$(( ci + 1 ))
		[ "$nad" = 0 ] && a1=1
		_bt_ed_addr1 || return 1
		if [ "$_bt_ed_addr" -ge 0 ]; then
			a2=$_bt_ed_addr
		else
			a2=${#buf[@]}
		fi
		[ "$nad" = 0 ] && { a1=1; nad=1; }
		nad=2
	done
	return 0
}

# Read lines from the input up to a lone dot into the `ins` array.
_bt_ed_input() {
	local line
	ins=()
	while IFS= read -r line <&"$infd"; do
		[ "$line" = '.' ] && return 0
		ins+=("$line")
	done
	return 0
}

# Print lines $1..$2 in style $3: p plain, n numbered, l unambiguous.
_bt_ed_print() {
	local i s c j out
	for (( i = $1; i <= $2; i++ )); do
		s=${buf[i-1]}
		case $3 in
		n)	printf '%d\t%s\n' "$i" "$s" ;;
		l)	out=
			for (( j = 0; j < ${#s}; j++ )); do
				c=${s:j:1}
				case $c in
				'\')	out=$out'\\' ;;
				$'\a')	out=$out'\a' ;;
				$'\b')	out=$out'\b' ;;
				$'\f')	out=$out'\f' ;;
				$'\n')	out=$out'\n' ;;
				$'\r')	out=$out'\r' ;;
				$'\t')	out=$out'\t' ;;
				$'\v')	out=$out'\v' ;;
				*)	_bt_ord "$c"
					if [ "$_bt_n" -lt 32 ] || [ "$_bt_n" -gt 126 ]; then
						printf -v c '\\%03o' "$_bt_n"
					fi
					out=$out$c ;;
				esac
			done
			printf '%s$\n' "$out" ;;
		*)	printf '%s\n' "$s" ;;
		esac
	done
	cur=$2
	return 0
}

ed () {
	local LC_ALL=C
	local prompt= silent=0 fname= cmd ci a1 a2 nad c line i j n rest
	local cur=0 modified=0 infd=0 fd bytes tmp suffix style
	local _bt_ed_msg= _bt_ed_help=0 _bt_ed_bad=0 _bt_ed_addr
	local _bt_lastre= _bt_lastrep= _bt_re status=0
	local -a buf=() ins=() undo=() _bt_ed_gl=()
	local -A _bt_ed_mark=()
	local undocur=0 haveundo=0 quit=0

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-s|-)	silent=1; shift ;;
		-p)	shift
			if [ "$#" = 0 ]; then
				_bt_err "ed: option requires an argument -- p"
				return 1
			fi
			prompt=$1; shift ;;
		-p*)	prompt=${1#-p}; shift ;;
		-*)	_bt_err "ed: illegal option -- ${1#-}"
			_bt_err "usage: ed [-p string] [-s] [file]"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ "$#" -gt 1 ]; then
		_bt_err "usage: ed [-p string] [-s] [file]"
		return 1
	fi
	[ "$#" = 1 ] && fname=$1

	if [ -n "$fname" ]; then
		bytes=0
		if { exec {fd}<"$fname"; } 2>/dev/null; then
			line=
			while IFS= read -r line <&"$fd"; do
				buf+=("$line")
				bytes=$(( bytes + ${#line} + 1 ))
				line=
			done
			if [ -n "$line" ]; then
				buf+=("$line")
				bytes=$(( bytes + ${#line} ))
			fi
			exec {fd}<&-
			cur=${#buf[@]}
			[ "$silent" = 1 ] || printf '%d\n' "$bytes"
		else
			[ "$silent" = 1 ] || printf '%s: No such file or directory\n' "$fname" >&2
			_bt_ed_msg="Cannot open input file"
		fi
	fi

	while :; do
		[ -n "$prompt" ] && printf '%s' "$prompt"
		IFS= read -r cmd <&"$infd" || break
		_bt_ed_one
		[ "$quit" = 1 ] && break
	done

	[ "$_bt_ed_bad" = 1 ] && return 1
	return 0
}

# Run the command sitting in `cmd`.  Relies on ed's locals, which is what lets
# the global commands hand it a command of their own.
_bt_ed_one() {
	local ci a1 a2 nad c rest i j n line bytes fd
	local -a ins=()
	ci=0
	a1=$cur a2=$cur
	_bt_ed_range || return 1
	while [ "${cmd:ci:1}" = ' ' ]; do ci=$(( ci + 1 )); done
	c=${cmd:ci:1}
	ci=$(( ci + 1 ))
	rest=${cmd:ci}

	case $c in
	'')	# a bare address prints that line
		if [ "$nad" = 0 ]; then a1=$(( cur + 1 )) a2=$a1; fi
		if [ "$a1" -lt 1 ] || [ "$a2" -gt "${#buf[@]}" ] || [ "$a1" -gt "$a2" ]; then
			_bt_ed_oops "Invalid address"; return 1
		fi
		_bt_ed_print "$a1" "$a2" p ;;
	a|i)	if [ "$nad" = 0 ]; then a1=$cur a2=$cur; fi
		if [ "$c" = i ] && [ "$a1" -gt 0 ]; then a1=$(( a1 - 1 )); fi
		if [ "$a1" -lt 0 ] || [ "$a1" -gt "${#buf[@]}" ]; then
			_bt_ed_oops "Invalid address"; return 1
		fi
		_bt_ed_save
		_bt_ed_input
		if [ "${#ins[@]}" -gt 0 ]; then
			buf=( ${buf[@]+"${buf[@]:0:a1}"} "${ins[@]}" \
			      ${buf[@]+"${buf[@]:a1}"} )
			cur=$(( a1 + ${#ins[@]} ))
			modified=1
		fi ;;
	c)	if [ "$nad" = 0 ]; then a1=$cur a2=$cur; fi
		if [ "$a1" -lt 1 ] || [ "$a2" -gt "${#buf[@]}" ] || [ "$a1" -gt "$a2" ]; then
			_bt_ed_oops "Invalid address"; return 1
		fi
		_bt_ed_save
		_bt_ed_input
		buf=( ${buf[@]+"${buf[@]:0:a1-1}"} ${ins[@]+"${ins[@]}"} \
		      ${buf[@]+"${buf[@]:a2}"} )
		cur=$(( a1 - 1 + ${#ins[@]} ))
		modified=1 ;;
	d)	if [ "$nad" = 0 ]; then a1=$cur a2=$cur; fi
		if [ "$a1" -lt 1 ] || [ "$a2" -gt "${#buf[@]}" ] || [ "$a1" -gt "$a2" ]; then
			_bt_ed_oops "Invalid address"; return 1
		fi
		_bt_ed_save
		buf=( ${buf[@]+"${buf[@]:0:a1-1}"} ${buf[@]+"${buf[@]:a2}"} )
		cur=$(( a1 - 1 ))
		[ "$cur" -lt 1 ] && [ "${#buf[@]}" -gt 0 ] && cur=1
		modified=1 ;;
	'=')	if [ "$nad" = 0 ]; then printf '%d\n' "${#buf[@]}"
		else printf '%d\n' "$a2"; fi ;;
	p|n|l)	if [ "$nad" = 0 ]; then a1=$cur a2=$cur; fi
		if [ "$a1" -lt 1 ] || [ "$a2" -gt "${#buf[@]}" ] || [ "$a1" -gt "$a2" ]; then
			_bt_ed_oops "Invalid address"; return 1
		fi
		_bt_ed_print "$a1" "$a2" "$c" ;;
	f)	rest=${rest# }
		if [ -n "$rest" ]; then fname=$rest; fi
		printf '%s\n' "$fname" ;;
	h)	[ -n "$_bt_ed_msg" ] && printf '%s\n' "$_bt_ed_msg" ;;
	H)	if [ "$_bt_ed_help" = 1 ]; then _bt_ed_help=0
		else
			_bt_ed_help=1
			[ -n "$_bt_ed_msg" ] && printf '%s\n' "$_bt_ed_msg"
		fi ;;
	P)	if [ -n "$prompt" ]; then prompt=; else prompt='*'; fi ;;
	j)	if [ "$nad" = 0 ]; then a1=$cur a2=$(( cur + 1 )); fi
		[ "$nad" = 1 ] && a2=$(( a1 + 1 ))
		if [ "$a1" -lt 1 ] || [ "$a2" -gt "${#buf[@]}" ] || [ "$a1" -ge "$a2" ]; then
			_bt_ed_oops "Invalid address"; return 1
		fi
		_bt_ed_save
		line=
		for (( i = a1; i <= a2; i++ )); do line=$line${buf[i-1]}; done
		buf=( ${buf[@]+"${buf[@]:0:a1-1}"} "$line" ${buf[@]+"${buf[@]:a2}"} )
		cur=$a1
		modified=1 ;;
	k)	if [ "$nad" = 0 ]; then a2=$cur; fi
		c=${cmd:ci:1}
		if [ -z "$c" ] || [ "$a2" -lt 1 ] || [ "$a2" -gt "${#buf[@]}" ]; then
			_bt_ed_oops "Invalid mark"; return 1
		fi
		_bt_ed_mark[$c]=$a2 ;;
	m|t)	if [ "$nad" = 0 ]; then a1=$cur a2=$cur; fi
		if [ "$a1" -lt 1 ] || [ "$a2" -gt "${#buf[@]}" ] || [ "$a1" -gt "$a2" ]; then
			_bt_ed_oops "Invalid address"; return 1
		fi
		_bt_ed_addr1 || return 1
		n=$_bt_ed_addr
		if [ "$n" -lt 0 ] || [ "$n" -gt "${#buf[@]}" ]; then
			_bt_ed_oops "Invalid address"; return 1
		fi
		if [ "$c" = m ] && [ "$n" -ge "$a1" ] && [ "$n" -lt "$a2" ]; then
			_bt_ed_oops "Invalid destination"; return 1
		fi
		_bt_ed_save
		ins=( "${buf[@]:a1-1:a2-a1+1}" )
		if [ "$c" = m ]; then
			buf=( ${buf[@]+"${buf[@]:0:a1-1}"} ${buf[@]+"${buf[@]:a2}"} )
			[ "$n" -gt "$a2" ] && n=$(( n - (a2 - a1 + 1) ))
		fi
		buf=( ${buf[@]+"${buf[@]:0:n}"} "${ins[@]}" ${buf[@]+"${buf[@]:n}"} )
		cur=$(( n + ${#ins[@]} ))
		modified=1 ;;
	s)	if [ "$nad" = 0 ]; then a1=$cur a2=$cur; fi
		if [ "$a1" -lt 1 ] || [ "$a2" -gt "${#buf[@]}" ] || [ "$a1" -gt "$a2" ]; then
			_bt_ed_oops "Invalid address"; return 1
		fi
		_bt_ed_dosub || return 1 ;;
	g|v|G|V)
		if [ "$nad" = 0 ]; then a1=1 a2=${#buf[@]}; fi
		_bt_ed_global || return 1 ;;
	r)	rest=${rest# }
		[ -n "$rest" ] || rest=$fname
		if [ -z "$rest" ]; then _bt_ed_oops "No current filename"; return 1; fi
		if [ "$nad" = 0 ]; then a2=${#buf[@]}; fi
		if ! { exec {fd}<"$rest"; } 2>/dev/null; then
			_bt_ed_oops "Cannot open input file"; return 1
		fi
		_bt_ed_save
		ins=() bytes=0
		line=
		while IFS= read -r line <&"$fd"; do
			ins+=("$line")
			bytes=$(( bytes + ${#line} + 1 ))
			line=
		done
		if [ -n "$line" ]; then ins+=("$line"); bytes=$(( bytes + ${#line} )); fi
		exec {fd}<&-
		[ -n "$fname" ] || fname=$rest
		if [ "${#ins[@]}" -gt 0 ]; then
			buf=( ${buf[@]+"${buf[@]:0:a2}"} "${ins[@]}" \
			      ${buf[@]+"${buf[@]:a2}"} )
			cur=$(( a2 + ${#ins[@]} ))
			modified=1
		fi
		[ "$silent" = 1 ] || printf '%d\n' "$bytes" ;;
	e|E)	rest=${rest# }
		if [ "$c" = e ] && [ "$modified" = 1 ]; then
			modified=0
			_bt_ed_oops "Warning: buffer modified"
			return 1
		fi
		[ -n "$rest" ] || rest=$fname
		if [ -z "$rest" ]; then _bt_ed_oops "No current filename"; return 1; fi
		if ! { exec {fd}<"$rest"; } 2>/dev/null; then
			_bt_ed_oops "Cannot open input file"; return 1
		fi
		_bt_ed_save
		buf=() bytes=0
		line=
		while IFS= read -r line <&"$fd"; do
			buf+=("$line")
			bytes=$(( bytes + ${#line} + 1 ))
			line=
		done
		if [ -n "$line" ]; then buf+=("$line"); bytes=$(( bytes + ${#line} )); fi
		exec {fd}<&-
		fname=$rest
		cur=${#buf[@]}
		modified=0
		[ "$silent" = 1 ] || printf '%d\n' "$bytes" ;;
	w|W)	rest=${rest# }
		[ -n "$rest" ] || rest=$fname
		if [ -z "$rest" ]; then _bt_ed_oops "No current filename"; return 1; fi
		if [ "$nad" = 0 ]; then a1=1 a2=${#buf[@]}; fi
		if [ "$c" = W ]; then
			exec {fd}>>"$rest" 2>/dev/null
		else
			exec {fd}>"$rest" 2>/dev/null
		fi
		if [ -z "${fd:-}" ]; then _bt_ed_oops "Cannot open output file"; return 1; fi
		bytes=0
		for (( i = a1; i <= a2; i++ )); do
			printf '%s\n' "${buf[i-1]}" >&"$fd"
			bytes=$(( bytes + ${#buf[i-1]} + 1 ))
		done
		exec {fd}>&-
		[ -n "$fname" ] || fname=$rest
		modified=0
		[ "$silent" = 1 ] || printf '%d\n' "$bytes" ;;
	u)	if [ "$haveundo" = 0 ]; then _bt_ed_oops "Nothing to undo"; return 1; fi
		ins=( ${buf[@]+"${buf[@]}"} )
		n=$cur
		buf=( ${undo[@]+"${undo[@]}"} )
		cur=$undocur
		undo=( ${ins[@]+"${ins[@]}"} )
		undocur=$n
		modified=1 ;;
	q|Q)	if [ "$c" = q ] && [ "$modified" = 1 ]; then
			modified=0
			_bt_ed_oops "Warning: buffer modified"
			return 1
		fi
		quit=1
		return 0 ;;
	'!')	_bt_ed_oops "Cannot run a command: there is nothing to run it with"
		return 1 ;;
	*)	_bt_ed_oops "Unknown command"
		return 1 ;;
	esac
	return 0
}

# Remember the buffer so u can put it back.  Relies on its caller's locals.
_bt_ed_save() {
	undo=( ${buf[@]+"${buf[@]}"} )
	undocur=$cur
	haveundo=1
	return 0
}

# The s command, over lines a1..a2.  Relies on its caller's locals.
_bt_ed_dosub() {
	local delim re rep flags i any=0 subflag pat
	delim=${cmd:ci:1}
	if [ -z "$delim" ]; then _bt_ed_oops "Invalid pattern delimiter"; return 1; fi
	ci=$(( ci + 1 ))
	re=
	while [ "$ci" -lt "${#cmd}" ] && [ "${cmd:ci:1}" != "$delim" ]; do
		if [ "${cmd:ci:1}" = '\' ]; then
			re=$re${cmd:ci:1}
			ci=$(( ci + 1 ))
		fi
		re=$re${cmd:ci:1}
		ci=$(( ci + 1 ))
	done
	[ "${cmd:ci:1}" = "$delim" ] && ci=$(( ci + 1 ))
	rep=
	while [ "$ci" -lt "${#cmd}" ] && [ "${cmd:ci:1}" != "$delim" ]; do
		if [ "${cmd:ci:1}" = '\' ]; then
			rep=$rep${cmd:ci:1}
			ci=$(( ci + 1 ))
		fi
		rep=$rep${cmd:ci:1}
		ci=$(( ci + 1 ))
	done
	[ "${cmd:ci:1}" = "$delim" ] && ci=$(( ci + 1 ))
	flags=${cmd:ci}
	[ -n "$re" ] || re=$_bt_lastre
	if [ -z "$re" ]; then _bt_ed_oops "No previous pattern"; return 1; fi
	if [ "$rep" = '%' ]; then rep=$_bt_lastrep; fi
	_bt_lastrep=$rep
	_bt_ed_save
	for (( i = a1; i <= a2; i++ )); do
		pat=${buf[i-1]}
		subflag=0
		_bt_sed_sub "$re" "$rep" "${flags//[pnl]/}"
		if [ "$subflag" = 1 ]; then
			buf[i-1]=$pat
			cur=$i
			any=1
			modified=1
		fi
	done
	if [ "$any" = 0 ]; then _bt_ed_oops "No match"; return 1; fi
	case $flags in
	*p*)	_bt_ed_print "$cur" "$cur" p ;;
	*n*)	_bt_ed_print "$cur" "$cur" n ;;
	*l*)	_bt_ed_print "$cur" "$cur" l ;;
	esac
	return 0
}

# The g, v, G and V commands.  Relies on its caller's locals.
_bt_ed_global() {
	local delim re i n inverse=0 interactive=0 sub line
	local -a marked=()
	case $c in
	v|V)	inverse=1 ;;
	esac
	case $c in
	G|V)	interactive=1 ;;
	esac
	delim=${cmd:ci:1}
	if [ -z "$delim" ]; then _bt_ed_oops "Invalid pattern delimiter"; return 1; fi
	ci=$(( ci + 1 ))
	re=
	while [ "$ci" -lt "${#cmd}" ] && [ "${cmd:ci:1}" != "$delim" ]; do
		if [ "${cmd:ci:1}" = '\' ]; then
			re=$re${cmd:ci:1}
			ci=$(( ci + 1 ))
		fi
		re=$re${cmd:ci:1}
		ci=$(( ci + 1 ))
	done
	[ "${cmd:ci:1}" = "$delim" ] && ci=$(( ci + 1 ))
	[ -n "$re" ] || re=$_bt_lastre
	if [ -z "$re" ]; then _bt_ed_oops "No previous pattern"; return 1; fi
	_bt_lastre=$re
	_bt_sed_re "$re"
	sub=${cmd:ci}
	[ -n "$sub" ] || sub=p
	for (( i = a1; i <= a2; i++ )); do
		if [[ ${buf[i-1]} =~ $_bt_re ]]; then
			[ "$inverse" = 0 ] && marked+=("${buf[i-1]}")
		else
			[ "$inverse" = 1 ] && marked+=("${buf[i-1]}")
		fi
	done
	# The marked lines are remembered by content, since the commands run over
	# them may move everything around underneath.
	for line in ${marked[@]+"${marked[@]}"}; do
		n=-1
		for (( i = 1; i <= ${#buf[@]}; i++ )); do
			if [ "${buf[i-1]}" = "$line" ]; then n=$i; break; fi
		done
		[ "$n" -lt 0 ] && continue
		cur=$n
		if [ "$interactive" = 1 ]; then
			_bt_ed_print "$n" "$n" p
			IFS= read -r cmd <&"$infd" || break
			[ -z "$cmd" ] && continue
		else
			cmd=$sub
		fi
		_bt_ed_one
	done
	return 0
}

# ---------------------------------------------------------------------------
# m4 -- POSIX.1-2017: m4 [-s] [-D name[=val]]... [-U name]... [file...]
#
# The input is a string with a cursor in it.  What a macro expands to is put
# back in front of the cursor and read again, which is m4's whole model; the
# arguments of a call are collected with the quoting intact and expanded on
# their own before the call is made.
# ---------------------------------------------------------------------------

# The names of the built-in macros, so that they can be told from a definition.
_BT_M4_BUILTINS='define undefine defn pushdef popdef ifdef ifelse shift dnl
	dumpdef errprint eval include sinclude incr decr index len substr
	translit changequote changecom divert divnum undivert m4exit m4wrap
	maketemp mkstemp syscmd sysval traceon traceoff'

# Move the text gathered so far into the diversion it belongs to.  Relies on
# its caller's locals.
_bt_m4_flush() {
	local pre rest
	# a built-in that found its way into the text prints as nothing
	while [ "${out#*$'\001'}" != "$out" ]; do
		pre=${out%%$'\001'*}
		rest=${out#*$'\001'}
		while :; do
			case $rest in
			[a-z]*)	rest=${rest#?} ;;
			*)	break ;;
			esac
		done
		out=$pre$rest
	done
	if [ "$divnum" = 0 ]; then
		printf '%s' "$out"
	elif [ "$divnum" -gt 0 ]; then
		divs[divnum]=${divs[divnum]-}$out
	fi
	out=
	return 0
}

# Read the quoted string at `p` into _bt_m4_str, quotes stripped, nesting
# honoured.  Relies on its caller's locals.
_bt_m4_quoted() {
	local depth=1 s=
	p=$(( p + ${#lq} ))
	while [ "$p" -lt "${#in}" ]; do
		if [ "${in:p:${#lq}}" = "$lq" ]; then
			depth=$(( depth + 1 ))
			s=$s$lq
			p=$(( p + ${#lq} ))
		elif [ "${in:p:${#rq}}" = "$rq" ]; then
			depth=$(( depth - 1 ))
			p=$(( p + ${#rq} ))
			[ "$depth" = 0 ] && break
			s=$s$rq
		else
			s=$s${in:p:1}
			p=$(( p + 1 ))
		fi
	done
	_bt_m4_str=$s
	return 0
}

# Collect the arguments of a call, cursor just past the opening parenthesis,
# into the `args` array, still quoted.  Relies on its caller's locals.
_bt_m4_rawargs() {
	local depth=1 cur= c seen=0
	args=()
	# leading blanks before an argument are not part of it
	while :; do
		case ${in:p:1} in
		' '|$'\t'|$'\n')	p=$(( p + 1 )) ;;
		*)			break ;;
		esac
	done
	while [ "$p" -lt "${#in}" ]; do
		if [ "${in:p:${#lq}}" = "$lq" ]; then
			local q=$p
			_bt_m4_skipquoted
			cur=$cur${in:q:p-q}
			seen=1
			continue
		fi
		c=${in:p:1}
		case $c in
		'(')	depth=$(( depth + 1 )); cur=$cur$c; p=$(( p + 1 )); seen=1 ;;
		')')	depth=$(( depth - 1 ))
			p=$(( p + 1 ))
			if [ "$depth" = 0 ]; then
				args+=("$cur")
				return 0
			fi
			cur=$cur$c
			seen=1 ;;
		',')	if [ "$depth" = 1 ]; then
				args+=("$cur")
				cur=
				seen=0
				p=$(( p + 1 ))
				while :; do
					case ${in:p:1} in
					' '|$'\t'|$'\n')	p=$(( p + 1 )) ;;
					*)			break ;;
					esac
				done
			else
				cur=$cur$c
				p=$(( p + 1 ))
			fi ;;
		*)	cur=$cur$c; p=$(( p + 1 )); seen=1 ;;
		esac
	done
	args+=("$cur")
	return 0
}

# Step the cursor over a quoted string without keeping it.  Relies on its
# caller's locals.
_bt_m4_skipquoted() {
	local depth=1
	p=$(( p + ${#lq} ))
	while [ "$p" -lt "${#in}" ]; do
		if [ "${in:p:${#lq}}" = "$lq" ]; then
			depth=$(( depth + 1 ))
			p=$(( p + ${#lq} ))
		elif [ "${in:p:${#rq}}" = "$rq" ]; then
			depth=$(( depth - 1 ))
			p=$(( p + ${#rq} ))
			[ "$depth" = 0 ] && return 0
		else
			p=$(( p + 1 ))
		fi
	done
	return 0
}

# Expand $1 on its own and leave the result in _bt_m4_str.
_bt_m4_expand() {
	local _bt_m4_str
	_bt_m4_process "$1"
	_bt_m4_str=$_bt_m4_res
	_bt_m4_res=$_bt_m4_str
	return 0
}

# Expand the a-z ranges in a translit set into _bt_m4_str.
_bt_m4_set() {
	local s=$1 out= i c lo hi j
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		if [ "$c" = '-' ] && [ -n "$out" ] && [ $(( i + 1 )) -lt "${#s}" ]; then
			_bt_ord "${out: -1}"; lo=$_bt_n
			_bt_ord "${s:i+1:1}"; hi=$_bt_n
			i=$(( i + 1 ))
			if [ "$lo" -le "$hi" ]; then
				for (( j = lo + 1; j <= hi; j++ )); do
					_bt_chr "$j"; out=$out$_bt_c
				done
			else
				for (( j = lo - 1; j >= hi; j-- )); do
					_bt_chr "$j"; out=$out$_bt_c
				done
			fi
			continue
		fi
		out=$out$c
	done
	_bt_m4_str=$out
	return 0
}

# Evaluate an m4 arithmetic expression.  Only the characters an expression can
# be made of are allowed through, so that the shell cannot be handed a name to
# look up.
_bt_m4_eval() {
	local e=$1 v
	case $e in
	*[!0-9+\ \	*/%\(\)\<\>=\!\&\|^~-]*)
		_bt_err "m4: bad expression in eval: $1"
		_bt_m4_str=
		return 1 ;;
	esac
	[ -n "${e//[ 	]/}" ] || { _bt_m4_str=0; return 0; }
	v=$(( e ))
	_bt_m4_str=$v
	return 0
}

# Write $1 in base $2, padded to at least $3 digits, into _bt_m4_str.
_bt_m4_radix() {
	local v=$1 base=$2 width=${3:-1} neg= d s=
	local digits=0123456789abcdefghijklmnopqrstuvwxyz
	if [ "$base" -lt 2 ] || [ "$base" -gt 36 ]; then
		_bt_err "m4: radix out of range in eval: $base"
		_bt_m4_str=
		return 1
	fi
	if [ "$v" -lt 0 ]; then neg=-; v=$(( -v )); fi
	if [ "$v" = 0 ]; then s=0; fi
	while [ "$v" -gt 0 ]; do
		d=$(( v % base ))
		s=${digits:d:1}$s
		v=$(( v / base ))
	done
	while [ "${#s}" -lt "$width" ]; do s=0$s; done
	_bt_m4_str=$neg$s
	return 0
}

# Call macro $1 with the collected `args`; the expansion goes in _bt_m4_str.
# Relies on its caller's locals.
_bt_m4_call() {
	local name=$1 body i j n c s t from to nargs _bt_n _bt_c
	local a1=${args[0]-} a2=${args[1]-} a3=${args[2]-} a4=${args[3]-}
	nargs=${#args[@]}
	body=${def[$name]}
	_bt_m4_str=

	case $body in
	$'\001'*)	;;
	*)	# a macro of one's own: the arguments go where the $s are
		s=
		for (( i = 0; i < ${#body}; i++ )); do
			c=${body:i:1}
			if [ "$c" != '$' ] || [ $(( i + 1 )) -ge "${#body}" ]; then
				s=$s$c
				continue
			fi
			i=$(( i + 1 ))
			case ${body:i:1} in
			[0-9])	n=${body:i:1}
				if [ "$n" = 0 ]; then s=$s$name
				else s=$s${args[n-1]-}; fi ;;
			'#')	s=$s$nargs ;;
			'*')	t=
				for (( j = 0; j < nargs; j++ )); do
					[ "$j" -gt 0 ] && t=$t,
					t=$t${args[j]}
				done
				s=$s$t ;;
			'@')	t=
				for (( j = 0; j < nargs; j++ )); do
					[ "$j" -gt 0 ] && t=$t,
					t=$t$lq${args[j]}$rq
				done
				s=$s$t ;;
			*)	s=$s'$'${body:i:1} ;;
			esac
		done
		_bt_m4_str=$s
		return 0 ;;
	esac

	case ${body#$'\001'} in
	define)		[ -n "$a1" ] && def[$a1]=$a2 ;;
	undefine)	[ -n "$a1" ] && unset "def[$a1]" ;;
	defn)		if [ -n "${def[$a1]+x}" ]; then
				case ${def[$a1]} in
				$'\001'*)	_bt_m4_str=${def[$a1]} ;;
				*)		_bt_m4_str=$lq${def[$a1]}$rq ;;
				esac
			fi ;;
	pushdef)	if [ -n "$a1" ]; then
				n=${depth[$a1]-0}
				if [ -n "${def[$a1]+x}" ]; then
					stackv[$a1.$n]=${def[$a1]}
					stackd[$a1.$n]=1
				else
					stackd[$a1.$n]=0
				fi
				depth[$a1]=$(( n + 1 ))
				def[$a1]=$a2
			fi ;;
	popdef)		if [ -n "$a1" ] && [ "${depth[$a1]-0}" -gt 0 ]; then
				n=$(( depth[$a1] - 1 ))
				depth[$a1]=$n
				if [ "${stackd[$a1.$n]}" = 1 ]; then
					def[$a1]=${stackv[$a1.$n]}
				else
					unset "def[$a1]"
				fi
			elif [ -n "$a1" ]; then
				unset "def[$a1]"
			fi ;;
	ifdef)		if [ -n "${def[$a1]+x}" ]; then _bt_m4_str=$a2
			else _bt_m4_str=$a3; fi ;;
	ifelse)		if [ "$nargs" -le 1 ]; then
				_bt_m4_str=
			else
				i=0
				while [ $(( i + 1 )) -lt "$nargs" ]; do
					if [ "${args[i]}" = "${args[i+1]}" ]; then
						_bt_m4_str=${args[i+2]-}
						break
					fi
					if [ $(( i + 4 )) -ge "$nargs" ]; then
						[ $(( i + 3 )) -lt "$nargs" ] &&
							_bt_m4_str=${args[i+3]}
						break
					fi
					i=$(( i + 3 ))
				done
			fi ;;
	shift)		t=
			for (( j = 1; j < nargs; j++ )); do
				[ "$j" -gt 1 ] && t=$t,
				t=$t$lq${args[j]}$rq
			done
			_bt_m4_str=$t ;;
	dnl)		while [ "$p" -lt "${#in}" ] && [ "${in:p:1}" != $'\n' ]; do
				p=$(( p + 1 ))
			done
			[ "$p" -lt "${#in}" ] && p=$(( p + 1 )) ;;
	dumpdef)	if [ "$nargs" -le 1 ] && [ -z "$a1" ]; then
				for i in "${!def[@]}"; do
					printf '%s:\t%s\n' "$i" "${def[$i]}" >&2
				done
			else
				for i in "${args[@]}"; do
					printf '%s:\t%s\n' "$i" "${def[$i]-}" >&2
				done
			fi ;;
	errprint)	t=
			for (( j = 0; j < nargs; j++ )); do
				[ "$j" -gt 0 ] && t=$t' '
				t=$t${args[j]}
			done
			printf '%s' "$t" >&2 ;;
	eval)		if _bt_m4_eval "$a1"; then
				if [ -n "$a2" ]; then
					_bt_m4_radix "$_bt_m4_str" "$a2" "${a3:-1}"
				fi
			fi ;;
	incr)		_bt_m4_eval "${a1:-0}" && _bt_m4_str=$(( _bt_m4_str + 1 )) ;;
	decr)		_bt_m4_eval "${a1:-0}" && _bt_m4_str=$(( _bt_m4_str - 1 )) ;;
	len)		_bt_m4_str=${#a1} ;;
	index)		_bt_m4_str=-1
			n=${#a1}
			for (( j = 0; j <= n - ${#a2}; j++ )); do
				if [ "${a1:j:${#a2}}" = "$a2" ]; then
					_bt_m4_str=$j
					break
				fi
			done ;;
	substr)		n=${#a1}
			i=${a2:-0}
			[ "$i" -lt 0 ] && i=0
			if [ "$nargs" -ge 3 ] && [ -n "$a3" ]; then j=$a3
			else j=$(( n - i )); fi
			[ "$j" -lt 0 ] && j=0
			_bt_m4_str=${a1:i:j} ;;
	translit)	_bt_m4_set "$a2"; from=$_bt_m4_str
			_bt_m4_set "$a3"; to=$_bt_m4_str
			s=
			for (( j = 0; j < ${#a1}; j++ )); do
				c=${a1:j:1}
				t=${from%%"$c"*}
				if [ "${#t}" -lt "${#from}" ]; then
					if [ "${#t}" -lt "${#to}" ]; then
						s=$s${to:${#t}:1}
					fi
				else
					s=$s$c
				fi
			done
			_bt_m4_str=$s ;;
	changequote)	if [ "$nargs" -le 1 ] && [ -z "$a1" ]; then lq='`' rq="'"
			else lq=${a1:-'`'} rq=${a2:-"'"}; fi ;;
	changecom)	if [ "$nargs" -le 1 ] && [ -z "$a1" ]; then com= ecom=
			else com=$a1 ecom=${a2:-$'\n'}; fi ;;
	divert)		_bt_m4_flush
			divnum=${a1:-0}
			case $divnum in
			''|*[!0-9-]*)	divnum=0 ;;
			esac ;;
	divnum)		_bt_m4_str=$divnum ;;
	undivert)	_bt_m4_flush
			if [ "$nargs" -le 1 ] && [ -z "$a1" ]; then
				for (( j = 1; j < 10; j++ )); do
					if [ -n "${divs[j]-}" ]; then
						out=$out${divs[j]}
						divs[j]=
					fi
				done
			else
				for i in "${args[@]}"; do
					case $i in
					''|*[!0-9]*)	continue ;;
					esac
					[ "$i" = 0 ] && continue
					out=$out${divs[i]-}
					divs[i]=
				done
			fi ;;
	m4exit)		_bt_m4_flush
			status=${a1:-0}
			case $status in
			''|*[!0-9]*)	status=0 ;;
			esac
			quit=1 ;;
	m4wrap)		wrap+=("$a1") ;;
	maketemp|mkstemp)
			s=$a1
			t=${s%%XXXXXX*}
			if [ "${#t}" -lt "${#s}" ]; then
				printf -v c '%06d' $(( (BASHPID + RANDOM) % 1000000 ))
				_bt_m4_str=$t$c${s:${#t}+6}
				: > "$_bt_m4_str" 2>/dev/null
			else
				_bt_m4_str=$s
			fi ;;
	syscmd|sysval)
			if [ "${body#$'\001'}" = syscmd ]; then
				_bt_err "m4: syscmd: no way to run a command here"
				sysval=127
			else
				_bt_m4_str=$sysval
			fi ;;
	include|sinclude)
			if [ -r "$a1" ]; then
				s=
				t=
				while IFS= read -r c; do s=$s$t$c; t=$'\n'; done < "$a1"
				# a file that ends in a newline keeps it
				[ -n "$s" ] && s=$s$'\n'
				_bt_m4_str=$s
			elif [ "${body#$'\001'}" = include ]; then
				_bt_err "m4: cannot open $a1"
				status=1
			fi ;;
	traceon|traceoff)	;;
	esac
	return 0
}

# Expand $1; the result lands in _bt_m4_res.
_bt_m4_process() {
	local in=$1 p=0 out= name c fast
	local -a args=()
	local _bt_m4_str
	while [ "$p" -lt "${#in}" ]; do
		if [ "${in:p:${#lq}}" = "$lq" ]; then
			_bt_m4_quoted
			out=$out$_bt_m4_str
			continue
		fi
		if [ -n "$com" ] && [ "${in:p:${#com}}" = "$com" ]; then
			out=$out$com
			p=$(( p + ${#com} ))
			while [ "$p" -lt "${#in}" ]; do
				if [ "${in:p:${#ecom}}" = "$ecom" ]; then
					out=$out$ecom
					p=$(( p + ${#ecom} ))
					break
				fi
				out=$out${in:p:1}
				p=$(( p + 1 ))
			done
			continue
		fi
		c=${in:p:1}
		case $c in
		[A-Za-z_])
			name=
			while :; do
				case ${in:p:1} in
				[A-Za-z0-9_])	name=$name${in:p:1}; p=$(( p + 1 )) ;;
				*)		break ;;
				esac
			done
			if [ -n "${def[$name]+x}" ]; then
				args=()
				if [ "${in:p:1}" = '(' ]; then
					p=$(( p + 1 ))
					_bt_m4_rawargs
					for (( c = 0; c < ${#args[@]}; c++ )); do
						_bt_m4_process "${args[c]}"
						args[c]=$_bt_m4_res
					done
				fi
				_bt_m4_call "$name"
				[ "$quit" = 1 ] && break
				case $_bt_m4_str in
				$'\001'*)
					# what defn hands back is a built-in
					# itself, not text to be read again
					out=$out$_bt_m4_str ;;
				*)	in=$_bt_m4_str${in:p}
					p=0 ;;
				esac
			else
				out=$out$name
			fi ;;
		*)	# a run of ordinary text can go over in one piece
			if [[ ${in:p} =~ ^([^A-Za-z_$'\001'${lq:0:1}${com:0:1}]+) ]]; then
				out=$out${BASH_REMATCH[1]}
				p=$(( p + ${#BASH_REMATCH[1]} ))
			else
				out=$out$c
				p=$(( p + 1 ))
			fi ;;
		esac
	done
	_bt_m4_res=$out
	return 0
}

m4 () {
	local LC_ALL=C
	local arg opt val name text file line t i status=0 quit=0 sysval=0
	local lq='`' rq="'" com='#' ecom=$'\n' divnum=0 out= sync=0
	local _bt_m4_res _bt_m4_str
	local -A def=() stackv=() stackd=() depth=()
	local -a divs=() wrap=() args=()

	for name in $_BT_M4_BUILTINS; do
		def[$name]=$'\001'$name
	done

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-s)	sync=1; shift ;;
		-D|-U)	opt=${1#-}
			shift
			if [ "$#" = 0 ]; then
				_bt_err "m4: option requires an argument -- $opt"
				return 1
			fi
			val=$1; shift
			if [ "$opt" = D ]; then
				case $val in
				*=*)	def[${val%%=*}]=${val#*=} ;;
				*)	def[$val]= ;;
				esac
			else
				unset "def[$val]"
			fi ;;
		-D*)	val=${1#-D}; shift
			case $val in
			*=*)	def[${val%%=*}]=${val#*=} ;;
			*)	def[$val]= ;;
			esac ;;
		-U*)	val=${1#-U}; shift; unset "def[$val]" ;;
		-*)	[ "$1" = - ] && break
			_bt_err "m4: illegal option -- ${1#-}"
			_bt_err "usage: m4 [-s] [-D name[=value]]... [-U name]... [file...]"
			return 1 ;;
		*)	break ;;
		esac
	done

	text=
	if [ "$#" = 0 ]; then set -- -; fi
	for file in "$@"; do
		t=
		if [ "$file" = - ]; then
			line=
			while IFS= read -r line; do t=$t$line$'\n'; line=; done
			[ -n "$line" ] && t=$t$line
		elif [ -r "$file" ]; then
			line=
			while IFS= read -r line; do t=$t$line$'\n'; line=; done < "$file"
			[ -n "$line" ] && t=$t$line
		else
			_bt_err "m4: cannot open $file"
			status=1
			continue
		fi
		text=$text$t
	done

	_bt_m4_process "$text"
	out=$out$_bt_m4_res
	for (( i = 0; i < ${#wrap[@]} && quit == 0; i++ )); do
		_bt_m4_process "${wrap[i]}"
		out=$out$_bt_m4_res
	done
	_bt_m4_flush
	divnum=0
	for (( i = 1; i < 10; i++ )); do
		[ -n "${divs[i]-}" ] && printf '%s' "${divs[i]}"
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# iconv -- POSIX.1-2017:
#	iconv [-cs] -f frommap -t tomap [file...]
#	iconv -f fromcode [-cs] [-t tocode] [file...]
#	iconv -l
#
# Input is decoded to code points and the code points are encoded again, so any
# pair of the character sets below can be converted to any other.  The sets are
# the ones a shell can carry a table for: the Unicode encodings, ASCII, the two
# Latin ones and the Windows page that is so often mistaken for them.
# ---------------------------------------------------------------------------

# byte:code point, for the places where a set differs from Latin-1
_BT_ICONV_8859_15='164:8364 166:352 168:353 180:381 184:382 188:338 189:339 190:376'
_BT_ICONV_1252='128:8364 130:8218 131:402 132:8222 133:8230 134:8224 135:8225
	136:710 137:8240 138:352 139:8249 140:338 142:381 145:8216 146:8217
	147:8220 148:8221 149:8226 150:8211 151:8212 152:732 153:8482 154:353
	155:8250 156:339 158:382 159:376'

# The canonical name of character set $1, in _bt_str; empty when it is not one
# of the sets here.
_bt_iconv_norm() {
	local n=${1^^}
	n=${n%//TRANSLIT}
	n=${n%//IGNORE}
	case $n in
	UTF-8|UTF8)			_bt_str=UTF-8 ;;
	ASCII|US-ASCII|ANSI_X3.4-1968|ISO-IR-6|646|IBM367|CP367)
					_bt_str=ASCII ;;
	ISO-8859-1|ISO8859-1|ISO_8859-1|LATIN1|L1|IBM819|CP819)
					_bt_str=8859-1 ;;
	ISO-8859-15|ISO8859-15|ISO_8859-15|LATIN9|L9)
					_bt_str=8859-15 ;;
	CP1252|WINDOWS-1252|MS-ANSI)	_bt_str=1252 ;;
	UTF-16|UTF16)			_bt_str=UTF-16 ;;
	UTF-16LE|UTF16LE|UCS-2LE)	_bt_str=UTF-16LE ;;
	UTF-16BE|UTF16BE|UCS-2BE)	_bt_str=UTF-16BE ;;
	UTF-32|UTF32|UCS-4)		_bt_str=UTF-32 ;;
	UTF-32LE|UTF32LE|UCS-4LE)	_bt_str=UTF-32LE ;;
	UTF-32BE|UTF32BE|UCS-4BE)	_bt_str=UTF-32BE ;;
	*)				_bt_str= ; return 1 ;;
	esac
	return 0
}

# Decode the bytes in _bt_b as character set $1 into the `cps` array.  Relies
# on its caller's locals for `drop` and `status`.
_bt_iconv_decode() {
	local set=$1 n=${#_bt_b[@]} i=0 b c j need cp pair lo hi
	local -A tbl=()
	cps=()
	case $set in
	8859-15)	for pair in $_BT_ICONV_8859_15; do tbl[${pair%%:*}]=${pair#*:}; done ;;
	1252)		for pair in $_BT_ICONV_1252; do tbl[${pair%%:*}]=${pair#*:}; done ;;
	esac
	case $set in
	UTF-8)
		while [ "$i" -lt "$n" ]; do
			b=${_bt_b[i]}
			if [ "$b" -lt 128 ]; then
				cps+=("$b"); i=$(( i + 1 )); continue
			fi
			if [ "$b" -ge 240 ] && [ "$b" -le 247 ]; then need=3 cp=$(( b & 7 ))
			elif [ "$b" -ge 224 ]; then need=2 cp=$(( b & 15 ))
			elif [ "$b" -ge 192 ]; then need=1 cp=$(( b & 31 ))
			else
				_bt_iconv_bad "$i" || return 1
				i=$(( i + 1 )); continue
			fi
			if [ $(( i + need )) -ge "$n" ]; then
				# a sequence cut off by the end of the input is
				# not something -c can paper over
				_bt_iconv_short
				return 1
			fi
			c=1
			for (( j = 1; j <= need; j++ )); do
				b=${_bt_b[i+j]}
				if [ "$b" -lt 128 ] || [ "$b" -gt 191 ]; then c=0; break; fi
				cp=$(( cp << 6 | (b & 63) ))
			done
			if [ "$c" = 0 ] || ! _bt_iconv_ok "$cp" ||
			   { [ "$need" = 1 ] && [ "$cp" -lt 128 ]; } ||
			   { [ "$need" = 2 ] && [ "$cp" -lt 2048 ]; } ||
			   { [ "$need" = 3 ] && [ "$cp" -lt 65536 ]; }; then
				_bt_iconv_bad "$i" || return 1
				i=$(( i + 1 )); continue
			fi
			cps+=("$cp")
			i=$(( i + need + 1 ))
		done ;;
	ASCII)
		while [ "$i" -lt "$n" ]; do
			b=${_bt_b[i]}
			if [ "$b" -gt 127 ]; then
				_bt_iconv_bad "$i" || return 1
			else
				cps+=("$b")
			fi
			i=$(( i + 1 ))
		done ;;
	8859-1|8859-15|1252)
		while [ "$i" -lt "$n" ]; do
			b=${_bt_b[i]}
			cp=${tbl[$b]-$b}
			if [ "$set" = 1252 ] && [ "$b" -ge 128 ] && [ "$b" -le 159 ] &&
			   [ -z "${tbl[$b]-}" ]; then
				_bt_iconv_bad "$i" || return 1
			else
				cps+=("$cp")
			fi
			i=$(( i + 1 ))
		done ;;
	UTF-16|UTF-16LE|UTF-16BE)
		local big=0
		[ "$set" = UTF-16BE ] && big=1
		if [ "$set" = UTF-16 ]; then
			big=0
			if [ "$n" -ge 2 ]; then
				if [ "${_bt_b[0]}" = 255 ] && [ "${_bt_b[1]}" = 254 ]; then
					big=0; i=2
				elif [ "${_bt_b[0]}" = 254 ] && [ "${_bt_b[1]}" = 255 ]; then
					big=1; i=2
				fi
			fi
		fi
		while [ $(( i + 1 )) -lt "$n" ]; do
			if [ "$big" = 1 ]; then cp=$(( _bt_b[i] << 8 | _bt_b[i+1] ))
			else cp=$(( _bt_b[i+1] << 8 | _bt_b[i] )); fi
			i=$(( i + 2 ))
			if [ "$cp" -ge 55296 ] && [ "$cp" -le 56319 ]; then
				if [ $(( i + 1 )) -ge "$n" ]; then
					_bt_iconv_short
					return 1
				fi
				if [ "$big" = 1 ]; then lo=$(( _bt_b[i] << 8 | _bt_b[i+1] ))
				else lo=$(( _bt_b[i+1] << 8 | _bt_b[i] )); fi
				if [ "$lo" -lt 56320 ] || [ "$lo" -gt 57343 ]; then
					_bt_iconv_bad $(( i - 2 )) || return 1
					continue
				fi
				cp=$(( 65536 + ((cp - 55296) << 10) + (lo - 56320) ))
				i=$(( i + 2 ))
			elif [ "$cp" -ge 56320 ] && [ "$cp" -le 57343 ]; then
				_bt_iconv_bad $(( i - 2 )) || return 1
				continue
			fi
			cps+=("$cp")
		done
		if [ "$i" -lt "$n" ]; then _bt_iconv_short; return 1; fi ;;
	UTF-32|UTF-32LE|UTF-32BE)
		local big=0
		[ "$set" = UTF-32BE ] && big=1
		if [ "$set" = UTF-32 ]; then
			big=0
			if [ "$n" -ge 4 ]; then
				if [ "${_bt_b[0]}" = 255 ] && [ "${_bt_b[1]}" = 254 ] &&
				   [ "${_bt_b[2]}" = 0 ] && [ "${_bt_b[3]}" = 0 ]; then
					big=0; i=4
				elif [ "${_bt_b[0]}" = 0 ] && [ "${_bt_b[1]}" = 0 ] &&
				     [ "${_bt_b[2]}" = 254 ] && [ "${_bt_b[3]}" = 255 ]; then
					big=1; i=4
				fi
			fi
		fi
		while [ $(( i + 3 )) -lt "$n" ]; do
			if [ "$big" = 1 ]; then
				cp=$(( _bt_b[i] << 24 | _bt_b[i+1] << 16 | _bt_b[i+2] << 8 | _bt_b[i+3] ))
			else
				cp=$(( _bt_b[i+3] << 24 | _bt_b[i+2] << 16 | _bt_b[i+1] << 8 | _bt_b[i] ))
			fi
			if ! _bt_iconv_ok "$cp"; then
				# a 32-bit word that is not a character at all
				# stops the conversion, -c or no -c, which is
				# what iconv does with it
				[ "$quiet" = 1 ] ||
					_bt_err "iconv: illegal input sequence at position $i"
				status=1
				return 1
			fi
			cps+=("$cp")
			i=$(( i + 4 ))
		done
		if [ "$i" -lt "$n" ]; then _bt_iconv_short; return 1; fi ;;
	esac
	return 0
}

# Is $1 a code point at all?
_bt_iconv_ok() {
	[ "$1" -gt 1114111 ] && return 1
	[ "$1" -ge 55296 ] && [ "$1" -le 57343 ] && return 1
	return 0
}

# The input stopped in the middle of a character, which -c does not excuse.
_bt_iconv_short() {
	[ "$quiet" = 1 ] ||
		_bt_err "iconv: incomplete character or shift sequence at end of buffer"
	status=1
	return 1
}

# Complain about the byte at $1, or say nothing if -c asked for silence.
# Returns non-zero when the conversion should stop.  Relies on its caller.
_bt_iconv_bad() {
	if [ "$drop" = 1 ]; then return 0; fi
	[ "$quiet" = 1 ] || _bt_err "iconv: illegal input sequence at position $1"
	status=1
	return 1
}

# Encode the `cps` array as character set $1, writing as it goes.
_bt_iconv_encode() {
	local set=$1 i cp esc= out= pair b hi lo
	local -A rev=()
	case $set in
	8859-15)	for pair in $_BT_ICONV_8859_15; do rev[${pair#*:}]=${pair%%:*}; done ;;
	1252)		for pair in $_BT_ICONV_1252; do rev[${pair#*:}]=${pair%%:*}; done ;;
	esac
	case $set in
	UTF-16)		esc='\0377\0376' ;;
	UTF-32)		esc='\0377\0376\0000\0000' ;;
	esac
	for cp in ${cps[@]+"${cps[@]}"}; do
		case $set in
		UTF-8)
			if [ "$cp" -lt 128 ]; then
				_bt_iconv_put "$cp"
			elif [ "$cp" -lt 2048 ]; then
				_bt_iconv_put $(( 192 | cp >> 6 )) $(( 128 | cp & 63 ))
			elif [ "$cp" -lt 65536 ]; then
				_bt_iconv_put $(( 224 | cp >> 12 )) \
					$(( 128 | (cp >> 6) & 63 )) $(( 128 | cp & 63 ))
			else
				_bt_iconv_put $(( 240 | cp >> 18 )) \
					$(( 128 | (cp >> 12) & 63 )) \
					$(( 128 | (cp >> 6) & 63 )) $(( 128 | cp & 63 ))
			fi ;;
		ASCII)
			if [ "$cp" -lt 128 ]; then _bt_iconv_put "$cp"
			else _bt_iconv_cannot || return 1; fi ;;
		8859-1)
			if [ "$cp" -lt 256 ]; then _bt_iconv_put "$cp"
			else _bt_iconv_cannot || return 1; fi ;;
		8859-15|1252)
			b=${rev[$cp]-}
			if [ -n "$b" ]; then
				_bt_iconv_put "$b"
			elif [ "$cp" -lt 256 ] && [ -z "${rev2[$cp]-}" ]; then
				_bt_iconv_put "$cp"
			else
				_bt_iconv_cannot || return 1
			fi ;;
		UTF-16*)
			if [ "$cp" -ge 65536 ]; then
				hi=$(( 55296 + ((cp - 65536) >> 10) ))
				lo=$(( 56320 + ((cp - 65536) & 1023) ))
				_bt_iconv_put16 "$hi"
				_bt_iconv_put16 "$lo"
			else
				_bt_iconv_put16 "$cp"
			fi ;;
		UTF-32*)
			_bt_iconv_put32 "$cp" ;;
		esac
	done
	_bt_iconv_out
	return 0
}

# Add bytes to the pending output.  Relies on its caller's `esc`.
_bt_iconv_put() {
	local b
	for b in "$@"; do
		printf -v out '\\0%03o' "$b"
		esc=$esc$out
	done
	[ "${#esc}" -gt 8000 ] && _bt_iconv_out
	return 0
}

_bt_iconv_put16() {
	if [ "$big" = 1 ]; then _bt_iconv_put $(( $1 >> 8 )) $(( $1 & 255 ))
	else _bt_iconv_put $(( $1 & 255 )) $(( $1 >> 8 )); fi
	return 0
}

_bt_iconv_put32() {
	if [ "$big" = 1 ]; then
		_bt_iconv_put $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) \
			$(( ($1 >> 8) & 255 )) $(( $1 & 255 ))
	else
		_bt_iconv_put $(( $1 & 255 )) $(( ($1 >> 8) & 255 )) \
			$(( ($1 >> 16) & 255 )) $(( ($1 >> 24) & 255 ))
	fi
	return 0
}

_bt_iconv_out() {
	[ -n "$esc" ] && printf '%b' "$esc"
	esc=
	return 0
}

# A code point that will not fit the target set.  Relies on its caller.
_bt_iconv_cannot() {
	[ "$drop" = 1 ] && return 0
	_bt_iconv_out
	[ "$quiet" = 1 ] || _bt_err "iconv: cannot convert"
	status=1
	return 1
}

iconv () {
	local LC_ALL=C
	local arg opt from= to= drop=0 quiet=0 list=0 status=0 file fd
	local _bt_str _bt_reason big=0
	local -a _bt_b=() cps=()
	local -A rev2=()

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-f)	shift; [ "$#" = 0 ] && { _bt_err "iconv: option requires an argument -- f"; return 1; }
			from=$1; shift ;;
		-f*)	from=${1#-f}; shift ;;
		-t)	shift; [ "$#" = 0 ] && { _bt_err "iconv: option requires an argument -- t"; return 1; }
			to=$1; shift ;;
		-t*)	to=${1#-t}; shift ;;
		-l)	list=1; shift ;;
		-c)	drop=1; shift ;;
		-s)	quiet=1; shift ;;
		-cs|-sc)	drop=1 quiet=1; shift ;;
		-*)	[ "$1" = - ] && break
			_bt_err "iconv: illegal option -- ${1#-}"
			_bt_err "usage: iconv [-cs] [-f frommap] [-t tomap] [file...]"
			_bt_err "       iconv -l"
			return 1 ;;
		*)	break ;;
		esac
	done

	if [ "$list" = 1 ]; then
		printf '%s\n' UTF-8 ASCII ISO-8859-1 ISO-8859-15 CP1252 \
			UTF-16 UTF-16LE UTF-16BE UTF-32 UTF-32LE UTF-32BE
		return 0
	fi

	[ -n "$from" ] || from=UTF-8
	[ -n "$to" ] || to=UTF-8
	if ! _bt_iconv_norm "$from"; then
		_bt_err "iconv: conversion from $from unsupported"
		return 1
	fi
	from=$_bt_str
	if ! _bt_iconv_norm "$to"; then
		_bt_err "iconv: conversion to $to unsupported"
		return 1
	fi
	to=$_bt_str

	# which of the two Latin sets a byte belongs to is decided by the table,
	# so the code points a set spells differently must not fall through
	case $to in
	8859-15)	for arg in $_BT_ICONV_8859_15; do rev2[${arg%%:*}]=1; done ;;
	1252)		for arg in $_BT_ICONV_1252; do rev2[${arg%%:*}]=1; done ;;
	esac
	case $to in
	UTF-16BE|UTF-32BE)	big=1 ;;
	*)			big=0 ;;
	esac

	[ "$#" = 0 ] && set -- -
	for file in "$@"; do
		if [ "$file" = - ]; then
			_bt_fd_bytes 0
		elif { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_fd_bytes "$fd"
			exec {fd}<&-
		else
			_bt_why "$file"
			_bt_err "iconv: $file: $_bt_reason"
			status=1
			continue
		fi
		_bt_iconv_decode "$from" || { _bt_iconv_encode "$to"; return 1; }
		_bt_iconv_encode "$to" || return 1
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# ar -- POSIX.1-2017:
#	ar -d [-v] archive file...
#	ar -m [-abiv] [posname] archive file...
#	ar -p [-v] archive [file...]
#	ar -q [-cv] archive file...
#	ar -r [-abciuv] [posname] archive file...
#	ar -t [-v] archive [file...]
#	ar -x [-v] archive [file...]
#
# The format is the common one: the magic "!<arch>\n", then a 60-byte header
# per member and its bytes padded to an even length.  Names too long for the
# header live in a member called // and are referred to by their offset in it.
#
# What goes in the date, owner and mode fields is 0, 0, 0 and 644, which is
# what ar itself writes in the deterministic mode it now defaults to -- and
# just as well, because there is no stat() here to write anything else.
# ---------------------------------------------------------------------------

# Pending output, flushed a few thousand escapes at a time.
_bt_ar_put() {
	local b s
	for b in "$@"; do
		printf -v s '\\0%03o' "$b"
		esc=$esc$s
	done
	[ "${#esc}" -gt 8000 ] && { printf '%b' "$esc" >&"$ofd"; esc=; }
	return 0
}

_bt_ar_flush() {
	[ -n "$esc" ] && printf '%b' "$esc" >&"$ofd"
	esc=
	return 0
}

# Read the archive $1 into _bt_b and fill mname/moff/msize.  An archive that is
# not there leaves the arrays empty and returns 1.
_bt_ar_read() {
	local i n name size off longoff longsize=0 j c
	mname=() moff=() msize=()
	_bt_file_bytes "$1" || return 1
	n=${#_bt_b[@]}
	if [ "$n" -lt 8 ]; then return 0; fi
	_bt_b_str 0 7
	if [ "$_bt_str" != '!<arch>' ]; then
		_bt_err "ar: $1: file format not recognized"
		return 2
	fi
	i=8
	longoff=-1
	while [ $(( i + 60 )) -le "$n" ]; do
		_bt_b_str "$i" 16
		name=$_bt_str
		name=${name%"${name##*[! ]}"}
		_bt_b_str $(( i + 48 )) 10
		size=${_bt_str%"${_bt_str##*[! ]}"}
		case $size in
		''|*[!0-9]*)	break ;;
		esac
		off=$(( i + 60 ))
		if [ "$name" = '//' ]; then
			longoff=$off longsize=$size
		elif [ "$name" != '/' ] && [ "$name" != '/SYM64/' ]; then
			case $name in
			/*)	j=${name#/}
				name=
				if [ "$longoff" -ge 0 ] && [ -n "$j" ]; then
					for (( c = longoff + j; c < longoff + longsize; c++ )); do
						[ "${_bt_b[c]}" = 47 ] && break
						[ "${_bt_b[c]}" = 10 ] && break
						_bt_chr "${_bt_b[c]}"
						name=$name$_bt_c
					done
				fi ;;
			*/)	name=${name%/} ;;
			esac
			mname+=("$name")
			moff+=("$off")
			msize+=("$size")
		fi
		i=$(( off + size + (size % 2) ))
	done
	return 0
}

# Write the working member list to the archive named $1.
_bt_ar_write() {
	local out=$1 i j n name size esc= ofd longs= tmp
	local -a fb=()

	for (( i = 0; i < ${#wname[@]}; i++ )); do
		if [ $(( ${#wname[i]} + 1 )) -gt 16 ]; then
			longs=$longs${wname[i]}/$'\n'
		fi
	done

	if ! { exec {ofd}>"$out"; } 2>/dev/null; then
		_bt_err "ar: cannot write $out"
		return 1
	fi
	printf '!<arch>\n' >&"$ofd"
	if [ -n "$longs" ]; then
		# the padding that keeps the table even is counted in its size
		[ $(( ${#longs} % 2 )) = 1 ] && longs=$longs$'\n'
		size=${#longs}
		printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' '//' '' '' '' '' "$size" >&"$ofd"
		printf '%s' "$longs" >&"$ofd"
	fi

	tmp=0
	for (( i = 0; i < ${#wname[@]}; i++ )); do
		name=${wname[i]}
		if [ $(( ${#name} + 1 )) -gt 16 ]; then
			printf -v name '/%d' "$tmp"
			tmp=$(( tmp + ${#wname[i]} + 2 ))
		else
			name=$name/
		fi
		if [ -n "${wfile[i]}" ]; then
			fb=()
			_bt_ar_slurp "${wfile[i]}" || { exec {ofd}>&-; return 1; }
			size=${#fb[@]}
		else
			size=${wsize[i]}
		fi
		printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$name" 0 0 0 644 "$size" >&"$ofd"
		esc=
		if [ -n "${wfile[i]}" ]; then
			for (( j = 0; j < size; j++ )); do _bt_ar_put "${fb[j]}"; done
		else
			n=$(( woff[i] + size ))
			for (( j = woff[i]; j < n; j++ )); do _bt_ar_put "${_bt_b[j]}"; done
		fi
		[ $(( size % 2 )) = 1 ] && _bt_ar_put 10
		_bt_ar_flush
	done
	exec {ofd}>&-
	return 0
}

# Read file $1 into the `fb` array.
_bt_ar_slurp() {
	local fd i len rc
	local _bt_buf _bt_nul v
	fb=()
	if ! { exec {fd}<"$1"; } 2>/dev/null; then
		_bt_err "ar: $1: No such file or directory"
		return 1
	fi
	while :; do
		if _bt_read "$fd"; then rc=0; else rc=1; fi
		len=${#_bt_buf}
		for (( i = 0; i < len; i++ )); do
			printf -v v '%d' "'${_bt_buf:i:1}"
			fb+=("$v")
		done
		[ "$rc" = 0 ] && [ "$_bt_nul" = 1 ] && fb+=(0)
		[ "$rc" = 1 ] && break
	done
	exec {fd}<&-
	return 0
}

ar () {
	local LC_ALL=C
	local arg opt key= pos= posname= verbose=0 quiet=0 archive= i j k n
	local status=0 name found esc ofd
	local -a mname=() moff=() msize=() wname=() wfile=() wsize=() woff=()
	local -a _bt_b=() fb=() ops=()
	local _bt_str _bt_c _bt_reason

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-*)	arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				d|m|p|q|r|t|x)	key=$opt ;;
				a|b|i)		pos=$opt ;;
				c)		quiet=1 ;;
				v)		verbose=1 ;;
				s|u|C|T|D|U)	;;
				*)	_bt_err "ar: illegal option -- $opt"
					_bt_err "usage: ar -d|-m|-p|-q|-r|-t|-x [-abcisuv] [posname] archive [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ -z "$key" ] && [ "$#" -gt 0 ]; then
		# the key may come without its dash, as it always could
		case $1 in
		*[dmpqrtx]*)
			arg=$1
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				d|m|p|q|r|t|x)	key=$opt ;;
				a|b|i)		pos=$opt ;;
				c)		quiet=1 ;;
				v)		verbose=1 ;;
				s|u|C|T|D|U)	;;
				esac
			done ;;
		esac
	fi
	if [ -z "$key" ]; then
		_bt_err "usage: ar -d|-m|-p|-q|-r|-t|-x [-abcisuv] [posname] archive [file...]"
		return 1
	fi
	if [ -n "$pos" ]; then
		if [ "$#" = 0 ]; then
			_bt_err "ar: an option that positions a member needs a member to position it by"
			return 1
		fi
		posname=$1; shift
	fi
	if [ "$#" = 0 ]; then
		_bt_err "ar: no archive named"
		return 1
	fi
	archive=$1; shift
	ops=("$@")

	if [ -e "$archive" ]; then
		_bt_ar_read "$archive" || return 1
	elif [ "$key" = r ] || [ "$key" = q ]; then
		[ "$quiet" = 1 ] || _bt_err "ar: creating $archive"
	else
		_bt_err "ar: $archive: No such file or directory"
		return 1
	fi

	case $key in
	t)	for (( i = 0; i < ${#mname[@]}; i++ )); do
			if [ "${#ops[@]}" -gt 0 ]; then
				found=0
				for name in "${ops[@]}"; do
					[ "${name##*/}" = "${mname[i]}" ] && found=1
				done
				[ "$found" = 1 ] || continue
			fi
			if [ "$verbose" = 1 ]; then
				printf 'rw-r--r-- 0/0 %6d Jan  1 00:00 1970 %s\n' \
					"${msize[i]}" "${mname[i]}"
			else
				printf '%s\n' "${mname[i]}"
			fi
		done ;;
	p)	esc=
		ofd=1
		for (( i = 0; i < ${#mname[@]}; i++ )); do
			if [ "${#ops[@]}" -gt 0 ]; then
				found=0
				for name in "${ops[@]}"; do
					[ "${name##*/}" = "${mname[i]}" ] && found=1
				done
				[ "$found" = 1 ] || continue
			fi
			[ "$verbose" = 1 ] && printf '\n<%s>\n\n' "${mname[i]}"
			n=$(( moff[i] + msize[i] ))
			for (( j = moff[i]; j < n; j++ )); do _bt_ar_put "${_bt_b[j]}"; done
			_bt_ar_flush
		done ;;
	x)	for (( i = 0; i < ${#mname[@]}; i++ )); do
			if [ "${#ops[@]}" -gt 0 ]; then
				found=0
				for name in "${ops[@]}"; do
					[ "${name##*/}" = "${mname[i]}" ] && found=1
				done
				[ "$found" = 1 ] || continue
			fi
			esc=
			if ! { exec {ofd}>"${mname[i]}"; } 2>/dev/null; then
				_bt_err "ar: cannot write ${mname[i]}"
				status=1
				continue
			fi
			n=$(( moff[i] + msize[i] ))
			for (( j = moff[i]; j < n; j++ )); do _bt_ar_put "${_bt_b[j]}"; done
			_bt_ar_flush
			exec {ofd}>&-
			[ "$verbose" = 1 ] && printf 'x - %s\n' "${mname[i]}"
		done ;;
	d)	for (( i = 0; i < ${#mname[@]}; i++ )); do
			found=0
			for name in "${ops[@]}"; do
				[ "${name##*/}" = "${mname[i]}" ] && found=1
			done
			if [ "$found" = 1 ]; then
				[ "$verbose" = 1 ] && printf 'd - %s\n' "${mname[i]}"
				continue
			fi
			wname+=("${mname[i]}") wfile+=('') woff+=("${moff[i]}") wsize+=("${msize[i]}")
		done
		_bt_ar_write "$archive" || return 1 ;;
	q)	for (( i = 0; i < ${#mname[@]}; i++ )); do
			wname+=("${mname[i]}") wfile+=('') woff+=("${moff[i]}") wsize+=("${msize[i]}")
		done
		for name in "${ops[@]}"; do
			wname+=("${name##*/}") wfile+=("$name") woff+=(0) wsize+=(0)
			[ "$verbose" = 1 ] && printf 'a - %s\n' "$name"
		done
		_bt_ar_write "$archive" || return 1 ;;
	r)	for (( i = 0; i < ${#mname[@]}; i++ )); do
			wname+=("${mname[i]}") wfile+=('') woff+=("${moff[i]}") wsize+=("${msize[i]}")
		done
		for name in "${ops[@]}"; do
			found=-1
			for (( i = 0; i < ${#wname[@]}; i++ )); do
				[ "${wname[i]}" = "${name##*/}" ] && { found=$i; break; }
			done
			if [ "$found" -ge 0 ] && [ -z "$pos" ]; then
				wfile[found]=$name
				woff[found]=0
				wsize[found]=0
				[ "$verbose" = 1 ] && printf 'r - %s\n' "$name"
			elif [ "$found" -ge 0 ]; then
				# asked to place it somewhere, a member that is
				# already there moves rather than staying put
				wname=( ${wname[@]+"${wname[@]:0:found}"} ${wname[@]+"${wname[@]:found+1}"} )
				wfile=( ${wfile[@]+"${wfile[@]:0:found}"} ${wfile[@]+"${wfile[@]:found+1}"} )
				woff=( ${woff[@]+"${woff[@]:0:found}"} ${woff[@]+"${woff[@]:found+1}"} )
				wsize=( ${wsize[@]+"${wsize[@]:0:found}"} ${wsize[@]+"${wsize[@]:found+1}"} )
				_bt_ar_insert "${name##*/}" "$name"
				[ "$verbose" = 1 ] && printf 'r - %s\n' "$name"
			else
				_bt_ar_insert "${name##*/}" "$name"
				[ "$verbose" = 1 ] && printf 'a - %s\n' "$name"
			fi
		done
		_bt_ar_write "$archive" || return 1 ;;
	m)	for (( i = 0; i < ${#mname[@]}; i++ )); do
			found=0
			for name in "${ops[@]}"; do
				[ "${name##*/}" = "${mname[i]}" ] && found=1
			done
			[ "$found" = 1 ] && continue
			wname+=("${mname[i]}") wfile+=('') woff+=("${moff[i]}") wsize+=("${msize[i]}")
		done
		for name in "${ops[@]}"; do
			for (( i = 0; i < ${#mname[@]}; i++ )); do
				[ "${mname[i]}" = "${name##*/}" ] || continue
				_bt_ar_insert "${mname[i]}" '' "${moff[i]}" "${msize[i]}"
				[ "$verbose" = 1 ] && printf 'm - %s\n' "${mname[i]}"
			done
		done
		_bt_ar_write "$archive" || return 1 ;;
	esac
	return "$status"
}

# Put a member in the working list where -a, -b or -i says it goes, or at the
# end when nothing says otherwise.  Relies on its caller's locals.
_bt_ar_insert() {
	local nm=$1 file=$2 off=${3:-0} size=${4:-0} at=${#wname[@]} i
	if [ -n "$pos" ] && [ -n "$posname" ]; then
		for (( i = 0; i < ${#wname[@]}; i++ )); do
			if [ "${wname[i]}" = "${posname##*/}" ]; then
				if [ "$pos" = a ]; then at=$(( i + 1 )); else at=$i; fi
				break
			fi
		done
	fi
	wname=( ${wname[@]+"${wname[@]:0:at}"} "$nm" ${wname[@]+"${wname[@]:at}"} )
	wfile=( ${wfile[@]+"${wfile[@]:0:at}"} "$file" ${wfile[@]+"${wfile[@]:at}"} )
	woff=( ${woff[@]+"${woff[@]:0:at}"} "$off" ${woff[@]+"${woff[@]:at}"} )
	wsize=( ${wsize[@]+"${wsize[@]:0:at}"} "$size" ${wsize[@]+"${wsize[@]:at}"} )
	return 0
}

# ---------------------------------------------------------------------------
# locale -- POSIX.1-2017:
#	locale [-a|-m]
#	locale [-ck] name...
#
# What the environment asks for is answered exactly.  The keyword values are
# the ones the standard fixes for the POSIX locale; the data for any other
# locale lives in a compiled archive that nothing here can read, so those are
# the values that come out whatever LANG says.
# ---------------------------------------------------------------------------

# category:keyword:kind:value, kind s for a string and n for a number
_BT_LOCALE_KEYS='
LC_CTYPE:charmap:s:ANSI_X3.4-1968
LC_NUMERIC:decimal_point:s:.
LC_NUMERIC:thousands_sep:s:
LC_NUMERIC:grouping:n:-1
LC_MONETARY:int_curr_symbol:s:
LC_MONETARY:currency_symbol:s:
LC_MONETARY:mon_decimal_point:s:
LC_MONETARY:mon_thousands_sep:s:
LC_MONETARY:mon_grouping:n:-1
LC_MONETARY:positive_sign:s:
LC_MONETARY:negative_sign:s:
LC_MONETARY:int_frac_digits:n:-1
LC_MONETARY:frac_digits:n:-1
LC_MONETARY:p_cs_precedes:n:-1
LC_MONETARY:p_sep_by_space:n:-1
LC_MONETARY:n_cs_precedes:n:-1
LC_MONETARY:n_sep_by_space:n:-1
LC_MONETARY:p_sign_posn:n:-1
LC_MONETARY:n_sign_posn:n:-1
LC_TIME:abday:s:Sun;Mon;Tue;Wed;Thu;Fri;Sat
LC_TIME:day:s:Sunday;Monday;Tuesday;Wednesday;Thursday;Friday;Saturday
LC_TIME:abmon:s:Jan;Feb;Mar;Apr;May;Jun;Jul;Aug;Sep;Oct;Nov;Dec
LC_TIME:mon:s:January;February;March;April;May;June;July;August;September;October;November;December
LC_TIME:d_t_fmt:s:%a %b %e %H:%M:%S %Y
LC_TIME:d_fmt:s:%m/%d/%y
LC_TIME:t_fmt:s:%H:%M:%S
LC_TIME:am_pm:s:AM;PM
LC_TIME:t_fmt_ampm:s:%I:%M:%S %p
LC_TIME:era:s:
LC_TIME:era_d_fmt:s:
LC_TIME:era_d_t_fmt:s:
LC_TIME:era_t_fmt:s:
LC_TIME:alt_digits:s:
LC_MESSAGES:yesexpr:s:^[yY]
LC_MESSAGES:noexpr:s:^[nN]
LC_MESSAGES:yesstr:s:
LC_MESSAGES:nostr:s:'

_BT_LOCALE_CATS='LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY LC_MESSAGES
	LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION'

locale () {
	local LC_ALL_SAVE=${LC_ALL-}
	local arg opt all=0 maps=0 showcat=0 keyword=0 status=0
	local name cat kind val line def set IFS_SAVE

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
				a)	all=1 ;;
				m)	maps=1 ;;
				c)	showcat=1 ;;
				k)	keyword=1 ;;
				*)	_bt_err "locale: illegal option -- $opt"
					_bt_err "usage: locale [-a|-m]"
					_bt_err "       locale [-ck] name..."
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	if [ "$all" = 1 ]; then
		_bt_locale_list
		return 0
	fi
	if [ "$maps" = 1 ]; then
		_bt_locale_charmaps
		return 0
	fi

	if [ "$#" = 0 ]; then
		# The value of a category is what its own variable says, or what
		# LC_ALL or LANG says instead -- and the quotes mark which.
		printf 'LANG=%s\n' "${LANG-}"
		printf 'LANGUAGE=%s\n' "${LANGUAGE-}"
		def=${LC_ALL_SAVE:-${LANG:-POSIX}}
		for cat in $_BT_LOCALE_CATS; do
			eval "set=\${$cat-}"
			if [ -n "$set" ] && [ -z "$LC_ALL_SAVE" ]; then
				printf '%s=%s\n' "$cat" "$set"
			else
				printf '%s="%s"\n' "$cat" "$def"
			fi
		done
		printf 'LC_ALL=%s\n' "$LC_ALL_SAVE"
		return 0
	fi

	for name in "$@"; do
		case " $_BT_LOCALE_CATS " in
		*" $name "*)
			[ "$showcat" = 1 ] && printf '%s\n' "$name"
			IFS_SAVE=$IFS
			IFS=$'\n'
			for line in $_BT_LOCALE_KEYS; do
				IFS=$IFS_SAVE
				[ -n "$line" ] || continue
				[ "${line%%:*}" = "$name" ] || continue
				_bt_locale_show "$line"
				IFS=$'\n'
			done
			IFS=$IFS_SAVE
			continue ;;
		esac
		found=
		IFS_SAVE=$IFS
		IFS=$'\n'
		for line in $_BT_LOCALE_KEYS; do
			IFS=$IFS_SAVE
			[ -n "$line" ] || continue
			val=${line#*:}
			if [ "${val%%:*}" = "$name" ]; then
				found=$line
				break
			fi
			IFS=$'\n'
		done
		IFS=$IFS_SAVE
		if [ -z "$found" ]; then
			_bt_err "locale: unknown name \"$name\""
			status=1
			continue
		fi
		[ "$showcat" = 1 ] && printf '%s\n' "${found%%:*}"
		_bt_locale_show "$found"
	done
	return "$status"
}

# Print one keyword line of the table $1, the way -k asks for it or not.
_bt_locale_show() {
	local line=$1 cat key kind val
	cat=${line%%:*}
	line=${line#*:}
	key=${line%%:*}
	line=${line#*:}
	kind=${line%%:*}
	val=${line#*:}
	if [ "$keyword" = 1 ]; then
		if [ "$kind" = n ]; then printf '%s=%s\n' "$key" "$val"
		else printf '%s="%s"\n' "$key" "$val"; fi
	else
		printf '%s\n' "$val"
	fi
	return 0
}

# The locales this machine has, which are the compiled ones plus the two that
# are always there.
_bt_locale_list() {
	local d f
	local -a names=(C POSIX)
	for d in /usr/lib/locale /usr/share/locale; do
		[ -d "$d" ] || continue
		for f in "$d"/*; do
			[ -d "$f" ] || continue
			f=${f##*/}
			case $f in
			locale-archive|*.alias)	continue ;;
			esac
			names+=("$f")
		done
		break
	done
	printf '%s\n' "${names[@]}" | { local l; while IFS= read -r l; do printf '%s\n' "$l"; done; } |
		_bt_locale_sort
	return 0
}

# Sort what comes in, without leaving the shell.
_bt_locale_sort() {
	local line
	local -a lines=()
	local i j n tmp
	while IFS= read -r line; do lines+=("$line"); done
	n=${#lines[@]}
	for (( i = 1; i < n; i++ )); do
		tmp=${lines[i]}
		j=$(( i - 1 ))
		while [ "$j" -ge 0 ] && [ "${lines[j]}" \> "$tmp" ]; do
			lines[j+1]=${lines[j]}
			j=$(( j - 1 ))
		done
		lines[j+1]=$tmp
	done
	[ "$n" -gt 0 ] && printf '%s\n' "${lines[@]}"
	return 0
}

# The character maps this machine has a description of.
_bt_locale_charmaps() {
	local f
	local -a names=()
	[ -d /usr/share/i18n/charmaps ] || return 0
	for f in /usr/share/i18n/charmaps/*; do
		[ -f "$f" ] || continue
		f=${f##*/}
		f=${f%.gz}
		names+=("$f")
	done
	[ "${#names[@]}" -gt 0 ] && printf '%s\n' "${names[@]}" | _bt_locale_sort
	return 0
}

# ---------------------------------------------------------------------------
# nm -- POSIX.1-2017: nm [-APv] [-efox] [-g|-u] [-t format] file...
#
# An ELF file is a header, a table of section headers, and among the sections a
# symbol table and the strings its names live in.  All of that is fixed-width
# little- or big-endian integers at known offsets, which is exactly the sort of
# thing that can be picked out of an array of bytes.
# ---------------------------------------------------------------------------

# Read $2 bytes at offset $1 of _bt_b as an integer, honouring `elfbe`.
_bt_elf_num() {
	local off=$1 n=$2 i v=0
	if [ "$elfbe" = 1 ]; then
		for (( i = 0; i < n; i++ )); do v=$(( (v << 8) | _bt_b[off+i] )); done
	else
		for (( i = n - 1; i >= 0; i-- )); do v=$(( (v << 8) | _bt_b[off+i] )); done
	fi
	_bt_int=$v
	return 0
}

# The letter nm gives a symbol, in _bt_str.  Relies on its caller's locals.
_bt_nm_type() {
	local bind=$1 styp=$2 shndx=$3 c
	case $shndx in
	0)	if [ "$bind" = 2 ]; then
			if [ "$styp" = 1 ]; then _bt_str=v; else _bt_str=w; fi
		else
			_bt_str=U
		fi
		return 0 ;;
	65521)	c=A ;;
	65522)	_bt_str=C; return 0 ;;
	*)	if [ "$bind" = 2 ]; then
			if [ "$styp" = 1 ]; then _bt_str=V; else _bt_str=W; fi
			return 0
		fi
		if [ $(( shflags[shndx] & 4 )) != 0 ]; then c=T
		elif [ "${shtype[shndx]}" = 8 ]; then c=B
		elif [ $(( shflags[shndx] & 1 )) != 0 ]; then c=D
		else c=R
		fi ;;
	esac
	if [ "$bind" = 0 ]; then
		_bt_str=${c,}
	else
		_bt_str=$c
	fi
	return 0
}

# Sort the parallel symbol arrays by name, or by value when `bynum` says so.
_bt_nm_sort() {
	local n=${#snames[@]} width=1 i j k lo mid hi
	local -a idx=() tmp=()
	for (( i = 0; i < n; i++ )); do idx+=("$i"); done
	while [ "$width" -lt "$n" ]; do
		tmp=()
		lo=0
		while [ "$lo" -lt "$n" ]; do
			mid=$(( lo + width ))
			hi=$(( mid + width ))
			[ "$mid" -gt "$n" ] && mid=$n
			[ "$hi" -gt "$n" ] && hi=$n
			i=$lo j=$mid
			while [ "$i" -lt "$mid" ] || [ "$j" -lt "$hi" ]; do
				if [ "$i" -ge "$mid" ]; then
					tmp+=("${idx[j]}"); j=$(( j + 1 ))
				elif [ "$j" -ge "$hi" ]; then
					tmp+=("${idx[i]}"); i=$(( i + 1 ))
				elif _bt_nm_before "${idx[j]}" "${idx[i]}"; then
					tmp+=("${idx[j]}"); j=$(( j + 1 ))
				else
					tmp+=("${idx[i]}"); i=$(( i + 1 ))
				fi
			done
			lo=$hi
		done
		idx=("${tmp[@]}")
		width=$(( width * 2 ))
	done
	order=("${idx[@]}")
	return 0
}

# Does symbol $1 come before symbol $2?  Relies on its caller's locals.
_bt_nm_before() {
	if [ "$bynum" = 1 ]; then
		# the ones with no address at all come first, and anything that
		# ends up level is settled by name
		if [ "${sundef[$1]}" != "${sundef[$2]}" ]; then
			[ "${sundef[$1]}" = 1 ] && return 0
			return 1
		fi
		if [ "${sundef[$1]}" = 0 ] && [ "${svalue[$1]}" != "${svalue[$2]}" ]; then
			[ "${svalue[$1]}" -lt "${svalue[$2]}" ] && return 0
			return 1
		fi
	fi
	[ "${snames[$1]}" \< "${snames[$2]}" ] && return 0
	return 1
}

nm () {
	local LC_ALL=C
	local arg opt file fd status=0 base=x posix=0 prefix=0 bynum=0 nosort=0
	local onlyext=0 onlyundef=0 showall=0 first=1 many=0 dynamic=0
	local elfbe=0 elfclass i j n off shoff shnum shentsize shstrndx
	local symtab=-1 symsize symcount stroff name value size info bind styp shndx
	local _bt_int _bt_str _bt_c _bt_reason fmt val
	local -a _bt_b=() shtype=() shflags=() shoffset=() shsize=() shlink=() shentsz=()
	local -a shname=()
	local -a snames=() svalue=() ssize=() stype=() sundef=() order=()

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-t)	shift
			[ "$#" = 0 ] && { _bt_err "nm: option requires an argument -- t"; return 1; }
			base=$1; shift ;;
		-t*)	base=${1#-t}; shift ;;
		-f)	shift
			[ "$#" = 0 ] && { _bt_err "nm: option requires an argument -- f"; return 1; }
			[ "$1" = posix ] && posix=1
			shift ;;
		-*)	[ "$1" = - ] && break
			arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				A|o)	prefix=1 ;;
				D)	dynamic=1 ;;
				P)	posix=1 ;;
				v|n)	bynum=1 ;;
				p)	nosort=1 ;;
				g)	onlyext=1 ;;
				u)	onlyundef=1 ;;
				a)	showall=1 ;;
				e|f|x|C|B|S|s|r)	;;
				*)	_bt_err "nm: illegal option -- $opt"
					_bt_err "usage: nm [-APv] [-efox] [-g|-u] [-t format] file..."
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	if [ "$#" = 0 ]; then set -- a.out; fi
	[ "$#" -gt 1 ] && many=1

	case $base in
	d|o|x)	;;
	*)	_bt_err "nm: invalid radix -- $base"
		return 1 ;;
	esac

	for file in "$@"; do
		if ! _bt_file_bytes "$file"; then
			_bt_why "$file"
			_bt_err "nm: $file: $_bt_reason"
			status=1
			continue
		fi
		n=${#_bt_b[@]}
		if [ "$n" -lt 64 ] || [ "${_bt_b[0]}" != 127 ] || [ "${_bt_b[1]}" != 69 ] ||
		   [ "${_bt_b[2]}" != 76 ] || [ "${_bt_b[3]}" != 70 ]; then
			_bt_err "nm: $file: file format not recognized"
			status=1
			continue
		fi
		elfclass=${_bt_b[4]}
		if [ "${_bt_b[5]}" = 2 ]; then elfbe=1; else elfbe=0; fi
		if [ "$elfclass" = 2 ]; then
			_bt_elf_num 40 8; shoff=$_bt_int
			_bt_elf_num 58 2; shentsize=$_bt_int
			_bt_elf_num 60 2; shnum=$_bt_int
			_bt_elf_num 62 2; shstrndx=$_bt_int
		else
			_bt_elf_num 32 4; shoff=$_bt_int
			_bt_elf_num 46 2; shentsize=$_bt_int
			_bt_elf_num 48 2; shnum=$_bt_int
			_bt_elf_num 50 2; shstrndx=$_bt_int
		fi

		shtype=() shflags=() shoffset=() shsize=() shlink=() shentsz=() shname=()
		symtab=-1
		for (( i = 0; i < shnum; i++ )); do
			off=$(( shoff + i * shentsize ))
			_bt_elf_num "$off" 4; shname+=("$_bt_int")
			if [ "$elfclass" = 2 ]; then
				_bt_elf_num $(( off + 4 )) 4;  shtype+=("$_bt_int")
				_bt_elf_num $(( off + 8 )) 8;  shflags+=("$_bt_int")
				_bt_elf_num $(( off + 24 )) 8; shoffset+=("$_bt_int")
				_bt_elf_num $(( off + 32 )) 8; shsize+=("$_bt_int")
				_bt_elf_num $(( off + 40 )) 4; shlink+=("$_bt_int")
				_bt_elf_num $(( off + 56 )) 8; shentsz+=("$_bt_int")
			else
				_bt_elf_num $(( off + 4 )) 4;  shtype+=("$_bt_int")
				_bt_elf_num $(( off + 8 )) 4;  shflags+=("$_bt_int")
				_bt_elf_num $(( off + 16 )) 4; shoffset+=("$_bt_int")
				_bt_elf_num $(( off + 20 )) 4; shsize+=("$_bt_int")
				_bt_elf_num $(( off + 24 )) 4; shlink+=("$_bt_int")
				_bt_elf_num $(( off + 36 )) 4; shentsz+=("$_bt_int")
			fi
			if [ "$dynamic" = 1 ]; then
				[ "${shtype[i]}" = 11 ] && symtab=$i
			else
				[ "${shtype[i]}" = 2 ] && symtab=$i
			fi
		done
		if [ "$symtab" -lt 0 ]; then
			_bt_err "nm: $file: no symbols"
			status=1
			continue
		fi
		stroff=${shoffset[${shlink[symtab]}]}
		symsize=${shentsz[symtab]}
		[ "$symsize" -gt 0 ] || symsize=24
		symcount=$(( shsize[symtab] / symsize ))

		snames=() svalue=() ssize=() stype=() sundef=()
		for (( i = 1; i < symcount; i++ )); do
			off=$(( shoffset[symtab] + i * symsize ))
			if [ "$elfclass" = 2 ]; then
				_bt_elf_num "$off" 4; name=$_bt_int
				info=${_bt_b[off+4]}
				_bt_elf_num $(( off + 6 )) 2; shndx=$_bt_int
				_bt_elf_num $(( off + 8 )) 8; value=$_bt_int
				_bt_elf_num $(( off + 16 )) 8; size=$_bt_int
			else
				_bt_elf_num "$off" 4; name=$_bt_int
				_bt_elf_num $(( off + 4 )) 4; value=$_bt_int
				_bt_elf_num $(( off + 8 )) 4; size=$_bt_int
				info=${_bt_b[off+12]}
				_bt_elf_num $(( off + 14 )) 2; shndx=$_bt_int
			fi
			bind=$(( info >> 4 ))
			styp=$(( info & 15 ))
			_bt_b_str $(( stroff + name )) 4096
			name=$_bt_str
			if [ -z "$name" ] && [ "$styp" = 3 ] &&
			   [ "$shndx" -lt "$shnum" ]; then
				# a section's symbol carries no name of its own;
				# the section header has it
				_bt_b_str $(( shoffset[shstrndx] + shname[shndx] )) 4096
				name=$_bt_str
			fi
			[ -n "$name" ] || [ "$showall" = 1 ] || continue
			if [ "$showall" = 0 ]; then
				# section and file names are not symbols anyone asked for
				[ "$styp" = 3 ] && continue
				[ "$styp" = 4 ] && continue
			fi
			[ "$onlyext" = 1 ] && [ "$bind" = 0 ] && continue
			if [ "$styp" = 4 ]; then
				_bt_str=a
			else
				_bt_nm_type "$bind" "$styp" "$shndx"
			fi
			[ "$onlyundef" = 1 ] && [ "$shndx" != 0 ] && continue
			snames+=("$name")
			svalue+=("$value")
			ssize+=("$size")
			stype+=("$_bt_str")
			if [ "$shndx" = 0 ]; then sundef+=(1); else sundef+=(0); fi
		done

		if [ "$nosort" = 1 ]; then
			order=()
			for (( i = 0; i < ${#snames[@]}; i++ )); do order+=("$i"); done
		else
			_bt_nm_sort
		fi

		if [ "$many" = 1 ] && [ "$prefix" = 0 ] && [ "$posix" = 0 ]; then
			printf '\n%s:\n' "$file"
		fi
		fmt=$base
		for i in ${order[@]+"${order[@]}"}; do
			if [ "$posix" = 1 ]; then
				[ "$prefix" = 1 ] && printf '%s:' "$file"
				if [ "${sundef[i]}" = 1 ]; then
					printf '%s %s         \n' "${snames[i]}" "${stype[i]}"
				else
					printf -v val "%$fmt" "${svalue[i]}"
					printf '%s %s %s ' "${snames[i]}" "${stype[i]}" "$val"
					# a symbol of no size gets no size printed
					if [ "${ssize[i]}" = 0 ]; then
						printf '\n'
					else
						printf -v val "%$fmt" "${ssize[i]}"
						printf '%s\n' "$val"
					fi
				fi
				continue
			fi
			[ "$prefix" = 1 ] && printf '%s:' "$file"
			if [ "${sundef[i]}" = 1 ]; then
				printf '%16s %s %s\n' '' "${stype[i]}" "${snames[i]}"
			else
				if [ "$elfclass" = 2 ]; then
					printf -v val "%016$fmt" "${svalue[i]}"
				else
					printf -v val "%08$fmt" "${svalue[i]}"
				fi
				printf '%s %s %s\n' "$val" "${stype[i]}" "${snames[i]}"
			fi
		done
	done
	return "$status"
}

# ---------------------------------------------------------------------------
# The SCCS utilities -- POSIX.1-2017: admin, delta, get, prs, rmdel, sact,
# sccs, unget, val.
#
# An SCCS file is a text file with control lines that begin with SOH (^A): a
# checksum, a table of deltas newest first, the list of who may edit it, the
# flags, the descriptive text, and then the body -- every line any version ever
# had, wrapped in ^AI, ^AD and ^AE lines that say which delta put it there and
# which delta took it away.  A version is read out by walking the body and
# keeping the lines the wanted delta can see.
#
# Branches are not offered: the deltas here run 1.1, 1.2, 1.3 up the trunk.
# ---------------------------------------------------------------------------

_BT_SOH=$'\001'

# Add up every byte of file $1 except its first line, which is where the sum
# itself is written.  Leaves the answer in _bt_int.
_bt_sccs_sum() {
	local fd line sum=0 i first=1 c
	local -a bytes=()
	_bt_int=0
	{ exec {fd}<"$1"; } 2>/dev/null || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$first" = 1 ]; then first=0; line=; continue; fi
		for (( i = 0; i < ${#line}; i++ )); do
			printf -v c '%d' "'${line:i:1}"
			sum=$(( sum + c ))
		done
		sum=$(( sum + 10 ))
		line=
	done <&"$fd"
	exec {fd}<&-
	_bt_int=$(( sum % 65536 ))
	return 0
}

# Read the SCCS file $1 into the arrays the other commands work from.
_bt_sccs_read() {
	local fd line rest key i
	sc_sums= sc_flags=() sc_desc=() sc_users=() sc_body=()
	sc_type=() sc_sid=() sc_date=() sc_time=() sc_user=() sc_serial=()
	sc_pred=() sc_ins=() sc_del=() sc_unc=() sc_comment=() sc_mr=()
	{ exec {fd}<"$1"; } 2>/dev/null || return 1
	IFS= read -r line <&"$fd" || { exec {fd}<&-; return 1; }
	case $line in
	"$_BT_SOH"h*)	sc_sums=${line#"$_BT_SOH"h} ;;
	*)		exec {fd}<&-; return 1 ;;
	esac
	i=-1
	while IFS= read -r line <&"$fd"; do
		case $line in
		"$_BT_SOH"s*)	rest=${line#"$_BT_SOH"s }
				i=$(( i + 1 ))
				sc_ins+=("${rest%%/*}")
				rest=${rest#*/}
				sc_del+=("${rest%%/*}")
				sc_unc+=("${rest#*/}")
				sc_comment+=('')
				sc_mr+=('') ;;
		"$_BT_SOH"d*)	rest=${line#"$_BT_SOH"d }
				set -- $rest
				sc_type+=("$1") sc_sid+=("$2") sc_date+=("$3")
				sc_time+=("$4") sc_user+=("$5") sc_serial+=("$6")
				sc_pred+=("$7") ;;
		"$_BT_SOH"c*)	rest=${line#"$_BT_SOH"c}
				rest=${rest# }
				if [ -n "${sc_comment[i]}" ]; then
					sc_comment[i]=${sc_comment[i]}$'\n'$rest
				else
					sc_comment[i]=$rest
				fi ;;
		"$_BT_SOH"m*)	rest=${line#"$_BT_SOH"m}
				rest=${rest# }
				if [ -n "${sc_mr[i]}" ]; then
					sc_mr[i]=${sc_mr[i]}$'\n'$rest
				else
					sc_mr[i]=$rest
				fi ;;
		"$_BT_SOH"e)	;;
		"$_BT_SOH"u)	while IFS= read -r line <&"$fd"; do
					[ "$line" = "${_BT_SOH}U" ] && break
					sc_users+=("$line")
				done ;;
		"$_BT_SOH"f*)	rest=${line#"$_BT_SOH"f }
				key=${rest%% *}
				if [ "$key" = "$rest" ]; then
					sc_flags[$key]=
				else
					sc_flags[$key]=${rest#* }
				fi ;;
		"$_BT_SOH"t)	while IFS= read -r line <&"$fd"; do
					[ "$line" = "${_BT_SOH}T" ] && break
					sc_desc+=("$line")
				done ;;
		*)		sc_body+=("$line") ;;
		esac
	done
	exec {fd}<&-
	return 0
}

# Write the SCCS file $1 from the arrays, checksum and all.  The file is built
# in memory first so that its own sum can go in the line that holds it, which
# saves writing a second file that nothing here could remove afterwards.
_bt_sccs_write() {
	local out=$1 fd i n line sum=0 c j
	local -a text=()
	n=${#sc_serial[@]}
	for (( i = 0; i < n; i++ )); do
		printf -v line '%ss %05d/%05d/%05d' "$_BT_SOH" "${sc_ins[i]}" \
			"${sc_del[i]}" "${sc_unc[i]}"
		text+=("$line")
		printf -v line '%sd %s %s %s %s %s %s %s' "$_BT_SOH" "${sc_type[i]}" \
			"${sc_sid[i]}" "${sc_date[i]}" "${sc_time[i]}" \
			"${sc_user[i]}" "${sc_serial[i]}" "${sc_pred[i]}"
		text+=("$line")
		if [ -n "${sc_mr[i]}" ]; then
			while IFS= read -r line; do
				text+=("${_BT_SOH}m $line")
			done <<< "${sc_mr[i]}"
		fi
		if [ -n "${sc_comment[i]}" ]; then
			while IFS= read -r line; do
				text+=("${_BT_SOH}c $line")
			done <<< "${sc_comment[i]}"
		fi
		text+=("${_BT_SOH}e")
	done
	text+=("${_BT_SOH}u")
	for i in ${sc_users[@]+"${sc_users[@]}"}; do text+=("$i"); done
	text+=("${_BT_SOH}U")
	for i in ${!sc_flags[@]}; do
		if [ -n "${sc_flags[$i]}" ]; then
			text+=("${_BT_SOH}f $i ${sc_flags[$i]}")
		else
			text+=("${_BT_SOH}f $i")
		fi
	done
	text+=("${_BT_SOH}t")
	for i in ${sc_desc[@]+"${sc_desc[@]}"}; do text+=("$i"); done
	text+=("${_BT_SOH}T")
	for (( i = 0; i < ${#sc_body[@]}; i++ )); do text+=("${sc_body[i]}"); done

	for (( i = 0; i < ${#text[@]}; i++ )); do
		line=${text[i]}
		for (( j = 0; j < ${#line}; j++ )); do
			printf -v c '%d' "'${line:j:1}"
			sum=$(( sum + c ))
		done
		sum=$(( sum + 10 ))
	done
	sum=$(( sum % 65536 ))

	if ! { exec {fd}>"$out"; } 2>/dev/null; then
		_bt_err "$_bt_sccs_who: cannot write $out"
		return 1
	fi
	printf '%sh%05d\n' "$_BT_SOH" "$sum" >&"$fd"
	for (( i = 0; i < ${#text[@]}; i++ )); do
		printf '%s\n' "${text[i]}" >&"$fd"
	done
	exec {fd}>&-
	return 0
}

# Nothing in a shell can remove a file, so what stands in for it here is
# leaving the file empty: the p-file with no edits in it means no edits are
# pending, and the g-file with nothing in it is the file delta took away.
_bt_sccs_unlink() {
	: > "$1" 2>/dev/null
	return 0
}

# The text of the version with serial $1, into the `sc_text` array.
_bt_sccs_apply() {
	local want=$1 i n line cmd ser keep j
	local -a stack=()
	sc_text=()
	n=${#sc_body[@]}
	for (( i = 0; i < n; i++ )); do
		line=${sc_body[i]}
		case $line in
		"$_BT_SOH"[IDE]*)
			cmd=${line:1:1}
			ser=${line#* }
			if [ "$cmd" = E ]; then
				unset "stack[${#stack[@]}-1]"
			else
				stack+=("$cmd$ser")
			fi
			continue ;;
		esac
		keep=1
		for (( j = 0; j < ${#stack[@]}; j++ )); do
			cmd=${stack[j]:0:1}
			ser=${stack[j]:1}
			if [ "$cmd" = D ] && [ "$ser" -le "$want" ]; then keep=0; break; fi
		done
		if [ "$keep" = 1 ]; then
			for (( j = ${#stack[@]} - 1; j >= 0; j-- )); do
				[ "${stack[j]:0:1}" = I ] || continue
				[ "${stack[j]:1}" -gt "$want" ] && keep=0
				break
			done
		fi
		[ "$keep" = 1 ] && sc_text+=("$line")
	done
	return 0
}

# The index in the delta table of SID $1, or of the newest delta when $1 is
# empty.  Leaves it in _bt_int, or -1.
_bt_sccs_find() {
	local want=$1 i
	_bt_int=-1
	if [ -z "$want" ]; then
		[ "${#sc_sid[@]}" -gt 0 ] && _bt_int=0
		return 0
	fi
	for (( i = 0; i < ${#sc_sid[@]}; i++ )); do
		if [ "${sc_sid[i]}" = "$want" ]; then _bt_int=$i; return 0; fi
	done
	return 0
}

# The SID that follows $1 up the trunk.
_bt_sccs_next() {
	local sid=$1
	_bt_str=$(( ${sid%%.*} )).$(( ${sid#*.} + 1 ))
	return 0
}

# Today, the way an SCCS file writes it.
_bt_sccs_now() {
	printf -v sc_today '%(%y/%m/%d)T' -1
	printf -v sc_clock '%(%H:%M:%S)T' -1
	return 0
}

# Who is running this.
_bt_sccs_whoami() {
	local _bt_name _bt_uid _bt_gid
	local _bt_ruid _bt_euid _bt_rgid _bt_egid
	local -a _bt_supp=()
	_bt_self_ids
	if _bt_passwd "$_bt_euid" uid; then sc_me=$_bt_name; else sc_me=$_bt_euid; fi
	return 0
}

# The same walk as _bt_sccs_apply, but recording for every body line whether
# the wanted version has it, in `sc_in`.
_bt_sccs_mark() {
	local want=$1 i n line cmd ser keep j
	local -a stack=()
	sc_text=() sc_in=()
	n=${#sc_body[@]}
	for (( i = 0; i < n; i++ )); do
		line=${sc_body[i]}
		case $line in
		"$_BT_SOH"[IDE]*)
			cmd=${line:1:1}
			ser=${line#* }
			if [ "$cmd" = E ]; then
				unset "stack[${#stack[@]}-1]"
			else
				stack+=("$cmd$ser")
			fi
			sc_in+=(2)
			continue ;;
		esac
		keep=1
		for (( j = 0; j < ${#stack[@]}; j++ )); do
			cmd=${stack[j]:0:1}
			ser=${stack[j]:1}
			if [ "$cmd" = D ] && [ "$ser" -le "$want" ]; then keep=0; break; fi
		done
		if [ "$keep" = 1 ]; then
			for (( j = ${#stack[@]} - 1; j >= 0; j-- )); do
				[ "${stack[j]:0:1}" = I ] || continue
				[ "${stack[j]:1}" -gt "$want" ] && keep=0
				break
			done
		fi
		sc_in+=("$keep")
		[ "$keep" = 1 ] && sc_text+=("$line")
	done
	return 0
}

# The g-file and p-file names that go with the SCCS file $1.
_bt_sccs_names() {
	local f=$1 dir base
	dir=${f%/*}
	[ "$dir" = "$f" ] && dir=.
	base=${f##*/}
	case $base in
	s.*)	;;
	*)	return 1 ;;
	esac
	sc_gfile=${base#s.}
	sc_pfile=$dir/p.${base#s.}
	sc_sfile=$f
	[ "$dir" = . ] || sc_gfile=$dir/${base#s.}
	return 0
}

admin () {
	local LC_ALL=C
	local _bt_sccs_who=admin
	local arg opt init= empty=0 sfile= comment= tfile= settext=0 i line fd
	local status=0 rel= sc_today sc_clock sc_me
	local -a sc_type=() sc_sid=() sc_date=() sc_time=() sc_user=() sc_serial=()
	local -a sc_pred=() sc_ins=() sc_del=() sc_unc=() sc_comment=() sc_mr=()
	local -a sc_users=() sc_desc=() sc_body=() sc_text=() sc_in=()
	local -A sc_flags=()
	local sc_sums sc_gfile sc_pfile sc_sfile _bt_int _bt_str
	local -a adds=() dels=() fset=() fdel=()

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-i*)	init=${1#-i}; shift; [ -n "$init" ] || init=- ;;
		-n)	empty=1; shift ;;
		-r*)	rel=${1#-r}; shift ;;
		-y*)	comment=${1#-y}; shift ;;
		-t*)	tfile=${1#-t}; settext=1; shift ;;
		-a*)	adds+=("${1#-a}"); shift ;;
		-e*)	dels+=("${1#-e}"); shift ;;
		-f*)	fset+=("${1#-f}"); shift ;;
		-d*)	fdel+=("${1#-d}"); shift ;;
		-h|-z)	shift ;;
		-*)	_bt_err "admin: illegal option -- ${1#-}"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ "$#" != 1 ]; then
		_bt_err "usage: admin -i[file] [-n] [-r SID] [-y comment] [-fflag] s.file"
		_bt_err "       admin [-a user] [-e user] [-fflag] [-dflag] [-t[file]] s.file"
		return 1
	fi
	sfile=$1
	if ! _bt_sccs_names "$sfile"; then
		_bt_err "admin: $sfile: not an SCCS file name"
		return 1
	fi

	if [ -n "$init" ] || [ "$empty" = 1 ]; then
		if [ -s "$sfile" ]; then
			_bt_err "admin: $sfile is already there"
			return 1
		fi
		_bt_sccs_now
		_bt_sccs_whoami
		sc_body=()
		if [ "$empty" = 0 ]; then
			if [ "$init" = - ]; then
				line=
				while IFS= read -r line; do sc_body+=("$line"); line=; done
				[ -n "$line" ] && sc_body+=("$line")
			elif { exec {fd}<"$init"; } 2>/dev/null; then
				line=
				while IFS= read -r line <&"$fd"; do sc_body+=("$line"); line=; done
				[ -n "$line" ] && sc_body+=("$line")
				exec {fd}<&-
			else
				_bt_err "admin: cannot open $init"
				return 1
			fi
		fi
		i=${#sc_body[@]}
		sc_body=( "${_BT_SOH}I 1" ${sc_body[@]+"${sc_body[@]}"} "${_BT_SOH}E 1" )
		sc_type=(D) sc_sid=("${rel:-1.1}") sc_date=("$sc_today") sc_time=("$sc_clock")
		sc_user=("$sc_me") sc_serial=(1) sc_pred=(0)
		sc_ins=("$i") sc_del=(0) sc_unc=(0)
		sc_comment=("${comment:-date and time created $sc_today $sc_clock by $sc_me}")
		sc_mr=('')
		sc_users=() sc_desc=()
	else
		if ! _bt_sccs_read "$sfile"; then
			_bt_err "admin: $sfile: not an SCCS file"
			return 1
		fi
	fi

	for i in ${adds[@]+"${adds[@]}"}; do sc_users+=("$i"); done
	for i in ${dels[@]+"${dels[@]}"}; do
		local -a keep=()
		local u
		for u in ${sc_users[@]+"${sc_users[@]}"}; do
			[ "$u" = "$i" ] || keep+=("$u")
		done
		sc_users=( ${keep[@]+"${keep[@]}"} )
	done
	for i in ${fset[@]+"${fset[@]}"}; do
		sc_flags[${i:0:1}]=${i:1}
	done
	for i in ${fdel[@]+"${fdel[@]}"}; do
		unset "sc_flags[${i:0:1}]"
	done
	if [ "$settext" = 1 ]; then
		sc_desc=()
		if [ -n "$tfile" ] && { exec {fd}<"$tfile"; } 2>/dev/null; then
			line=
			while IFS= read -r line <&"$fd"; do sc_desc+=("$line"); line=; done
			[ -n "$line" ] && sc_desc+=("$line")
			exec {fd}<&-
		fi
	fi

	_bt_sccs_write "$sfile" || return 1
	return "$status"
}

get () {
	local LC_ALL=C
	local _bt_sccs_who=get
	local arg opt sid= edit=0 topipe=0 silent=0 nog=0 keep=0 i n fd line
	local status=0 sc_today sc_clock sc_me newsid
	local -a sc_type=() sc_sid=() sc_date=() sc_time=() sc_user=() sc_serial=()
	local -a sc_pred=() sc_ins=() sc_del=() sc_unc=() sc_comment=() sc_mr=()
	local -a sc_users=() sc_desc=() sc_body=() sc_text=() sc_in=()
	local -A sc_flags=()
	local sc_sums sc_gfile sc_pfile sc_sfile _bt_int _bt_str

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-r*)	sid=${1#-r}; shift ;;
		-e)	edit=1; shift ;;
		-p)	topipe=1; shift ;;
		-s)	silent=1; shift ;;
		-g)	nog=1; shift ;;
		-k)	keep=1; shift ;;
		-m|-n|-b|-t)	shift ;;
		-c*|-w*|-x*|-i*|-a*|-l*)	shift ;;
		-*)	_bt_err "get: illegal option -- ${1#-}"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ "$#" -lt 1 ]; then
		_bt_err "usage: get [-e] [-k] [-p] [-s] [-g] [-r SID] s.file..."
		return 1
	fi

	for arg in "$@"; do
		if ! _bt_sccs_names "$arg" || ! _bt_sccs_read "$arg"; then
			_bt_err "get: $arg: not an SCCS file"
			status=1
			continue
		fi
		_bt_sccs_find "$sid"
		i=$_bt_int
		if [ "$i" -lt 0 ]; then
			_bt_err "get: $arg: no such delta $sid"
			status=1
			continue
		fi
		_bt_sccs_apply "${sc_serial[i]}"
		[ "$silent" = 1 ] || printf '%s\n' "${sc_sid[i]}"
		if [ "$edit" = 1 ]; then
			_bt_sccs_next "${sc_sid[i]}"
			newsid=$_bt_str
			[ "$silent" = 1 ] || printf 'new delta %s\n' "$newsid"
			_bt_sccs_now
			_bt_sccs_whoami
			printf '%s %s %s %s %s\n' "${sc_sid[i]}" "$newsid" "$sc_me" \
				"$sc_today" "$sc_clock" >> "$sc_pfile"
		fi
		n=${#sc_text[@]}
		if [ "$topipe" = 1 ]; then
			[ "$n" -gt 0 ] && printf '%s\n' "${sc_text[@]}"
		elif [ "$nog" = 0 ]; then
			if ! { exec {fd}>"$sc_gfile"; } 2>/dev/null; then
				_bt_err "get: cannot write $sc_gfile"
				status=1
				continue
			fi
			for (( n = 0; n < ${#sc_text[@]}; n++ )); do
				printf '%s\n' "${sc_text[n]}" >&"$fd"
			done
			exec {fd}>&-
			n=${#sc_text[@]}
		fi
		[ "$silent" = 1 ] || printf '%d lines\n' "$n"
	done
	return "$status"
}

sact () {
	local LC_ALL=C
	local arg line status=0
	local sc_gfile sc_pfile sc_sfile
	if [ "$#" -lt 1 ]; then
		_bt_err "usage: sact s.file..."
		return 1
	fi
	for arg in "$@"; do
		if ! _bt_sccs_names "$arg"; then
			_bt_err "sact: $arg: not an SCCS file name"
			status=1
			continue
		fi
		if [ ! -s "$sc_pfile" ]; then
			_bt_err "sact: $arg: no edits pending"
			status=1
			continue
		fi
		[ "$#" -gt 1 ] && printf '\n%s:\n' "$arg"
		while IFS= read -r line; do
			printf '%s\n' "$line"
		done < "$sc_pfile"
	done
	return "$status"
}

unget () {
	local LC_ALL=C
	local arg sid= keep=0 silent=0 status=0 line found=0
	local sc_gfile sc_pfile sc_sfile
	local -a lines=()
	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-r*)	sid=${1#-r}; shift ;;
		-n)	keep=1; shift ;;
		-s)	silent=1; shift ;;
		-*)	_bt_err "unget: illegal option -- ${1#-}"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ "$#" -lt 1 ]; then
		_bt_err "usage: unget [-ns] [-r SID] s.file..."
		return 1
	fi
	for arg in "$@"; do
		if ! _bt_sccs_names "$arg"; then
			_bt_err "unget: $arg: not an SCCS file name"
			status=1
			continue
		fi
		if [ ! -s "$sc_pfile" ]; then
			_bt_err "unget: $arg: no edits pending"
			status=1
			continue
		fi
		lines=()
		found=0
		while IFS= read -r line; do
			set -- $line
			if [ "$found" = 0 ] && { [ -z "$sid" ] || [ "$2" = "$sid" ]; }; then
				found=1
				[ "$silent" = 1 ] || printf '%s\n' "$2"
				continue
			fi
			lines+=("$line")
		done < "$sc_pfile"
		if [ "$found" = 0 ]; then
			_bt_err "unget: $arg: no such delta pending"
			status=1
			continue
		fi
		if [ "${#lines[@]}" = 0 ]; then
			_bt_sccs_unlink "$sc_pfile"
		else
			printf '%s\n' "${lines[@]}" > "$sc_pfile"
		fi
		[ "$keep" = 1 ] || _bt_sccs_unlink "$sc_gfile"
	done
	return "$status"
}

delta () {
	local LC_ALL=C
	local _bt_sccs_who=delta
	local arg sid= comment= mrs= silent=0 keep=0 status=0
	local i j k n line fd oldsid newsid serial pi
	local sc_today sc_clock sc_me
	local -a sc_type=() sc_sid=() sc_date=() sc_time=() sc_user=() sc_serial=()
	local -a sc_pred=() sc_ins=() sc_del=() sc_unc=() sc_comment=() sc_mr=()
	local -a sc_users=() sc_desc=() sc_body=() sc_text=() sc_in=()
	local -A sc_flags=()
	local sc_sums sc_gfile sc_pfile sc_sfile _bt_int _bt_str
	local -a plines=() newlines=() opos=() odel=() oins=() newbody=()
	local script inserted=0 deleted=0 unchanged=0

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-r*)	sid=${1#-r}; shift ;;
		-y*)	comment=${1#-y}; shift ;;
		-m*)	mrs=${1#-m}; shift ;;
		-s)	silent=1; shift ;;
		-n)	keep=1; shift ;;
		-p|-g*)	shift ;;
		-*)	_bt_err "delta: illegal option -- ${1#-}"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ "$#" -lt 1 ]; then
		_bt_err "usage: delta [-nps] [-r SID] [-y comment] s.file..."
		return 1
	fi

	for arg in "$@"; do
		if ! _bt_sccs_names "$arg" || ! _bt_sccs_read "$arg"; then
			_bt_err "delta: $arg: not an SCCS file"
			status=1
			continue
		fi
		if [ ! -s "$sc_pfile" ]; then
			_bt_err "delta: $arg: no edits pending"
			status=1
			continue
		fi
		plines=()
		oldsid= newsid=
		while IFS= read -r line; do
			set -- $line
			if [ -z "$newsid" ] && { [ -z "$sid" ] || [ "$2" = "$sid" ]; }; then
				oldsid=$1 newsid=$2
				continue
			fi
			plines+=("$line")
		done < "$sc_pfile"
		if [ -z "$newsid" ]; then
			_bt_err "delta: $arg: no such delta pending"
			status=1
			continue
		fi

		_bt_sccs_find "$oldsid"
		i=$_bt_int
		if [ "$i" -lt 0 ]; then
			_bt_err "delta: $arg: no such delta $oldsid"
			status=1
			continue
		fi
		_bt_sccs_mark "${sc_serial[i]}"

		# the old text on one side, the file as it stands on the other;
		# the old text goes through a pipe, since a file left behind here
		# is a file nothing could remove afterwards
		if [ ! -r "$sc_gfile" ]; then
			_bt_err "delta: $arg: cannot read $sc_gfile"
			status=1
			continue
		fi
		# diff reports a difference by its exit status, which is the whole
		# point of running it, so that status is not an error here
		script=$( diff -e <(
			[ "${#sc_text[@]}" -gt 0 ] && printf '%s\n' "${sc_text[@]}"
			:
		) "$sc_gfile" ) || :

		# the ed script runs backwards; the body has to be built forwards
		opos=() odel=() oins=()
		_bt_sccs_ops "$script"

		serial=1
		for (( j = 0; j < ${#sc_serial[@]}; j++ )); do
			[ "${sc_serial[j]}" -ge "$serial" ] && serial=$(( sc_serial[j] + 1 ))
		done
		_bt_sccs_build "$serial"

		unchanged=$(( ${#sc_text[@]} - deleted ))
		_bt_sccs_now
		_bt_sccs_whoami
		sc_body=( ${newbody[@]+"${newbody[@]}"} )
		sc_type=(D ${sc_type[@]+"${sc_type[@]}"})
		sc_sid=("$newsid" ${sc_sid[@]+"${sc_sid[@]}"})
		sc_date=("$sc_today" ${sc_date[@]+"${sc_date[@]}"})
		sc_time=("$sc_clock" ${sc_time[@]+"${sc_time[@]}"})
		sc_user=("$sc_me" ${sc_user[@]+"${sc_user[@]}"})
		sc_serial=("$serial" ${sc_serial[@]+"${sc_serial[@]}"})
		sc_pred=("${sc_serial[1]}" ${sc_pred[@]+"${sc_pred[@]}"})
		sc_ins=("$inserted" ${sc_ins[@]+"${sc_ins[@]}"})
		sc_del=("$deleted" ${sc_del[@]+"${sc_del[@]}"})
		sc_unc=("$unchanged" ${sc_unc[@]+"${sc_unc[@]}"})
		sc_comment=("${comment:-delta $newsid}" ${sc_comment[@]+"${sc_comment[@]}"})
		sc_mr=("$mrs" ${sc_mr[@]+"${sc_mr[@]}"})

		_bt_sccs_write "$arg" || { status=1; continue; }
		if [ "${#plines[@]}" = 0 ]; then
			_bt_sccs_unlink "$sc_pfile"
		else
			printf '%s\n' "${plines[@]}" > "$sc_pfile"
		fi
		[ "$keep" = 1 ] || _bt_sccs_unlink "$sc_gfile"
		if [ "$silent" = 0 ]; then
			printf '%s\n' "$newsid"
			printf '%d inserted\n%d deleted\n%d unchanged\n' \
				"$inserted" "$deleted" "$unchanged"
		fi
	done
	return "$status"
}

# Turn the ed script $1 into the parallel arrays opos, odel and oins, in the
# order the lines come in rather than the order ed would apply them.  The
# inserted text of each change is one string, its lines joined by newlines.
_bt_sccs_ops() {
	local line cmd a b text collecting=0
	local -a p=() d=() ins=()
	while IFS= read -r line; do
		if [ "$collecting" = 1 ]; then
			if [ "$line" = '.' ]; then collecting=0; continue; fi
			if [ -n "${ins[${#ins[@]}-1]}" ]; then
				ins[${#ins[@]}-1]=${ins[${#ins[@]}-1]}$'\n'$line
			else
				ins[${#ins[@]}-1]=$line
			fi
			continue
		fi
		case $line in
		*[acd])	cmd=${line: -1}
			text=${line%?}
			a=${text%%,*}
			b=${text#*,}
			[ "$b" = "$text" ] && b=$a ;;
		*)	continue ;;
		esac
		case $cmd in
		a)	p+=($(( a + 1 ))); d+=(0); ins+=(''); collecting=1 ;;
		c)	p+=("$a"); d+=($(( b - a + 1 ))); ins+=(''); collecting=1 ;;
		d)	p+=("$a"); d+=($(( b - a + 1 ))); ins+=('') ;;
		esac
	done <<< "$1"
	# ed scripts run from the end of the file backwards
	local i n=${#p[@]}
	opos=() odel=() oins=()
	for (( i = n - 1; i >= 0; i-- )); do
		opos+=("${p[i]}")
		odel+=("${d[i]}")
		oins+=("${ins[i]}")
	done
	return 0
}

# Build the new body for a delta with serial $1.  Relies on its caller.
_bt_sccs_build() {
	local ser=$1 i k vline=0 opi=0 dopen=0 delend=0 pend= line n
	newbody=()
	inserted=0 deleted=0
	n=${#sc_body[@]}
	for (( i = 0; i < n; i++ )); do
		line=${sc_body[i]}
		if [ "${sc_in[i]}" != 1 ]; then
			if [ "$dopen" = 1 ]; then
				newbody+=("${_BT_SOH}E $ser")
				dopen=2
			fi
			newbody+=("$line")
			if [ "$dopen" = 2 ]; then
				newbody+=("${_BT_SOH}D $ser")
				dopen=1
			fi
			continue
		fi
		vline=$(( vline + 1 ))
		while [ "$dopen" = 0 ] && [ "$opi" -lt "${#opos[@]}" ] &&
		      [ "${opos[opi]}" = "$vline" ]; do
			if [ "${odel[opi]}" -gt 0 ]; then
				newbody+=("${_BT_SOH}D $ser")
				dopen=1
				delend=$(( vline + odel[opi] - 1 ))
				deleted=$(( deleted + odel[opi] ))
				pend=${oins[opi]}
				opi=$(( opi + 1 ))
				break
			fi
			_bt_sccs_emitins "$ser" "${oins[opi]}"
			opi=$(( opi + 1 ))
		done
		newbody+=("$line")
		if [ "$dopen" = 1 ] && [ "$vline" = "$delend" ]; then
			newbody+=("${_BT_SOH}E $ser")
			dopen=0
			if [ -n "$pend" ]; then
				_bt_sccs_emitins "$ser" "$pend"
				pend=
			fi
		fi
	done
	if [ "$dopen" != 0 ]; then
		newbody+=("${_BT_SOH}E $ser")
		[ -n "$pend" ] && _bt_sccs_emitins "$ser" "$pend"
	fi
	while [ "$opi" -lt "${#opos[@]}" ]; do
		if [ "${odel[opi]}" -gt 0 ]; then
			deleted=$(( deleted + odel[opi] ))
		fi
		_bt_sccs_emitins "$ser" "${oins[opi]}"
		opi=$(( opi + 1 ))
	done
	return 0
}

# Put an insert block of the lines in $2 into the body being built.
_bt_sccs_emitins() {
	local ser=$1 text=$2 line
	[ -n "$text" ] || return 0
	newbody+=("${_BT_SOH}I $ser")
	while IFS= read -r line; do
		newbody+=("$line")
		inserted=$(( inserted + 1 ))
	done <<< "$text"
	newbody+=("${_BT_SOH}E $ser")
	return 0
}

prs () {
	local LC_ALL=C
	local arg sid= dataspec= earlier=0 later=0 status=0 i n line first=1
	local -a sc_type=() sc_sid=() sc_date=() sc_time=() sc_user=() sc_serial=()
	local -a sc_pred=() sc_ins=() sc_del=() sc_unc=() sc_comment=() sc_mr=()
	local -a sc_users=() sc_desc=() sc_body=() sc_text=() sc_in=()
	local -A sc_flags=()
	local sc_sums sc_gfile sc_pfile sc_sfile _bt_int _bt_str

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-r*)	sid=${1#-r}; shift ;;
		-d*)	dataspec=${1#-d}; shift ;;
		-e)	earlier=1; shift ;;
		-l)	later=1; shift ;;
		-a)	shift ;;
		-c*)	shift ;;
		-*)	_bt_err "prs: illegal option -- ${1#-}"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ "$#" -lt 1 ]; then
		_bt_err "usage: prs [-a] [-d dataspec] [-r SID] [-e|-l] s.file..."
		return 1
	fi

	for arg in "$@"; do
		if ! _bt_sccs_names "$arg" || ! _bt_sccs_read "$arg"; then
			_bt_err "prs: $arg: not an SCCS file"
			status=1
			continue
		fi
		_bt_sccs_find "$sid"
		i=$_bt_int
		if [ "$i" -lt 0 ]; then
			_bt_err "prs: $arg: no such delta $sid"
			status=1
			continue
		fi
		n=${#sc_sid[@]}
		if [ -n "$dataspec" ]; then
			_bt_sccs_data "$i" "$dataspec"
			continue
		fi
		printf '%s:\n\n' "$arg"
		if [ "$earlier" = 1 ]; then
			for (( ; i < n; i++ )); do _bt_sccs_report "$i"; done
		elif [ "$later" = 1 ]; then
			for (( ; i >= 0; i-- )); do _bt_sccs_report "$i"; done
		else
			_bt_sccs_report "$i"
		fi
	done
	return "$status"
}

# The report prs writes for the delta at index $1.
_bt_sccs_report() {
	local i=$1 line
	printf '%s %s %s %s %s %s %s\n' "${sc_type[i]}" "${sc_sid[i]}" \
		"${sc_date[i]}" "${sc_time[i]}" "${sc_user[i]}" \
		"${sc_serial[i]}" "${sc_pred[i]}"
	printf '%05d/%05d/%05d\n' "${sc_ins[i]}" "${sc_del[i]}" "${sc_unc[i]}"
	printf 'MRs:\n'
	if [ -n "${sc_mr[i]}" ]; then
		while IFS= read -r line; do printf '%s\n' "$line"; done <<< "${sc_mr[i]}"
	fi
	printf 'COMMENTS:\n'
	if [ -n "${sc_comment[i]}" ]; then
		while IFS= read -r line; do printf '%s\n' "$line"; done <<< "${sc_comment[i]}"
	fi
	printf '\n'
	return 0
}

# Expand a -d data specification for the delta at index $1.
_bt_sccs_data() {
	local i=$1 spec=$2 out= j c key
	for (( j = 0; j < ${#spec}; j++ )); do
		c=${spec:j:1}
		if [ "$c" != : ]; then
			out=$out$c
			continue
		fi
		key=${spec:j+1}
		key=${key%%:*}
		j=$(( j + ${#key} + 1 ))
		case $key in
		I)	out=$out${sc_sid[i]} ;;
		R)	out=$out${sc_sid[i]%%.*} ;;
		L)	out=$out${sc_sid[i]#*.} ;;
		D)	out=$out${sc_date[i]} ;;
		T)	out=$out${sc_time[i]} ;;
		P)	out=$out${sc_user[i]} ;;
		DS)	out=$out${sc_serial[i]} ;;
		DP)	out=$out${sc_pred[i]} ;;
		Li)	out=$out${sc_ins[i]} ;;
		Ld)	out=$out${sc_del[i]} ;;
		Lu)	out=$out${sc_unc[i]} ;;
		C)	out=$out${sc_comment[i]} ;;
		MR)	out=$out${sc_mr[i]} ;;
		DT)	out=$out${sc_type[i]} ;;
		F)	out=$out${sc_sfile##*/} ;;
		Dt)	out=$out"${sc_type[i]} ${sc_sid[i]} ${sc_date[i]} ${sc_time[i]} ${sc_user[i]} ${sc_serial[i]} ${sc_pred[i]}" ;;
		*)	out=$out:$key: ;;
		esac
	done
	printf '%s\n' "$out"
	return 0
}

rmdel () {
	local LC_ALL=C
	local _bt_sccs_who=rmdel
	local arg sid= status=0 i j n ser line
	local -a sc_type=() sc_sid=() sc_date=() sc_time=() sc_user=() sc_serial=()
	local -a sc_pred=() sc_ins=() sc_del=() sc_unc=() sc_comment=() sc_mr=()
	local -a sc_users=() sc_desc=() sc_body=() sc_text=() sc_in=()
	local -A sc_flags=()
	local sc_sums sc_gfile sc_pfile sc_sfile _bt_int _bt_str
	local -a newbody=() stack=()

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-r*)	sid=${1#-r}; shift ;;
		-*)	_bt_err "rmdel: illegal option -- ${1#-}"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ -z "$sid" ] || [ "$#" -lt 1 ]; then
		_bt_err "usage: rmdel -r SID s.file..."
		return 1
	fi

	for arg in "$@"; do
		if ! _bt_sccs_names "$arg" || ! _bt_sccs_read "$arg"; then
			_bt_err "rmdel: $arg: not an SCCS file"
			status=1
			continue
		fi
		_bt_sccs_find "$sid"
		i=$_bt_int
		if [ "$i" -lt 0 ]; then
			_bt_err "rmdel: $arg: no such delta $sid"
			status=1
			continue
		fi
		if [ "$i" != 0 ]; then
			_bt_err "rmdel: $arg: $sid is not the newest delta"
			status=1
			continue
		fi
		ser=${sc_serial[i]}
		# what this delta put in goes away with it, and what it took out
		# comes back
		newbody=()
		n=${#sc_body[@]}
		local drop=0
		for (( j = 0; j < n; j++ )); do
			line=${sc_body[j]}
			case $line in
			"${_BT_SOH}I $ser")	drop=1; continue ;;
			"${_BT_SOH}D $ser")	continue ;;
			"${_BT_SOH}E $ser")	drop=0; continue ;;
			esac
			[ "$drop" = 1 ] && continue
			newbody+=("$line")
		done
		sc_body=( ${newbody[@]+"${newbody[@]}"} )
		sc_type=("${sc_type[@]:1}") sc_sid=("${sc_sid[@]:1}")
		sc_date=("${sc_date[@]:1}") sc_time=("${sc_time[@]:1}")
		sc_user=("${sc_user[@]:1}") sc_serial=("${sc_serial[@]:1}")
		sc_pred=("${sc_pred[@]:1}") sc_ins=("${sc_ins[@]:1}")
		sc_del=("${sc_del[@]:1}") sc_unc=("${sc_unc[@]:1}")
		sc_comment=("${sc_comment[@]:1}") sc_mr=("${sc_mr[@]:1}")
		_bt_sccs_write "$arg" || status=1
	done
	return "$status"
}

val () {
	local LC_ALL=C
	local arg sid= silent=0 name= type= status=0 bits=0 i
	local -a sc_type=() sc_sid=() sc_date=() sc_time=() sc_user=() sc_serial=()
	local -a sc_pred=() sc_ins=() sc_del=() sc_unc=() sc_comment=() sc_mr=()
	local -a sc_users=() sc_desc=() sc_body=() sc_text=() sc_in=()
	local -A sc_flags=()
	local sc_sums sc_gfile sc_pfile sc_sfile _bt_int _bt_str

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-s)	silent=1; shift ;;
		-r*)	sid=${1#-r}; shift ;;
		-m*)	name=${1#-m}; shift ;;
		-y*)	type=${1#-y}; shift ;;
		-*)	[ "$1" = - ] && break
			[ "$silent" = 1 ] || _bt_err "val: unknown option ${1#-}"
			bits=$(( bits | 2 ))
			shift ;;
		*)	break ;;
		esac
	done
	if [ "$#" -lt 1 ]; then
		[ "$silent" = 1 ] || _bt_err "val: missing file argument"
		return $(( bits | 1 ))
	fi

	for arg in "$@"; do
		if ! _bt_sccs_names "$arg"; then
			[ "$silent" = 1 ] || _bt_err "val: $arg: not an SCCS file name"
			bits=$(( bits | 8 ))
			continue
		fi
		if ! _bt_sccs_read "$arg"; then
			[ "$silent" = 1 ] || _bt_err "val: $arg: cannot be opened or is not an SCCS file"
			bits=$(( bits | 8 ))
			continue
		fi
		_bt_sccs_sum "$arg"
		if [ "$_bt_int" != "$(( 10#${sc_sums:-0} ))" ]; then
			[ "$silent" = 1 ] || _bt_err "val: $arg: corrupted SCCS file"
			bits=$(( bits | 4 ))
		fi
		if [ -n "$sid" ]; then
			_bt_sccs_find "$sid"
			if [ "$_bt_int" -lt 0 ]; then
				[ "$silent" = 1 ] || _bt_err "val: $arg: no such SID $sid"
				bits=$(( bits | 32 ))
			fi
		fi
		if [ -n "$type" ] && [ "${sc_flags[t]-}" != "$type" ]; then
			[ "$silent" = 1 ] || _bt_err "val: $arg: type is not $type"
			bits=$(( bits | 64 ))
		fi
		if [ -n "$name" ] && [ "${sc_flags[m]-}" != "$name" ]; then
			[ "$silent" = 1 ] || _bt_err "val: $arg: module name is not $name"
			bits=$(( bits | 128 ))
		fi
	done
	return "$bits"
}

sccs () {
	local LC_ALL=C
	local arg cmd dir=. prefix= i
	local -a files=() opts=()

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-d*)	dir=${1#-d}; shift ;;
		-p*)	prefix=${1#-p}; shift ;;
		-r)	shift ;;
		-*)	_bt_err "sccs: illegal option -- ${1#-}"
			return 1 ;;
		*)	break ;;
		esac
	done
	if [ "$#" = 0 ]; then
		_bt_err "usage: sccs [-r] [-d path] [-p path] command [options] [operands]"
		return 1
	fi
	cmd=$1
	shift
	case $cmd in
	admin|delta|get|prs|rmdel|sact|unget|val|cat|diffs|edit|create|print|check|info|tell|clean|unedit|deledit|fix|enter)	;;
	*)	_bt_err "sccs: unknown command $cmd"
		return 1 ;;
	esac
	# the front end knows where the files live, so a plain name becomes the
	# SCCS file that goes with it
	for arg in "$@"; do
		case $arg in
		-*)	opts+=("$arg"); continue ;;
		esac
		case $arg in
		*/s.*|s.*)	files+=("$arg") ;;
		*)		files+=("$dir/${prefix:-SCCS}/s.$arg") ;;
		esac
	done
	case $cmd in
	edit)	cmd=get; opts+=(-e) ;;
	unedit)	cmd=unget ;;
	print)	cmd=prs ;;
	cat)	cmd=get; opts+=(-p -s) ;;
	create|enter)	cmd=admin ;;
	check|info|tell)	cmd=sact ;;
	clean|fix|deledit|diffs)
		_bt_err "sccs: $cmd is not offered here"
		return 1 ;;
	esac
	"$cmd" ${opts[@]+"${opts[@]}"} ${files[@]+"${files[@]}"}
	return $?
}

# ---------------------------------------------------------------------------
# compress, uncompress, zcat -- POSIX.1-2017:
#	compress [-fv] [-b bits] [file...]
#	compress -c [-fv] [-b bits] [file]
#	uncompress [-cfv] [file...]
#	zcat [file...]
#
# The format is the one the standard describes: two magic bytes, a byte saying
# how wide the codes may grow and whether the table may be cleared, and then
# LZW codes packed low bit first, nine bits wide to begin with and one wider
# every time the table fills.  The awkward part is the padding: when the width
# grows, the encoder throws away bits so that the block just ended is a whole
# number of eight-code groups, and the decoder has to throw away the same.
# ---------------------------------------------------------------------------

# Read the whole of fd $1 into the byte array `zb`.
_bt_z_slurp() {
	local i len rc v
	local _bt_buf _bt_nul
	zb=()
	while :; do
		if _bt_read "$1"; then rc=0; else rc=1; fi
		len=${#_bt_buf}
		for (( i = 0; i < len; i++ )); do
			printf -v v '%d' "'${_bt_buf:i:1}"
			zb+=("$v")
		done
		[ "$rc" = 0 ] && [ "$_bt_nul" = 1 ] && zb+=(0)
		[ "$rc" = 1 ] && break
	done
	return 0
}

# Add byte $1 to the output being built, flushing now and then.
_bt_z_put() {
	local b s
	for b in "$@"; do
		printf -v s '\\0%03o' "$b"
		zesc=$zesc$s
	done
	[ "${#zesc}" -gt 8000 ] && { printf '%b' "$zesc" >&"$zfd"; zesc=; }
	return 0
}

_bt_z_flush() {
	[ -n "$zesc" ] && printf '%b' "$zesc" >&"$zfd"
	zesc=
	return 0
}

# Decompress the LZW data in `zb` (magic and all) to fd `zfd`.
#
# The code width grows when the table outgrows what the current width can name,
# and the table is started over when a clear code says so.  At either moment
# the reader skips whatever is left of the current group of eight codes, which
# is the padding the writer put there.
_bt_z_decompress() {
	local n=${#zb[@]} maxbits blockmode i bitpos code width next
	local first prev k c count=0 need
	local -a pfx=() sfx=() stack=()
	if [ "$n" -lt 3 ] || [ "${zb[0]}" != 31 ] || [ "${zb[1]}" != 157 ]; then
		_bt_err "$_bt_z_who: not in compressed format"
		return 1
	fi
	maxbits=$(( zb[2] & 31 ))
	blockmode=$(( (zb[2] >> 7) & 1 ))
	if [ "$maxbits" -lt 9 ] || [ "$maxbits" -gt 16 ]; then
		_bt_err "$_bt_z_who: cannot handle $maxbits bits"
		return 1
	fi
	if [ "$blockmode" = 1 ]; then next=257; else next=256; fi
	width=9
	bitpos=24
	prev=-1
	while :; do
		if [ $(( bitpos + width )) -gt $(( n * 8 )) ]; then break; fi
		code=0
		for (( i = 0; i < width; i++ )); do
			k=$(( bitpos + i ))
			c=$(( (zb[k / 8] >> (k % 8)) & 1 ))
			code=$(( code | (c << i) ))
		done
		bitpos=$(( bitpos + width ))
		count=$(( count + 1 ))
		if [ "$blockmode" = 1 ] && [ "$code" = 256 ]; then
			need=$(( (8 - (count % 8)) % 8 ))
			bitpos=$(( bitpos + need * width ))
			count=0
			pfx=() sfx=()
			next=257
			width=9
			prev=-1
			continue
		fi
		if [ "$code" -lt 256 ]; then
			stack=("$code")
		elif [ "$code" -lt "$next" ]; then
			k=$code
			stack=()
			while [ "$k" -ge 256 ]; do
				stack+=("${sfx[k]}")
				k=${pfx[k]}
			done
			stack+=("$k")
		elif [ "$code" = "$next" ] && [ "$prev" -ge 0 ]; then
			k=$prev
			stack=()
			while [ "$k" -ge 256 ]; do
				stack+=("${sfx[k]}")
				k=${pfx[k]}
			done
			stack+=("$k")
			# a code the table has not got yet stands for the last
			# string with its own first byte on the end
			stack=("$k" "${stack[@]}")
		else
			_bt_err "$_bt_z_who: corrupt input"
			return 1
		fi
		for (( i = ${#stack[@]} - 1; i >= 0; i-- )); do
			_bt_z_put "${stack[i]}"
		done
		first=${stack[${#stack[@]}-1]}
		if [ "$prev" -ge 0 ] && [ "$next" -lt $(( 1 << maxbits )) ]; then
			pfx[next]=$prev
			sfx[next]=$first
			next=$(( next + 1 ))
			# the reader is one code behind the writer, since it can
			# only add an entry once it knows what came next, so it
			# has to change width one code sooner
			if [ "$next" -ge $(( 1 << width )) ] && [ "$width" -lt "$maxbits" ]; then
				need=$(( (8 - (count % 8)) % 8 ))
				bitpos=$(( bitpos + need * width ))
				count=0
				width=$(( width + 1 ))
			fi
		fi
		prev=$code
	done
	_bt_z_flush
	return 0
}

# Compress the bytes in `zb` to fd `zfd`, codes at most $1 bits wide.  When the
# table is one entry short of full it is cleared and started again, which is
# what the clear code in block mode is for and what keeps every reader of this
# format in step.
_bt_z_compress() {
	local maxbits=$1 n=${#zb[@]} i b next width=9 cur=-1 count=0 limit key
	local acc=0 nacc=0
	local -A tbl=()
	next=257
	limit=$(( (1 << maxbits) - 1 ))
	_bt_z_put 31 157 $(( 128 | maxbits ))
	for (( i = 0; i < n; i++ )); do
		b=${zb[i]}
		if [ "$cur" -lt 0 ]; then cur=$b; continue; fi
		key=$cur,$b
		if [ -n "${tbl[$key]-}" ]; then
			cur=${tbl[$key]}
			continue
		fi
		_bt_z_emit "$cur"
		if [ "$next" -ge "$limit" ]; then
			_bt_z_emit 256
			_bt_z_pad
			tbl=()
			next=257
			width=9
		else
			tbl[$key]=$next
			next=$(( next + 1 ))
			if [ "$next" -gt $(( 1 << width )) ] && [ "$width" -lt "$maxbits" ]; then
				_bt_z_pad
				width=$(( width + 1 ))
			fi
		fi
		cur=$b
	done
	[ "$cur" -ge 0 ] && _bt_z_emit "$cur"
	while [ "$nacc" -gt 0 ]; do
		_bt_z_put $(( acc & 255 ))
		acc=$(( acc >> 8 ))
		nacc=$(( nacc - 8 ))
	done
	_bt_z_flush
	return 0
}

# Put one code into the bit stream.  Relies on its caller's locals.
_bt_z_emit() {
	acc=$(( acc | ($1 << nacc) ))
	nacc=$(( nacc + width ))
	count=$(( count + 1 ))
	while [ "$nacc" -ge 8 ]; do
		_bt_z_put $(( acc & 255 ))
		acc=$(( acc >> 8 ))
		nacc=$(( nacc - 8 ))
	done
	return 0
}

# Fill out the current group of eight codes, which is what a reader skips when
# the width changes or the table is cleared.  Relies on its caller's locals.
_bt_z_pad() {
	local need=$(( (8 - (count % 8)) % 8 )) i
	for (( i = 0; i < need; i++ )); do
		_bt_z_emit 0
	done
	count=0
	return 0
}

compress () {
	local LC_ALL=C
	local _bt_z_who=compress
	local arg opt tostdout=0 force=0 verbose=0 bits=16 status=0 file fd out
	local zesc= zfd=1
	local -a zb=()

	while [ "$#" -gt 0 ]; do
		case $1 in
		--)	shift; break ;;
		-b)	shift; [ "$#" = 0 ] && { _bt_err "compress: option requires an argument -- b"; return 1; }
			bits=$1; shift ;;
		-b*)	bits=${1#-b}; shift ;;
		-*)	[ "$1" = - ] && break
			arg=${1#-}
			shift
			while [ -n "$arg" ]; do
				opt=${arg:0:1}
				arg=${arg:1}
				case $opt in
				c)	tostdout=1 ;;
				f)	force=1 ;;
				v)	verbose=1 ;;
				*)	_bt_err "compress: illegal option -- $opt"
					_bt_err "usage: compress [-cfv] [-b bits] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done
	case $bits in
	''|*[!0-9]*)	_bt_err "compress: bits must be a number"; return 1 ;;
	esac
	if [ "$bits" -lt 9 ] || [ "$bits" -gt 16 ]; then
		_bt_err "compress: bits must be between 9 and 16"
		return 1
	fi

	if [ "$#" = 0 ]; then
		_bt_z_slurp 0
		zfd=1
		_bt_z_compress "$bits"
		return 0
	fi
	for file in "$@"; do
		if [ "$file" = - ]; then
			_bt_z_slurp 0
		elif { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_z_slurp "$fd"
			exec {fd}<&-
		else
			_bt_err "compress: $file: No such file or directory"
			status=1
			continue
		fi
		if [ "$tostdout" = 1 ] || [ "$file" = - ]; then
			zfd=1
			_bt_z_compress "$bits"
		else
			out=$file.Z
			if [ -e "$out" ] && [ "$force" = 0 ]; then
				_bt_err "compress: $out already exists"
				status=1
				continue
			fi
			if ! { exec {zfd}>"$out"; } 2>/dev/null; then
				_bt_err "compress: cannot write $out"
				status=1
				continue
			fi
			_bt_z_compress "$bits"
			exec {zfd}>&-
			zfd=1
			# the original would be removed here, which no shell can
			# do; it is left empty instead
			: > "$file"
			[ "$verbose" = 1 ] && _bt_err "$file: compressed to $out"
		fi
	done
	return "$status"
}

uncompress () {
	local LC_ALL=C
	local _bt_z_who=uncompress
	local arg opt tostdout=0 force=0 verbose=0 status=0 file fd out
	local zesc= zfd=1
	local -a zb=()

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
				c)	tostdout=1 ;;
				f)	force=1 ;;
				v)	verbose=1 ;;
				*)	_bt_err "uncompress: illegal option -- $opt"
					_bt_err "usage: uncompress [-cfv] [file...]"
					return 1 ;;
				esac
			done ;;
		*)	break ;;
		esac
	done

	if [ "$#" = 0 ]; then set -- -; fi
	for file in "$@"; do
		if [ "$file" = - ]; then
			_bt_z_slurp 0
			zfd=1
			_bt_z_decompress || status=1
			continue
		fi
		if [ ! -e "$file" ] && [ -e "$file.Z" ]; then file=$file.Z; fi
		if ! { exec {fd}<"$file"; } 2>/dev/null; then
			_bt_err "uncompress: $file: No such file or directory"
			status=1
			continue
		fi
		_bt_z_slurp "$fd"
		exec {fd}<&-
		if [ "$tostdout" = 1 ]; then
			zfd=1
			_bt_z_decompress || status=1
			continue
		fi
		case $file in
		*.Z)	out=${file%.Z} ;;
		*)	_bt_err "uncompress: $file: unknown suffix"
			status=1
			continue ;;
		esac
		if [ -e "$out" ] && [ "$force" = 0 ] && [ -s "$out" ]; then
			_bt_err "uncompress: $out already exists"
			status=1
			continue
		fi
		if ! { exec {zfd}>"$out"; } 2>/dev/null; then
			_bt_err "uncompress: cannot write $out"
			status=1
			continue
		fi
		_bt_z_decompress || status=1
		exec {zfd}>&-
		zfd=1
		: > "$file"
		[ "$verbose" = 1 ] && _bt_err "$file: expanded to $out"
	done
	return "$status"
}

zcat () {
	local LC_ALL=C
	uncompress -c "$@"
	return $?
}
