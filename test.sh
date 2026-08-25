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

# A syntax error in the library would leave the real utilities in place
# and every comparison below would be coreutils against itself, passing
# silently.  Refuse to run in that state.
if ! ( . "$BT" ) 2>/dev/null; then
	echo "cannot source $BT" >&2
	exit 1
fi
for u in asa basename cat cksum cmp comm cut date dirname env expand expr \
         fold head id nl od paste pathchk sleep sort split strings tabs \
         tail tee tr tsort tty uname unexpand uniq wc join csplit grep xargs \
         nohup pr dd sed who logname diff cal fuser ipcs; do
	if [ "$( . "$BT"; type -t "$u" )" != function ]; then
		echo "$u is not defined as a function after sourcing $BT" >&2
		exit 1
	fi
done

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

# --- cut, comm, paste, fold, expand, unexpand, tr, cmp ---------------------
echo "### cut comm paste fold expand unexpand tr cmp"
printf 'alpha:beta:gamma\na:b\n:x:\nnodelim\n\na::c\n'          > cf
printf 'one two three\nlonger line here with words\nshort\n'    > tf
printf 'a\nc\ne\n' > s1
printf 'b\nc\nd\ne\nf\n' > s2
printf '1\n2\n3\n' > pp1
printf 'x\ny\n' > pp2
printf 'Q\nR\nS\nT\n' > pp3
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbb cc\nshort\n\tTabbed line that is quite long indeed\n' > ff
printf 'a\tb\tc\n\tlead\nno tabs here\na\t\tdouble\n   spaces   then\ttab\nx\by\n'   > ex
printf 'a b\na  b\na   b\na       b\na        b\nab  c\n  lead  mid\n\t a\n\tmixed   \there\na\tb\tc\n' > ux
printf 'Hello World 123\nfoo   bar\tbaz\naaabbbccc\n' > ti
printf 'A\000B\000\000C\n' > tn

for l in 1 2 3 1,3 2-3 2- -2 5 1-100 "3,1" "1-2,2-3"; do
	chk "cut -c $l"        cut -c "$l" cf
	chk "cut -d: -f $l"    cut -d: -f "$l" cf
	chk "cut -d: -f $l -s" cut -d: -f "$l" -s cf
	chk "cut -f $l"        cut -f "$l" cf
done
chk "cut -b 2-4"       cut -b 2-4 tf
chk "cut -d' ' -f2"    cut -d' ' -f2 tf
chk "cut bad list"     cut -c x cf
chk "cut no mode"      cut cf
chk "cut missing"      cut -c1 no-such-file

for o in "" -1 -2 -3 -12 -13 -23 -123; do
	# shellcheck disable=SC2086
	if [ -z "$o" ]; then chk "comm" comm s1 s2; else chk "comm $o" comm $o s1 s2; fi
done
chk "comm empty"   comm empty s2
chk "comm same"    comm s1 s1
chk "comm missing" comm no-such-file s2

chk "paste two"     paste pp1 pp2
chk "paste three"   paste pp1 pp2 pp3
chk "paste -s"      paste -s pp1 pp2
chk "paste -d:"     paste -d: pp1 pp2
chk "paste -d:-"    paste -d:- pp1 pp2 pp3
chk "paste -s -d:"  paste -s -d: pp1
chk "paste -d nl"   paste -d'\n' pp1 pp2
chk "paste one"     paste pp1
chk "paste missing" paste no-such-file

for w in 5 10 20 1 2; do
	chk "fold -w $w"     fold -w "$w" ff
	chk "fold -b -w $w"  fold -b -w "$w" ff
	chk "fold -s -w $w"  fold -s -w "$w" ff
done
chk "fold"         fold ff
chk "fold -w5 tf"  fold -w5 tf
chk "fold missing" fold no-such-file

for t in "" "-t 4" "-t 8" "-t 1" "-t 2,4,8" "-t 3,6" "-4"; do
	for f in ex ux; do
		# shellcheck disable=SC2086
		if [ -z "$t" ]; then chk "expand $f" expand "$f"; else chk "expand $t $f" expand $t "$f"; fi
	done
done
for t in "" "-a" "-t 2" "-t 4" "-t 8" "-a -t 2" "-a -t 4" "-t 2,4" "-t 2,4,8" "-a -t 3,6,9" "-t 1"; do
	for f in ux ex; do
		# shellcheck disable=SC2086
		if [ -z "$t" ]; then chk "unexpand $f" unexpand "$f"; else chk "unexpand $t $f" unexpand $t "$f"; fi
	done
done
chk "expand bad -t" expand -t x ex
chk "expand missing" expand no-such-file

chks "tr a-z A-Z"    ti tr a-z A-Z
chks "tr A-Z a-z"    ti tr A-Z a-z
chks "tr abc xyz"    ti tr abc xyz
chks "tr ab ba"      ti tr ab ba
chks "tr short set2" ti tr a-z X
chks "tr -d aeiou"   ti tr -d aeiou
chks "tr -d 0-9"     ti tr -d 0-9
chks "tr -s a"       ti tr -s a
chks "tr -s abc"     ti tr -s abc
chks "tr -s space"   ti tr -s ' '
chks "tr -s a-z A-Z" ti tr -s a-z A-Z
chks "tr -cd"        ti tr -cd 'a-zA-Z\n'
chks "tr -c X"       ti tr -c 'a-zA-Z\n' X
chks "tr -cs X"      ti tr -cs 'a-zA-Z\n' X
chks "tr lower upper" ti tr '[:lower:]' '[:upper:]'
chks "tr digit d"    ti tr '[:digit:]' 'd'
chks "tr space _"    ti tr '[:space:]' '_'
chks "tr -d punct"   ti tr -d '[:punct:]'
chks "tr -d space"   ti tr -d '[:space:]'
chks "tr newline"    ti tr '\n' 'X'
chks "tr tab"        ti tr '\t' 'X'
chks "tr octal"      ti tr '\101' 'Z'
chks "tr [z*]"       ti tr 'abc' '[z*]'
chks "tr [z*2]x"     ti tr 'abc' '[z*2]x'
chks "tr NUL through" tn tr a-z A-Z
chks "tr -d NUL"     tn tr -d '\000'
chks "tr NUL to X"   tn tr '\000' 'X'
chks "tr -s NUL"     tn tr -s '\000'
chks "tr -cd NUL"    tn tr -cd 'A-Z\n'

printf 'abcdef\nghi\n' > k1
printf 'abcXef\nghi\n' > k2
printf 'abcdef\n' > k3
printf 'abcdef\nghi\nmore\n' > k4
printf 'ab\000cd\n' > k5
printf 'ab\000ce\n' > k6
printf 'aXcYe\n' > k7
printf 'aZcWe\n' > k8
chk "cmp same"      cmp k1 k1
chk "cmp differ"    cmp k1 k2
chk "cmp prefix"    cmp k1 k3
chk "cmp prefix r"  cmp k3 k1
chk "cmp longer"    cmp k1 k4
chk "cmp -s differ" cmp -s k1 k2
chk "cmp -s same"   cmp -s k1 k1
chk "cmp NUL"       cmp k5 k6
chk "cmp empty"     cmp empty empty
chk "cmp empty vs"  cmp empty k1
chk "cmp missing"   cmp k1 no-such-file
chk "cmp rand"      cmp rand.bin rand.bin
# -l uses the standard's "%d %o %o"; GNU pads the byte number, so the
# comparison ignores leading blanks.
for pair in "k1 k2" "k7 k8" "k5 k6" "k1 k1"; do
	# shellcheck disable=SC2086
	set -- $pair
	a=$( . "$BT"; cmp -l "$1" "$2" 2>/dev/null | sed 's/^ *//;s/  */ /g' )
	b=$( "$(real_of cmp)" -l "$1" "$2" 2>/dev/null | sed 's/^ *//;s/  */ /g' )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "cmp -l $pair"; fi
done

# --- date, cksum, split, env, nl, tsort, pathchk, asa ----------------------
echo "### date cksum split env nl tsort pathchk asa"
R_DATE=$(command -v date); R_CKSUM=$(command -v cksum)

# date is compared by asking for the same instant twice; a second boundary
# between the two calls would be a false failure, so a mismatch is retried.
for f in '+%Y-%m-%d' '+%H:%M' '+%Y' '+literal text' '+%Y%%%j' '+%s'; do
	a=$( . "$BT"; date "$f" )
	b=$( "$R_DATE" "$f" )
	if [ "$a" != "$b" ]; then a=$( . "$BT"; date "$f" ); b=$( "$R_DATE" "$f" ); fi
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "date $f: [$a] vs [$b]"; fi
done
a=$( . "$BT"; date -u '+%Y-%m-%dT%H' ); b=$( "$R_DATE" -u '+%Y-%m-%dT%H' )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "date -u"; fi
chk "date bad option" date -Z
# Not compared against the reference: the bare MMDDhhmm operand is the
# form that *sets* the clock, so running it is not something a test
# suite should do.  Only the refusal is checked.
( . "$BT"; date 010100002000 ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "date should refuse to set the clock"; fi

for f in lines12 nonl empty binary words blanks; do chk "cksum $f" cksum "$f"; done
chk "cksum two"     cksum lines12 binary
chk "cksum missing" cksum no-such-file
chks "cksum stdin"  lines12 cksum

# split writes files, so each run gets its own directory and the trees are
# compared afterwards.
splitchk() {
	rm -rf sp1 sp2
	mkdir -p sp1 sp2
	( cd sp1 && . "$BT" && split "$@" ) > /dev/null 2>&1
	( cd sp2 && "$(real_of split)" "$@" ) > /dev/null 2>&1
	if diff -r sp1 sp2 > /dev/null 2>&1; then pass=$((pass + 1))
	else note_fail "split $*"; fi
}
seq 1 25 > spin
splitchk -l 10 ../spin
splitchk -l 1 ../spin
splitchk -l 1000 ../spin
splitchk -b 7 ../spin
splitchk -b 1 ../nonl
splitchk -b 1k ../spin
splitchk -a 3 -l 5 ../spin
splitchk -l 5 ../spin pre
splitchk -b 4 ../binary
splitchk ../empty

a=$( . "$BT"; env | grep -v '^_=' | sort )
b=$( env | grep -v '^_=' | sort )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "env listing"; fi
for spec in "env FOO=bar sh -c 'echo \$FOO'" \
            "env X=1 Y=2 sh -c 'echo \$X\$Y'" \
            "env sh -c 'exit 7'; echo \$?" \
            "env /bin/echo hi" \
            "env nosuchprog; echo \$?" \
            "env /nonexistent/x; echo \$?" \
            "env /etc/passwd; echo \$?" \
            "env -i /usr/bin/env"; do
	a=$( bash -c ". \"$BT\"; $spec" 2>&1 )
	b=$( bash -c "$spec" 2>&1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "$spec"; fi
done

printf 'one\n\ntwo\nthree\n\n\nfour\n' > nl1
printf '\\:\\:\\:\nhdr\n\\:\\:\nbody1\nbody2\n\\:\nftr\n' > nl3
printf 'foo\nbar\nfoobar\nbaz\n' > nl4
for o in "" -ba -bn -bt -w3 -sX -nln -nrn -nrz -v5 -i2 -p; do
	for f in nl1 nl3 nl4; do
		# shellcheck disable=SC2086
		if [ -z "$o" ]; then chk "nl $f" nl "$f"; else chk "nl $o $f" nl $o "$f"; fi
	done
done
chk "nl -ba -l2"    nl -ba -l2 nl1
chk "nl -s space"   nl -s' ' nl1
chk "nl -ha -ba -fa" nl -ha -ba -fa nl3
chk "nl -bp"        nl -bp^foo nl4
chk "nl -d::"       nl -d'::' nl3
chk "nl missing"    nl no-such-file
chk "nl bad -n"     nl -nxx nl1

printf 'a b\nb c\nc d\n' > ts1
printf 'a b\n' > ts2
printf 'x x\n' > ts3
printf 'a b\nb a\n' > ts5
printf 'a b c\n' > ts6
for f in ts1 ts2 ts3; do chk "tsort $f" tsort "$f"; done
for f in ts5 ts6; do
	# only the exit status is comparable: a loop and an odd token count
	( . "$BT"; tsort "$f" ) > /dev/null 2>&1; a=$?
	"$(real_of tsort)" "$f" > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "tsort $f exit $a vs $b"; fi
done
# For unrelated items the order is unspecified, so check the property.
printf 'a b\nc d\nb d\ne f\n' > ts4
out=$( . "$BT"; tsort ts4 )
ok=1
while read -r u v; do
	iu=$(printf '%s\n' "$out" | grep -n "^$u\$" | cut -d: -f1)
	iv=$(printf '%s\n' "$out" | grep -n "^$v\$" | cut -d: -f1)
	[ -n "$iu" ] && [ -n "$iv" ] && [ "$iu" -lt "$iv" ] || ok=0
done < ts4
if [ "$ok" = 1 ] && [ "$(printf '%s\n' "$out" | sort)" = "$("$(real_of tsort)" ts4 | sort)" ]; then
	pass=$((pass + 1))
else
	note_fail "tsort is not a valid topological order"
fi

long=$(printf 'x%.0s' $(seq 1 300))
deep=$(printf 'd/%.0s' $(seq 1 200))x
for p in "/etc/passwd" "ok/name" "" "-lead" "a b" "no/such/dir/file" "/etc/passwd/x" "." ".." "$long" "$deep"; do
	for o in "" -p -P; do
		# shellcheck disable=SC2086
		a=$( . "$BT"; pathchk $o -- "$p" > /dev/null 2>&1; echo $? )
		# shellcheck disable=SC2086
		b=$( "$(real_of pathchk)" $o -- "$p" > /dev/null 2>&1; echo $? )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "pathchk $o '$p' ($a vs $b)"; fi
	done
done

# asa is not shipped by GNU, so it is checked against the standard directly.
printf ' first\n0double\n1page\n+over\n' > asain
a=$( . "$BT"; asa asain | od -An -c )
b=$( printf 'first\n\ndouble\n\fpage\rover\n' | od -An -c )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "asa carriage control"; fi
a=$( . "$BT"; asa < empty | od -An -c )
if [ -z "$(printf '%s' "$a" | tr -d ' \n')" ]; then pass=$((pass + 1)); else note_fail "asa empty"; fi

# --- strings, tabs, expr, od ----------------------------------------------
echo "### strings tabs expr od"
printf 'ab\000hello world\000\001\002longenough\000x\n' > stin
for o in "" "-n 4" "-n 2" "-n 20" "-t d" "-t o" "-t x" "-a" "-n 5 -t d"; do
	# shellcheck disable=SC2086
	if [ -z "$o" ]; then chk "strings" strings stin; else chk "strings $o" strings $o stin; fi
done
chk "strings binary"  strings binary
chk "strings rand"    strings rand.bin
chk "strings missing" strings no-such-file

for o in -8 -4 -16 "1,10,20" "1,5,9,13" -a -c -f -p -s -u ""; do
	# shellcheck disable=SC2086
	a=$( . "$BT"; tabs $o 2>/dev/null | od -An -c )
	# shellcheck disable=SC2086
	b=$( "$(real_of tabs)" $o 2>/dev/null | od -An -c )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "tabs $o"; fi
done

exprchk() {
	( . "$BT"; expr "$@" ) > bt.out 2>/dev/null; local a=$?
	"$(real_of expr)" "$@" > re.out 2>/dev/null; local b=$?
	if cmp -s bt.out re.out && [ "$a" = "$b" ]; then pass=$((pass + 1))
	else note_fail "expr $* ($a vs $b)"; fi
}
exprchk 1 + 2;         exprchk 5 - 8;          exprchk 3 '*' 4
exprchk 10 / 3;        exprchk 10 % 3;         exprchk 2 + 3 '*' 4
exprchk '(' 2 + 3 ')' '*' 4
exprchk abc = abc;     exprchk abc = abd;      exprchk 5 = 5
exprchk 5 '<' 10;      exprchk 5 '>' 10;       exprchk a '<' b
exprchk 10 '<' 9;      exprchk 3 '!=' 4;       exprchk 3 '>=' 3
exprchk length abcdef; exprchk substr abcdef 2 3
exprchk index abcdef cd; exprchk index abcdef zz
exprchk abc : 'a.c';   exprchk abcdef : 'abc'; exprchk abc : 'x'
exprchk 'abc123' : '[a-z]*\([0-9]*\)'
exprchk match abcdef abc
exprchk 1 '|' 2;       exprchk 0 '|' 2;        exprchk '' '|' 5
exprchk 1 '&' 2;       exprchk 0 '&' 2
exprchk 0;             exprchk '';             exprchk abc
exprchk 1 +;           exprchk +;              exprchk + 1
exprchk + abc;         exprchk 1 / 0

printf 'abc\n' > odin
printf 'abcdefghijklmnopqrstuvwxyz0123456789\n' > odw
head -c 64 /dev/zero > odz
printf 'A\000B\000\000C\n' > odn
for f in odin odw odz odn empty binary; do
	for o in "" -c -b -x -o -d -s "-An -c" "-Ad -c" "-Ax -c" \
	         "-t x1" "-t o1" "-t d1" "-t u1" "-t x2" "-t d2" "-t u4" "-t o4" \
	         "-t a" "-t c" "-v -t x1" "-t x4"; do
		# shellcheck disable=SC2086
		if [ -z "$o" ]; then chk "od $f" od "$f"; else chk "od $o $f" od $o "$f"; fi
	done
done
for o in "-j 3 -t x1" "-j 1 -c" "-j 20 -t x1" "-j 100 -c" "-N 5 -t x1" "-N 1 -c" \
         "-N 100 -c" "-N 0 -c" "-j 2 -N 4 -c" "-t x1 -t c" "-t x1c" "-c -x" \
         "-t d1 -t c" "-t x1 -t x2" "-b -c -x" "-t c -t a"; do
	# shellcheck disable=SC2086
	chk "od $o" od $o odw
done
chk "od missing"  od no-such-file
chk "od two"      od -t x1 odin odw

# --- sort -----------------------------------------------------------------
echo "### sort"
printf 'banana\napple\nCherry\napple\n10\n9\n2\n'   > so1
printf '  b 2\na 10\n c 1\nd 3\n'                   > so2
printf '3:z\n1:y\n2:x\n'                            > so3
printf '10\n9\n2\n-1\n2.5\n0.5\n-3.25\n007\n\nfoo\n' > so4
printf 'x\ny\nx\nz\ny\n'                            > so5
# a mixed table: numbers, blanks, cases, colon fields, empty lines
: > so6
i=0
while [ "$i" -lt 60 ]; do
	case $(( i % 6 )) in
	0)	printf '%s k%s %s\n' $(( (i * 7) % 100 )) $(( i % 9 )) $(( (i * 13) % 1000 )) ;;
	1)	printf '  w%s\t%s\n' $(( i % 20 )) $(( (i * 3) % 50 )) ;;
	2)	printf '%s:F%s:%s\n' $(( (i * 11) % 30 )) $(( i % 5 )) $(( i % 9 )) ;;
	3)	printf 'Word%s\n' $(( i % 15 )) ;;
	4)	printf -- '-%s.%s\n' $(( i % 40 )) $(( (i * 17) % 99 )) ;;
	5)	printf '\n' ;;
	esac >> so6
	i=$(( i + 1 ))
done

for o in "" -r -u -f -n -b -d -i -nr -ru -fbu -nu -un -uf; do
	for f in so1 so4 so5 so6; do
		# shellcheck disable=SC2086
		if [ -z "$o" ]; then chk "sort $f" sort "$f"; else chk "sort $o $f" sort $o "$f"; fi
	done
done
for o in "-k1" "-k2" "-k1,1" "-k2,2" "-k1n" "-k2n" "-k1r" "-k2 -k1" "-k1.2" "-k1,1.3" "-k2nr" "-k2u"; do
	# shellcheck disable=SC2086
	chk "sort $o so2" sort $o so2
	# shellcheck disable=SC2086
	chk "sort $o so6" sort $o so6
done
chk "sort -b -k2"     sort -b -k2 so2
chk "sort -t: -k2"    sort -t: -k2 so3
chk "sort -t: -k1n"   sort -t: -k1n so3
chk "sort -t: -k2,2"  sort -t: -k2,2 so3
chk "sort -t: -k2"    sort -t: -k2 so6
chk "sort empty"      sort empty
chk "sort missing"    sort no-such-file
chk "sort two files"  sort so1 so5
chks "sort stdin"     so1 sort

for f in so1 so5 so6; do
	( . "$BT"; sort -c "$f" ) > /dev/null 2>&1; a=$?
	"$(real_of sort)" -c "$f" > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "sort -c $f ($a vs $b)"; fi
done
"$(real_of sort)" so1 > sorted1
( . "$BT"; sort -c sorted1 ) > /dev/null 2>&1; a=$?
"$(real_of sort)" -c sorted1 > /dev/null 2>&1; b=$?
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "sort -c on sorted input"; fi
( . "$BT"; sort -o m.out so1 ) 2>/dev/null
"$(real_of sort)" -o g.out so1
if cmp -s m.out g.out; then pass=$((pass + 1)); else note_fail "sort -o"; fi

# --- join, csplit ---------------------------------------------------------
echo "### join csplit"
printf 'a 1\nb 2\nc 3\ne 5\n' > j1
printf 'a x\nb y\nd w\ne z\n' > j2
printf 'a:1\nb:2\n' > j3
printf 'a:x\nb:y\n' > j4
printf '1 a\n2 b\n' > j5
printf 'x a\ny b\n' > j6
printf 'a 1\na 2\nb 3\n' > jd1
printf 'a x\na y\nb z\n' > jd2
chk "join"            join j1 j2
chk "join -a1"        join -a1 j1 j2
chk "join -a2"        join -a2 j1 j2
chk "join -a1 -a2"    join -a1 -a2 j1 j2
chk "join -v1"        join -v1 j1 j2
chk "join -v2"        join -v2 j1 j2
chk "join -e -o"      join -e X -a1 -o 0,1.2,2.2 j1 j2
chk "join -o 0,1.2"   join -o 0,1.2 j1 j2
chk "join -o rev"     join -o 2.2,1.2,0 j1 j2
chk "join -t:"        join -t: j3 j4
chk "join -1 -2"      join -1 2 -2 2 j5 j6
chk "join dups"       join jd1 jd2
chk "join dups -a1"   join -a1 jd1 jd2
chk "join empty l"    join empty j2
chk "join empty r"    join j1 empty
chk "join both empty" join empty empty
chk "join missing"    join j1 no-such-file

seq 1 20 > csin
# csplit writes files, so each run gets its own directory.  On an error the
# real csplit removes what it made and this one cannot, so the tree is only
# compared when both runs succeeded.
csplitchk() {
	rm -rf cs1 cs2
	mkdir -p cs1 cs2
	( cd cs1 && . "$BT" && csplit "$@" ) > cs1/out 2> /dev/null; local a=$?
	( cd cs2 && "$(real_of csplit)" "$@" ) > cs2/out 2> /dev/null; local b=$?
	if ! cmp -s cs1/out cs2/out || [ "$a" != "$b" ]; then
		note_fail "csplit $* ($a vs $b)"
		return
	fi
	if [ "$a" = 0 ] && ! diff -r -x out cs1 cs2 > /dev/null 2>&1; then
		note_fail "csplit $* (files differ)"
		return
	fi
	pass=$((pass + 1))
}
csplitchk ../csin 5 10
csplitchk ../csin 5
csplitchk -s ../csin 5
csplitchk -f part ../csin 5
csplitchk -n 3 ../csin 5
csplitchk -f p -n 4 ../csin 3 7
csplitchk ../csin '/1[0-9]/'
csplitchk -s ../csin '/15/'
csplitchk ../csin '/5/' '/15/'
csplitchk ../csin 3 '{2}'
csplitchk ../csin 2 '{3}'
csplitchk ../csin '/2/' '{3}'
csplitchk ../csin '/2/' '{1}'
csplitchk ../csin '%5%' '/10/'
csplitchk ../csin '/5/+2'
csplitchk ../csin '/5/-1'
csplitchk ../csin 100
csplitchk ../csin '/nomatch/'
csplitchk ../csin 5 100

# --- grep, xargs, nohup, pr, dd -------------------------------------------
echo "### grep xargs nohup pr dd"
printf 'apple pie\nBanana\ncherry\napple tart\n\nlast\n' > g1
printf 'other\napple\n' > g2
chk "grep"           grep apple g1
chk "grep two"       grep apple g1 g2
chk "grep -n"        grep -n apple g1
chk "grep -n two"    grep -n apple g1 g2
chk "grep -c"        grep -c apple g1
chk "grep -c two"    grep -c apple g1 g2
chk "grep -l"        grep -l apple g1 g2
chk "grep -v"        grep -v apple g1
chk "grep -i"        grep -i banana g1
chk "grep -x"        grep -x cherry g1
chk "grep -q"        grep -q apple g1
chk "grep -q none"   grep -q zzz g1
chk "grep -F"        grep -F '.' g1
chk "grep -e multi"  grep -e apple -e cherry g1
chk "grep missing"   grep apple no-such-file
chk "grep -s"        grep -s apple no-such-file
chk "grep -in"       grep -in APPLE g1
chk "grep -vc"       grep -vc apple g1
chk "grep -F -x"     grep -F -x cherry g1
for p in 'app\+le' 'app\?le' 'apple\|cherry' '^apple' 'a.*e' '[abc]' 'e$' '\(ap\)ple' 'l\{2\}' 'a\{1,\}'; do
	chk "grep BRE $p" grep "$p" g1
done
for p in 'app+le' 'app?le' 'apple|cherry' '(ap)ple' 'l{2}'; do
	chk "grep ERE $p" grep -E "$p" g1
done
chks "grep stdin" g1 grep apple

xargschk() {
	local desc=$1 input=$2
	shift 2
	local a b
	a=$(printf '%s' "$input" | ( . "$BT"; xargs "$@" ) 2>&1)
	b=$(printf '%s' "$input" | "$(real_of xargs)" "$@" 2>&1)
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "xargs $desc"; fi
}
xargschk "echo X"    'a b c
' echo X
xargschk "-n 2"      'a
b
c
' -n 2 echo
xargschk "quotes"    "a 'b c' d
" echo
xargschk "dquotes"   'a "b c" d
' echo
xargschk "backslash" 'a\ b c
' echo
xargschk "default"   'x y
'
xargschk "-I{}"      'a b
' -I{} echo "[{}]"
xargschk "-L 1"      'a b
c d
' -L 1 echo

# nohup runs its utility; only the outcome is comparable.
( . "$BT"; nohup true ) > /dev/null 2>&1; a=$?
"$(real_of nohup)" true > /dev/null 2>&1; b=$?
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "nohup true ($a vs $b)"; fi
( . "$BT"; nohup sh -c 'exit 5' ) > /dev/null 2>&1; a=$?
"$(real_of nohup)" sh -c 'exit 5' > /dev/null 2>&1; b=$?
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "nohup exit code ($a vs $b)"; fi
( . "$BT"; nohup nosuchprog ) > /dev/null 2>&1; a=$?
"$(real_of nohup)" nosuchprog > /dev/null 2>&1; b=$?
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "nohup not found ($a vs $b)"; fi

seq 1 8 > pr1
seq 1 200 > pr2
# -t only: the page header carries a clock, which would race the reference.
for o in "-t" "-t -n" "-t -o 3" "-t -d" "-t -2" "-t -3" "-t -4" "-t -2 -a" \
         "-t -2 -s:" "-t -l 5" "-t -l 3 -2"; do
	# shellcheck disable=SC2086
	chk "pr $o pr1" pr $o pr1
	# shellcheck disable=SC2086
	chk "pr $o pr2" pr $o pr2
done
chk "pr missing" pr -t no-such-file

# dd's third stderr line is a transfer rate, so only the record counts are
# compared, along with the data itself.
ddchk() {
	( . "$BT"; dd "$@" ) > m.o 2> m.e; local a=$?
	"$(real_of dd)" "$@" > g.o 2> g.e; local b=$?
	# The reference is invoked by absolute path and puts argv[0] in its
	# diagnostics, so the leading path is normalised away.
	local me they
	me=$(head -2 m.e | sed "s|^.*/dd:|dd:|")
	they=$(head -2 g.e | sed "s|^.*/dd:|dd:|")
	if cmp -s m.o g.o && [ "$a" = "$b" ] && [ "$me" = "$they" ]; then
		pass=$((pass + 1))
	else
		note_fail "dd $* ($a vs $b)"
	fi
}
printf 'abcdefghij' > dd1
printf 'A\000B\000\000C\n' > ddn
ddchk if=dd1
ddchk if=dd1 bs=1
ddchk if=dd1 bs=1 count=5
ddchk if=dd1 bs=2
ddchk if=dd1 bs=2 skip=1
ddchk if=dd1 bs=3
ddchk if=dd1 conv=ucase
ddchk if=dd1 bs=1 conv=ucase
ddchk if=dd1 conv=swab
ddchk if=dd1 bs=4 count=1
ddchk if=dd1 bs=1 skip=3 count=4
ddchk if=ddn bs=1
ddchk if=ddn
ddchk if=ddn bs=2
ddchk if=ddn bs=3 skip=1
ddchk if=rand.bin bs=64 count=3
ddchk if=rand.bin bs=100
ddchk if=empty
ddchk if=no-such-file

# --- sed ------------------------------------------------------------------
echo "### sed"
printf 'one\ntwo\nthree\nfour\nfive\n'                                > s1
printf 'foo bar\n\nbaz  qux\n  indented\nUPPER lower\n123 456\nend\n' > s2
printf 'a\nb\nc\nd\ne\nf\ng\nh\n'                                     > s3
sedchk() {
	local f=$1
	shift
	( . "$BT"; sed "$@" "$f" ) > bt.out 2> /dev/null; local a=$?
	"$(real_of sed)" "$@" "$f" > re.out 2> /dev/null; local b=$?
	if cmp -s bt.out re.out && [ "$a" = "$b" ]; then pass=$((pass + 1))
	else note_fail "sed $* < $f ($a vs $b)"; fi
}
for f in s1 s2 s3 empty; do
	sedchk "$f" 's/o/0/'
	sedchk "$f" 's/o/0/g'
	sedchk "$f" 's/o/0/2'
	sedchk "$f" 's/e/E/2g'
	sedchk "$f" 's/x*/-/g'
	sedchk "$f" 's/o*/./g'
	sedchk "$f" 's/[0-9]*/N/g'
	sedchk "$f" 's/[0-9]\+/N/g'
	sedchk "$f" 's/^ *//'
	sedchk "$f" 's/ *$//'
	sedchk "$f" 's/\(.\)\(.\)/\2\1/'
	sedchk "$f" 's/.*/[&]/'
	sedchk "$f" 's/e/&&/g'
	sedchk "$f" 's/^/> /'
	sedchk "$f" 's/[aeiou]//g'
	sedchk "$f" '1d'
	sedchk "$f" '$d'
	sedchk "$f" '2d'
	sedchk "$f" '2,4d'
	sedchk "$f" '/^$/d'
	sedchk "$f" '2!d'
	sedchk "$f" 'y/abc/ABC/'
	sedchk "$f" 'y/oe/0E/'
	sedchk "$f" 'G'
	sedchk "$f" 'N;s/\n/+/'
	sedchk "$f" '$!N;s/\n/ /'
	sedchk "$f" '2{s/./X/}'
	sedchk "$f" ':a;s/o/0/;ta'
	sedchk "$f" -n '$p'
	sedchk "$f" -n '2,3p'
	sedchk "$f" -n 'p;p'
	sedchk "$f" -n 'l'
	sedchk "$f" -n '='
	sedchk "$f" -n '$='
	sedchk "$f" -n 'N;P;D'
	sedchk "$f" -n 'H;${x;s/\n/,/g;p}'
	sedchk "$f" -n '/a/,/c/p'
	sedchk "$f" -n '/./{s/^/> /;p}'
	sedchk "$f" -n 's/o/0/p'
	sedchk "$f" -n '/o/!p'
	sedchk "$f" -n '/o/{s//X/p}'
	sedchk "$f" -e '1h' -e '$!d' -e 'x;G'
	sedchk "$f" -e 's/x/y/' -e 's/o/0/'
done
sedchk s1 '1a\
APPEND'
sedchk s1 '1i\
INS'
sedchk s1 '2c\
CHG'
sedchk s1 '2q'
sedchk s1 -n '/five/q;p'
sedchk s1 's/\t/TAB/'
chk "sed missing" sed 's/a/b/' no-such-file
chks "sed stdin" s1 sed 's/o/0/'

# --- who, logname, diff ---------------------------------------------------
echo "### who logname diff"

# There is no utmp in most containers, so a synthetic one is built and both
# implementations are pointed at it -- who takes the file as an operand.
mkutmp() { # type pid line id user host tv_sec
	printf "$(printf '\\%03o\\%03o\\000\\000' $(( $1 & 255 )) $(( $1 >> 8 )))"
	printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(( $2 & 255 )) $(( $2 >> 8 & 255 )) $(( $2 >> 16 & 255 )) $(( $2 >> 24 & 255 )))"
	printf '%s' "$3"; head -c $(( 32 - ${#3} )) /dev/zero
	printf '%s' "$4"; head -c $(( 4 - ${#4} )) /dev/zero
	printf '%s' "$5"; head -c $(( 32 - ${#5} )) /dev/zero
	printf '%s' "$6"; head -c $(( 256 - ${#6} )) /dev/zero
	head -c 8 /dev/zero
	printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(( $7 & 255 )) $(( $7 >> 8 & 255 )) $(( $7 >> 16 & 255 )) $(( $7 >> 24 & 255 )))"
	head -c 4 /dev/zero
	head -c 36 /dev/zero
}
{ mkutmp 7 1234 pts/0 ts/0 alice host1 1700000000
  mkutmp 7 1235 pts/1 ts/1 bob '' 1700003600
  mkutmp 8 1200 pts/9 ts/9 old '' 1699000000; } > utmp.syn
for o in "" -u; do
	# shellcheck disable=SC2086
	a=$( . "$BT"; who $o utmp.syn 2>&1 )
	# shellcheck disable=SC2086
	b=$( "$(real_of who)" $o utmp.syn 2>&1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "who $o"; fi
done
a=$( . "$BT"; who 2>&1; echo "rc=$?" )
b=$( "$(real_of who)" 2>&1; echo "rc=$?" )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "who with no utmp"; fi
# Same argv[0] artifact as dd: the reference is invoked by path.
a=$( . "$BT"; logname 2>&1; echo "rc=$?" )
b=$( "$(real_of logname)" 2>&1; echo "rc=$?" | sed "s|^.*/logname:|logname:|" )
b=$(printf '%s\n' "$b" | sed "s|^.*/logname:|logname:|")
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "logname"; fi

printf 'a\nb\nc\nd\ne\n' > df1
printf 'a\nB\nc\ne\nf\n' > df2
printf 'a\nb\n'          > df3
printf 'a\nb\nc\n'       > df4
printf 'x\ny\n'          > df5
printf 'a  b\n'          > df6
printf 'a b\n'           > df7
printf 'ABC\n'           > df8
printf 'abc\n'           > df9
for o in "" -e; do
	for pair in "df1 df2" "df2 df1" "df1 df1" "df3 df4" "df4 df3" "df3 df5" \
	            "empty df3" "df3 empty"; do
		# shellcheck disable=SC2086
		set -- $pair
		# shellcheck disable=SC2086
		chk "diff $o $pair" diff $o "$1" "$2"
	done
done
chk "diff -b"  diff -b df6 df7
chk "diff -i"  diff -i df8 df9
chk "diff -b files" diff -b df1 df2
chk "diff missing" diff df1 no-such-file
# -u and -c are not offered at all (they need file timestamps), so
# this is not compared against the reference -- only that it says so.
( . "$BT"; diff -u df1 df2 ) > /dev/null 2>&1
if [ "$?" -eq 2 ]; then pass=$((pass + 1)); else note_fail "diff -u should be refused"; fi

# When several edit scripts are equally short, which one comes out is not
# fixed by the standard and this one does not always pick the same as GNU.
# What is checked instead: the script is as short as the reference's, and
# applying it really does turn the first file into the second.
applyed() {
	awk '
		NR==FNR { orig[FNR]=$0; nl=FNR; next }
		{ script[++sn]=$0 }
		END {
			n=nl; i=1
			while (i<=sn) {
				cmd=script[i++]
				if (cmd ~ /^[0-9]+(,[0-9]+)?[acd]$/) {
					op=substr(cmd,length(cmd),1)
					rng=substr(cmd,1,length(cmd)-1)
					if (index(rng,",")) { split(rng,r,","); a=r[1]+0; b=r[2]+0 }
					else { a=rng+0; b=a }
					textn=0
					if (op=="a" || op=="c") {
						while (i<=sn && script[i]!=".") text[++textn]=script[i++]
						i++
					}
					if (op=="d" || op=="c") { for (k=a;k<=b;k++) del[k]=1 }
					if (op=="a") { for (k=1;k<=textn;k++) add[a]=add[a] (add[a]==""?"":"\n") text[k] }
					if (op=="c") { for (k=1;k<=textn;k++) add[a-1]=add[a-1] (add[a-1]==""?"":"\n") text[k] }
				}
			}
			if (add[0]!="") print add[0]
			for (i=1;i<=nl;i++) { if (!del[i]) print orig[i]; if (add[i]!="") print add[i] }
		}' "$1" "$2"
}
i=0
while [ "$i" -lt 40 ]; do
	i=$(( i + 1 ))
	: > r1
	: > r2
	j=0
	while [ "$j" -lt $(( i % 9 + 1 )) ]; do printf '%s\n' $(( (i * j * 7) % 5 )) >> r1; j=$(( j + 1 )); done
	j=0
	while [ "$j" -lt $(( (i * 3) % 9 + 1 )) ]; do printf '%s\n' $(( (i + j * 3) % 5 )) >> r2; j=$(( j + 1 )); done
	( . "$BT"; diff r1 r2 ) > m.o 2>/dev/null
	"$(real_of diff)" r1 r2 > g.o 2>/dev/null
	md=$(grep -c '^[<>]' m.o); gd=$(grep -c '^[<>]' g.o)
	( . "$BT"; diff -e r1 r2 ) > e.o 2>/dev/null
	applyed r1 e.o > rebuilt 2>/dev/null
	if [ "$md" = "$gd" ] && cmp -s rebuilt r2; then
		pass=$((pass + 1))
	else
		note_fail "diff property (case $i): distance $md vs $gd, rebuild $(cmp -s rebuilt r2 && echo ok || echo bad)"
	fi
done

# --- cal, fuser, ipcs -----------------------------------------------------
echo "### cal fuser ipcs"

# There is no cal on this machine to compare against, so the arithmetic is
# checked against bash's own strftime and the layout against known months.
bad=0
for y in 1970 1999 2000 2001 2024 2025 2026 2030; do
	for mo in 1 2 3 6 9 12; do
		for d in 1 15 28; do
			ep=$(TZ=UTC0 "$R_DATE" -u -d "$y-$mo-$d 12:00:00" +%s 2>/dev/null) || continue
			want=$(TZ=UTC0 printf '%(%w)T' "$ep")
			got=$( . "$BT"; _bt_cal_dow "$y" "$mo" "$d"; echo "$_bt_dow" )
			[ "$want" = "$got" ] || bad=$((bad + 1))
		done
	done
done
if [ "$bad" -eq 0 ]; then pass=$((pass + 1)); else note_fail "cal day-of-week wrong in $bad cases"; fi

a=$( . "$BT"; cal 9 1752 )
b='   September 1752
Su Mo Tu We Th Fr Sa
       1  2 14 15 16
17 18 19 20 21 22 23
24 25 26 27 28 29 30'
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "cal 9 1752 (the eleven missing days)"; fi
a=$( . "$BT"; cal 2 2024 | tail -1 )
if [ "$a" = "25 26 27 28 29" ]; then pass=$((pass + 1)); else note_fail "cal 2 2024 leap day: [$a]"; fi
a=$( . "$BT"; cal 2 2025 | tail -1 )
if [ "$a" = "23 24 25 26 27 28" ]; then pass=$((pass + 1)); else note_fail "cal 2 2025: [$a]"; fi
a=$( . "$BT"; cal 2025 | wc -l )
if [ "$a" = 37 ]; then pass=$((pass + 1)); else note_fail "cal year should be 37 lines, got $a"; fi
a=$( . "$BT"; cal 2025 | sed -n 2p )
if [ -z "$a" ]; then pass=$((pass + 1)); else note_fail "cal year: blank line after the heading"; fi
( . "$BT"; cal 13 2025 ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "cal should reject month 13"; fi
( . "$BT"; cal 1 2 3 ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "cal should reject three operands"; fi

# fuser: the pid list depends on what is running, so a file is held open by
# one known process and the two pid sets are compared.
if command -v fuser > /dev/null 2>&1; then
	printf 'x\n' > held.txt
	sleep 30 < held.txt &
	holder=$!
	sleep 0.3
	a=$( . "$BT"; fuser held.txt 2>/dev/null | tr -s ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' ' )
	b=$( "$(real_of fuser)" held.txt 2>/dev/null | tr -s ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' ' )
	if [ "$a" = "$b" ] && [ -n "$a" ]; then pass=$((pass + 1))
	else note_fail "fuser pid set: [$a] vs [$b]"; fi
	kill "$holder" 2>/dev/null
	wait "$holder" 2>/dev/null
	( . "$BT"; fuser /nonexistent ) > /dev/null 2>&1; a=$?
	"$(real_of fuser)" /nonexistent > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "fuser exit on no holder ($a vs $b)"; fi
fi

# ipcs: compared against the real one, with objects present if they can be
# created and with the tables empty otherwise.
if command -v ipcs > /dev/null 2>&1; then
	made=
	if command -v ipcmk > /dev/null 2>&1; then
		ipcmk -Q > /dev/null 2>&1 && made="$made q"
		ipcmk -M 1024 > /dev/null 2>&1 && made="$made m"
		ipcmk -S 4 > /dev/null 2>&1 && made="$made s"
	fi
	for o in "" -q -m -s -qm -qms; do
		# shellcheck disable=SC2086
		a=$( . "$BT"; ipcs $o 2>&1 )
		# shellcheck disable=SC2086
		b=$( "$(real_of ipcs)" $o 2>&1 )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ipcs $o"; fi
	done
	for t in $made; do
		id=$("$(real_of ipcs)" -$t 2>/dev/null | awk 'NR==4{print $2}')
		[ -n "$id" ] && ipcrm -$t "$id" 2>/dev/null
	done
fi

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
