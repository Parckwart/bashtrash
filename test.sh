#!/usr/bin/env bash
#
# Differential test for bashtrash: every case is run twice, once through the
# bash functions and once through the system coreutils, and the two are
# compared byte for byte on stdout and on exit status.
#
# The harness itself uses external programs (cmp, od, seq); only the tools
# under test are required to be pure bash.
#
# NOTE: the bashtrash side must invoke the *bare* name, so that the shell
# function shadows the real utility.  Calling it by path silently tests
# coreutils against itself.

BT=$(cd -- "$(dirname -- "$0")" && pwd)/bashtrash.sh
R_CAT=$(command -v cat) || exit 1
R_TAIL=$(command -v tail) || exit 1

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1

pass=0 fail=0 failed=()

# The system utility to compare against.  Resolved by name, since the
# bashtrash side is invoked by bare name so the function shadows it.
real_of() { command -v "$1"; }

note_fail() { # MESSAGE
	fail=$((fail + 1)); failed+=("$1"); echo "FAIL: $1"
}

report() { # NAME
	note_fail "$1"
	echo "   bashtrash: $(od -An -c bt.out | head -2 | tr -s ' ')"
	echo "   coreutils: $(od -An -c re.out | head -2 | tr -s ' ')"
}

chk() { # NAME UTIL ARGS...
	local name=$1 util=$2; shift 2
	( . "$BT"; "$util" "$@" ) >bt.out 2>bt.err </dev/null; local a=$?
	"$(real_of "$util")" "$@" >re.out 2>re.err </dev/null; local b=$?
	if cmp -s bt.out re.out && [ "$a" = "$b" ]; then pass=$((pass + 1))
	else report "$name (exit $a vs $b)"; fi
}

chks() { # NAME INFILE UTIL ARGS...
	local name=$1 in=$2 util=$3; shift 3
	( . "$BT"; "$util" "$@" ) <"$in" >bt.out 2>bt.err; local a=$?
	"$(real_of "$util")" "$@" <"$in" >re.out 2>re.err; local b=$?
	if cmp -s bt.out re.out && [ "$a" = "$b" ]; then pass=$((pass + 1))
	else report "$name <$in (exit $a vs $b)"; fi
}

# --- fixtures -------------------------------------------------------------
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\n' > lines12
printf 'a\nb\nc'            > nonl		# no terminating newline
printf ''                   > empty
printf '\n\n\n'             > blanks
printf 'A\000B\000\000C\nD\000\n' > binary	# embedded NULs
printf 'no newline at all'  > oneline
printf 'x\n'                > sp_ace.txt
head -c 300000 /dev/urandom > rand.bin
seq 1 20000                 > big
FILES="lines12 nonl empty blanks binary oneline rand.bin big sp_ace.txt"

echo "### cat"
for f in $FILES; do chk "cat $f" cat "$f"; done
chk "cat two files"    cat lines12 nonl
chk "cat three files"  cat lines12 binary nonl
chk "cat missing"      cat no-such-file
chk "cat missing+ok"   cat no-such-file lines12
chk "cat ok+missing"   cat lines12 no-such-file
chk "cat directory"    cat .
chk "cat -u"           cat -u nonl
chk "cat -u binary"    cat -u binary
chk "cat -uu"          cat -uu lines12
chk "cat -u -u"        cat -u -u lines12
chk "cat --"           cat -- lines12
chk "cat bad option"   cat -Z lines12
for f in $FILES; do chks "cat" "$f" cat; done
chks "cat -"           binary cat -
chks "cat - file"      nonl cat - lines12
chks "cat file -"      nonl cat lines12 -

echo "### tail"
for f in $FILES; do chk "tail $f" tail "$f"; done
for n in 0 1 2 3 5 9 10 11 12 13 20 100 100000; do
	for form in "$n" "-$n" "+$n"; do
		for f in lines12 nonl blanks binary oneline empty big rand.bin; do
			chk "tail -n $form $f" tail -n "$form" "$f"
			chk "tail -c $form $f" tail -c "$form" "$f"
		done
	done
done
chk "tail -n5 attached"   tail -n5 lines12
chk "tail -c7 attached"   tail -c7 lines12
chk "tail -3 obsolescent" tail -3 lines12
chk "tail -n 007"         tail -n 007 lines12
chk "tail --"             tail -- lines12
for f in $FILES; do chks "tail" "$f" tail; done
chks "tail -n 3"  binary tail -n 3
chks "tail -c 9"  rand.bin tail -c 9
chks "tail -n +3" lines12 tail -n +3
chk  "tail missing"     tail no-such-file
chk  "tail directory"   tail .
chk  "tail -n xyz"      tail -n xyz lines12
chk  "tail -n empty"    tail -n '' lines12
chk  "tail bad option"  tail -Z lines12
chk  "tail -n no arg"   tail -n

# --- fuzz: random binary, and block sizes that force the boundary paths ----
echo "### fuzz"
RANDOM=20260825
mkdir -p fz
gen() { local n=$1 out=$2 i
	{ for ((i = 0; i < n; i++)); do
		case $(( RANDOM % 10 )) in
		0|1|2)	printf 'a' ;;
		3|4)	printf 'b' ;;
		5|6|7)	printf '\n' ;;
		8)	printf '\000' ;;
		*)	printf 'Z' ;;
		esac
	done; } > "$out"
}
for i in $(seq 1 30); do gen $(( RANDOM % 400 )) "fz/f$i"; done
gen 0 fz/empty
printf '\000'       > fz/justnul
printf '\n'         > fz/justnl
printf '\000\000\000' > fz/nuls
printf 'a\000\nb\000' > fz/mix

for f in fz/*; do
	for bs in 1 2 3 7 64 65536; do
		( . "$BT"; _BT_BLOCK=$bs; cat "$f" )    >bt.out 2>/dev/null
		( . "$BT"; _BT_BLOCK=$bs; cat -u "$f" ) >bt2.out 2>/dev/null
		"$R_CAT" "$f" >re.out 2>/dev/null
		cmp -s bt.out re.out && pass=$((pass + 1)) || report "fuzz cat $f bs=$bs"
		cp bt2.out bt.out
		cmp -s bt.out re.out && pass=$((pass + 1)) || report "fuzz cat -u $f bs=$bs"
		for spec in "-n 1" "-n 2" "-n 5" "-n 0" "-n +1" "-n +2" "-n +5" "-n +9" \
		            "-c 1" "-c 4" "-c 17" "-c 0" "-c +1" "-c +4" "-c +17" "" "-n 10"; do
			# shellcheck disable=SC2086
			( . "$BT"; _BT_BLOCK=$bs; tail $spec "$f" ) >bt.out 2>/dev/null
			# shellcheck disable=SC2086
			"$R_TAIL" $spec "$f" >re.out 2>/dev/null
			cmp -s bt.out re.out && pass=$((pass + 1)) || report "fuzz tail $spec $f bs=$bs"
		done
	done
done

# --- id -------------------------------------------------------------------
echo "### id"
R_ID=$(command -v id) || exit 1

chkid() { # ARGS...
	( . "$BT"; id "$@" ) >bt.out 2>bt.err </dev/null; local a=$?
	"$R_ID" "$@" >re.out 2>re.err </dev/null; local b=$?
	if cmp -s bt.out re.out && [ "$a" = "$b" ]; then pass=$((pass + 1))
	else report "id $* (exit $a vs $b)"; fi
}

# Every option form, against the calling process.
for o in "" -u -g -G -un -gn -Gn -ur -gr -Gr -unr -gnr -nu -a; do
	if [ -z "$o" ]; then chkid; else chkid $o; fi
done

# Every user this machine knows, so whatever mix of primary, supplementary
# and unmapped groups it happens to have all gets covered.
users=$(while IFS=: read -r n _ || [ -n "$n" ]; do printf '%s\n' "$n"; done < /etc/passwd)
for u in $users; do
	for o in "" -u -g -G -un -gn -Gn -ur -gr; do
		if [ -z "$o" ]; then chkid "$u"; else chkid $o "$u"; fi
	done
done
chkid 0				# numeric operand, taken as a user ID
chkid nosuchuser
chkid -- root
for bad in -n -r -nr -x; do chkid $bad; done
chkid -u -g
chkid -G -u

# Real and effective IDs that differ cannot be reached any other way.
if [ "$("$R_ID" -u)" = 0 ] && command -v setpriv > /dev/null 2>&1; then
	n=0
	for spec in "--ruid 60001 --euid 60002 --rgid 60003 --egid 60004 --groups 60004,60005" \
	            "--ruid 60001 --euid 60001 --rgid 60003 --egid 60003 --groups 60004,60005" \
	            "--ruid 60001 --euid 60001 --rgid 60003 --egid 60003 --clear-groups"; do
		n=$((n + 1))
		# shellcheck disable=SC2086
		out=$(setpriv $spec "$BASH" --noprofile --norc -p -c '
			cd / || exit 1
			bt=$1 real=$2 bad=0
			for o in "" -u -g -G -un -gn -Gn -ur -gr -Gr -unr -gnr; do
				a=$( . "$bt"; id $o 2>/dev/null ); ra=$?
				b=$( "$real" $o 2>/dev/null ); rb=$?
				if [ "$a" != "$b" ] || [ "$ra" != "$rb" ]; then
					bad=1
					echo "id $o: [$a]($ra) vs [$b]($rb)"
				fi
			done
			[ "$bad" = 0 ] && echo ok' _ "$BT" "$R_ID" 2>&1)
		if [ "$out" = ok ]; then pass=$((pass + 1))
		else note_fail "setpriv context $n: $out"; fi
	done
fi

# --- basename, dirname, head, wc, uniq, uname ------------------------------
echo "### basename dirname head wc uniq uname"
printf 'a b c\nd  e\tf\n\n  g  \n'   > words
printf 'x\nx\ny\nx\nx\nx\nz\n'       > dup
printf 'aa 1\nbb 1\ncc 2\ndd 2\n'    > flds

for s in "/usr/lib" "/usr/" "usr" "/" "//" "///" "" "a/b/c" "a//b//" "//a//b//" ".." "a.c" "-"; do
	chk "basename '$s'" basename "$s"
	chk "dirname '$s'"  dirname "$s"
done
chk "basename a.c .c"   basename a.c .c
chk "basename .c .c"    basename .c .c
chk "basename /x/a.c c" basename /x/a.c c
chk "basename -- /a/b"  basename -- /a/b
chk "dirname -- /a/b"   dirname -- /a/b

for f in lines12 nonl empty binary big; do
	for o in "" "-n 1" "-n 3" "-n 0" "-n 12" "-n 100" "-1" "-c 5" "-c 0" "-c 1000"; do
		# shellcheck disable=SC2086
		if [ -z "$o" ]; then chk "head $f" head "$f"; else chk "head $o $f" head $o "$f"; fi
	done
done
chk "head two files"    head lines12 nonl
chk "head -n 2 three"   head -n 2 lines12 nonl binary
chk "head missing"      head no-such-file
chk "head bad option"   head -Z lines12
chks "head" lines12 head
chks "head -n 3" binary head -n 3

for f in lines12 nonl empty binary words big; do
	for o in "" -l -w -c -m -lw -lc -wc -lwc -cl; do
		# shellcheck disable=SC2086
		if [ -z "$o" ]; then chk "wc $f" wc "$f"; else chk "wc $o $f" wc $o "$f"; fi
	done
done
chk "wc two files"      wc lines12 nonl
chk "wc -l two files"   wc -l lines12 nonl
chk "wc three files"    wc lines12 words big
chk "wc missing"        wc no-such-file
for f in lines12 words binary; do chks "wc" "$f" wc; chks "wc -l" "$f" wc -l; done

for o in "" -c -d -u -cd -cu "-f 1" "-s 1" "-f 1 -c" "-s 2 -c"; do
	# shellcheck disable=SC2086
	if [ -z "$o" ]; then chk "uniq dup" uniq dup; chk "uniq flds" uniq flds
	else chk "uniq $o dup" uniq $o dup; chk "uniq $o flds" uniq $o flds; fi
done
chk "uniq nonl"  uniq nonl
chk "uniq empty" uniq empty
chks "uniq" dup uniq

for o in -s -n -r -v -m; do chk "uname $o" uname $o; done
chk "uname" uname

# --- tee, sleep, tty -------------------------------------------------------
echo "### tee sleep tty"
printf 'A\000B\nC\n' > tin
( . "$BT"; tee o1 o2 < tin ) > o0
"$(command -v tee)" r1 r2 < tin > r0
for p in 0 1 2; do
	if cmp -s "o$p" "r$p"; then pass=$((pass + 1)); else note_fail "tee output $p"; fi
done
( . "$BT"; tee -a o1 < tin ) > /dev/null
"$(command -v tee)" -a r1 < tin > /dev/null
if cmp -s o1 r1; then pass=$((pass + 1)); else note_fail "tee -a"; fi
( . "$BT"; tee /nope/x < tin ) > /dev/null 2>&1; a=$?
"$(command -v tee)" /nope/x < tin > /dev/null 2>&1; b=$?
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "tee unwritable ($a vs $b)"; fi

# sleep has nothing to compare against, so time it instead.
s=$EPOCHREALTIME
( . "$BT"; sleep 0.4 )
e=$EPOCHREALTIME
if awk -v s="$s" -v e="$e" 'BEGIN { exit !(e - s > 0.3 && e - s < 1.5) }'; then
	pass=$((pass + 1))
else
	note_fail "sleep 0.4 took $(awk -v s="$s" -v e="$e" 'BEGIN{printf "%.2f", e-s}')s"
fi
chk "sleep bad arg" sleep xyz

# tty off a terminal, and then on a real one if a pty can be had.
chks "tty" /dev/null tty
if command -v script > /dev/null 2>&1; then
	out=$(script -qec '. '"$BT"'; printf "%s %s\n" "$(tty)" "$(command tty)"' /dev/null 2>/dev/null | tr -d '\r' | head -1)
	set -- $out
	if [ -n "$1" ] && [ "$1" = "$2" ]; then pass=$((pass + 1))
	else note_fail "tty in a pty: [$out]"; fi
fi

# --- byte semantics in a multibyte locale ----------------------------------
# ${#s}, ${s:i:n} and read -n all count characters unless the locale is C,
# which silently made every length wrong.
echo "### multibyte locale"
printf 'caf\303\251 na\303\257ve\n' > mb
for loc in C C.UTF-8 en_US.UTF-8; do
	for n in 1 2 3 6 7 12; do
		a=$(LC_ALL=$loc bash -c '. "$1"; tail -c "$2" mb' _ "$BT" "$n" | od -An -c)
		b=$(LC_ALL=$loc "$R_TAIL" -c "$n" mb | od -An -c)
		if [ "$a" = "$b" ]; then pass=$((pass + 1))
		else note_fail "tail -c $n under $loc"; fi
	done
	a=$(LC_ALL=$loc bash -c '. "$1"; cat mb' _ "$BT" | od -An -c)
	b=$(LC_ALL=$loc "$R_CAT" mb | od -An -c)
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "cat under $loc"; fi
done

# --- the pure-bash claim itself -------------------------------------------
echo "### no external programs"
out=$(env -i PATH= "$BASH" --noprofile --norc -c '
	. "$1" || exit 1
	cd "$2" || exit 1
	cat lines12 > /dev/null    || exit 1
	cat -u binary > /dev/null  || exit 1
	tail -n 3 lines12 > /dev/null || exit 1
	tail -c 5 lines12 > /dev/null || exit 1
	id > /dev/null             || exit 1
	echo ok' _ "$BT" "$work" 2>&1)
if [ "$out" = ok ]; then
	pass=$((pass + 1)); echo "all three run with an empty PATH"
else
	note_fail "empty PATH: $out"
fi

echo
echo "==== pass=$pass fail=$fail ===="
if [ "$fail" -gt 0 ]; then
	printf 'failed: %s\n' "${failed[@]:0:20}"
	[ "${#failed[@]}" -gt 20 ] && echo "... and $(( ${#failed[@]} - 20 )) more"
	exit 1
fi
exit 0
