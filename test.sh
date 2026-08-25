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
         nohup pr dd sed who logname diff cal fuser ipcs patch tput \
         what uuencode uudecode write ps ed m4 iconv ar locale nm \
         admin delta get prs rmdel sact sccs unget val \
         compress uncompress zcat bc make awk gencat ctags cflow cxref file lex yacc man mailx localedef; do
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
# A field longer than the space it goes in would ask head for a negative count,
# which means "all but the last n bytes" and never stops on /dev/zero.
pad() { [ "$1" -gt 0 ] && head -c "$1" /dev/zero; return 0; }
mkutmp() { # type pid line id user host tv_sec
	printf "$(printf '\\%03o\\%03o\\000\\000' $(( $1 & 255 )) $(( $1 >> 8 )))"
	printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(( $2 & 255 )) $(( $2 >> 8 & 255 )) $(( $2 >> 16 & 255 )) $(( $2 >> 24 & 255 )))"
	printf '%s' "${3:0:32}"; pad $(( 32 - ${#3} ))
	printf '%s' "${4:0:4}"; pad $(( 4 - ${#4} ))
	printf '%s' "${5:0:32}"; pad $(( 32 - ${#5} ))
	printf '%s' "${6:0:256}"; pad $(( 256 - ${#6} ))
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

# --- patch ----------------------------------------------------------------
# What matters is the file that comes out, not the chatter on stdout, so each
# case applies the same patch with both implementations and compares the result
# and the exit status.
echo "### patch"
if command -v patch > /dev/null 2>&1; then
	RPATCH=$(real_of patch)
	patchchk() {	# patchchk desc source patchfile [options...]
		local desc=$1 src=$2 pf=$3 orc rrc
		shift 3
		rm -f pw pr pw.orig pr.orig
		cp "$src" pw; cp "$src" pr
		( . "$BT"; patch "$@" -i "$pf" pw < /dev/null ) > /dev/null 2>&1; orc=$?
		"$RPATCH" "$@" -i "$pf" pr < /dev/null > /dev/null 2>&1; rrc=$?
		if [ "$orc" = "$rrc" ] && cmp -s pw pr; then pass=$((pass + 1))
		else note_fail "patch $desc (rc $orc vs $rrc)"; fi
	}

	printf 'alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\ngolf\nhotel\nindia\njuliet\n' > pa
	printf 'alpha\nbravo\nCHARLIE\ndelta\necho\nfoxtrot\ngolf\nHOTEL\nindia\njuliet\nkilo\n' > pb
	"$(real_of diff)" -u pa pb > pu.patch
	"$(real_of diff)" pa pb > pn.patch

	patchchk "unified"          pa pu.patch
	patchchk "normal"           pa pn.patch
	patchchk "unified reversed" pb pu.patch -R
	patchchk "normal reversed"  pb pn.patch -R
	patchchk "unified already applied" pb pu.patch
	patchchk "normal already applied"  pb pn.patch
	patchchk "unified with -b"  pa pu.patch -b

	# a hunk that is not where its header says it is has to be found nearby
	{ echo PRE1; echo PRE2; echo PRE3; cat pa; } > pshift
	patchchk "unified at an offset" pshift pu.patch
	patchchk "normal at an offset"  pshift pn.patch

	# a missing newline at the end of a file survives in both directions
	printf 'a\nb\nc\n' > pnl1
	printf 'a\nB\nc' > pnl2
	"$(real_of diff)" -u pnl1 pnl2 > pnu.patch
	"$(real_of diff)" pnl1 pnl2 > pnn.patch
	patchchk "unified losing the final newline" pnl1 pnu.patch
	patchchk "normal losing the final newline"  pnl1 pnn.patch
	patchchk "unified gaining the final newline" pnl2 pnu.patch -R
	patchchk "normal gaining the final newline"  pnl2 pnn.patch -R

	# -p and the filename in the header
	rm -rf pd1 pd2 pw1 pw2
	mkdir -p pd1/sub pd2/sub pw1 pw2
	cp pa pd1/sub/f; cp pb pd2/sub/f
	"$(real_of diff)" -u pd1/sub/f pd2/sub/f > pp.patch
	for o in "" -p0 -p1 -p2 -p3; do
		cp pa pw1/f; cp pa pw2/f
		# shellcheck disable=SC2086
		a=$( cd pw1 && . "$BT"; patch $o -i ../pp.patch < /dev/null > /dev/null 2>&1; echo $? )
		# shellcheck disable=SC2086
		b=$( cd pw2 && "$RPATCH" $o -i ../pp.patch < /dev/null > /dev/null 2>&1; echo $? )
		if [ "$a" = "$b" ] && cmp -s pw1/f pw2/f; then pass=$((pass + 1))
		else note_fail "patch ${o:--p unset} naming the file from the header ($a vs $b)"; fi
	done

	# -o writes elsewhere and leaves the original alone
	rm -f pw po1 po2
	cp pa pw
	( . "$BT"; patch -o po1 -i pu.patch pw < /dev/null ) > /dev/null 2>&1; a=$?
	"$RPATCH" -o po2 -i pu.patch pw < /dev/null > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ] && cmp -s po1 po2 && cmp -s pw pa; then pass=$((pass + 1))
	else note_fail "patch -o ($a vs $b)"; fi

	# the patch on standard input rather than behind -i
	rm -f pw pr
	cp pa pw; cp pa pr
	( . "$BT"; patch pw < pu.patch ) > /dev/null 2>&1; a=$?
	"$RPATCH" pr < pu.patch > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ] && cmp -s pw pr; then pass=$((pass + 1))
	else note_fail "patch reading the patch from stdin ($a vs $b)"; fi

	# nothing usable in the input, and a file that is not there
	( . "$BT"; patch -i pu.patch nosuch < /dev/null ) > /dev/null 2>&1; a=$?
	"$RPATCH" -i pu.patch nosuch < /dev/null > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "patch on a missing file ($a vs $b)"; fi
	printf 'not a patch at all\n' > pjunk.patch
	( . "$BT"; patch -i pjunk.patch < /dev/null ) > /dev/null 2>&1; a=$?
	"$RPATCH" -i pjunk.patch < /dev/null > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "patch on garbage input ($a vs $b)"; fi

	# random pairs, both formats, both directions: lines carry spaces, tabs and
	# backslashes, and half of them end without a final newline
	for seed in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
		RANDOM=$seed
		: > px
		n=$(( 5 + RANDOM % 25 ))
		for i in $(seq 1 "$n"); do
			printf '  line%d\tx %d \\ *\n' "$((RANDOM % 9))" "$i" >> px
		done
		: > py
		i=0
		while IFS= read -r ln; do
			i=$((i + 1))
			[ $(( RANDOM % 7 )) = 0 ] && continue
			[ $(( RANDOM % 7 )) = 0 ] && printf '  NEW-%d \\t\n' "$i" >> py
			printf '%s\n' "$ln" >> py
		done < px
		[ $(( RANDOM % 2 )) = 0 ] && printf 'TAIL with no newline' >> py
		{ echo Z1; echo Z2; echo Z3; echo Z4; cat px; } > pxs
		"$(real_of diff)" -u px py > pru.patch
		"$(real_of diff)" px py > prn.patch
		patchchk "random $seed unified"           px pru.patch
		patchchk "random $seed normal"            px prn.patch
		patchchk "random $seed unified reversed"  py pru.patch -R
		patchchk "random $seed normal reversed"   py prn.patch -R
		patchchk "random $seed unified applied"   py pru.patch
		patchchk "random $seed normal applied"    py prn.patch
		patchchk "random $seed unified shifted"   pxs pru.patch
		patchchk "random $seed normal shifted"    pxs prn.patch
	done
	# how far a hunk may travel, and which hunks are pinned to the ends of the
	# file because the patch left them short of context
	i=1
	: > pf0
	while [ "$i" -le 20 ]; do printf 'c%d\n' "$i" >> pf0; i=$((i + 1)); done
	for u in 1 2 3; do
		for k in 1 2 3 5 18 20; do
			"$(real_of sed)" "${k}s/.*/CHANGED/" pf0 > pf1
			"$(real_of diff)" -U$u pf0 pf1 > pk.patch
			for off in 0 1 2 4 6 9; do
				i=1
				: > pfs
				while [ "$i" -le "$off" ]; do printf 'Z%d\n' "$i" >> pfs; i=$((i + 1)); done
				cat pf0 >> pfs
				patchchk "-U$u change at $k, $off lines down" pfs pk.patch
			done
		done
	done
fi

# --- tput -----------------------------------------------------------------
# Every capability of every terminfo entry on this machine, compared name by
# name against the real tput: the value it prints and the status it exits with.
echo "### tput"
if command -v tput > /dev/null 2>&1 && command -v infocmp > /dev/null 2>&1; then
	RTPUT=$(real_of tput)
	terms=
	for d in /usr/share/terminfo /lib/terminfo /etc/terminfo; do
		[ -d "$d" ] || continue
		for f in "$d"/*/*; do
			[ -f "$f" ] || continue
			terms="$terms ${f##*/}"
		done
		[ -n "$terms" ] && break
	done
	caps=$( . "$BT"; echo "$_BT_TI_BOOLS $_BT_TI_NUMS $_BT_TI_STRS" )
	# a handful of terminals get every capability; the rest get a sample, so
	# that the suite does not spend a minute here
	i=0
	for t in $terms; do
		i=$((i + 1))
		if [ $(( i % 6 )) = 1 ]; then
			use=$caps
		else
			use="clear longname cols lines am bw colors cbt bel cr sgr0
			     smso rmso el ed smcup rmcup flash civis cnorm kf5 is2
			     rs1 acsc u6 enacs smkx rmkx nosuchcapability"
		fi
		# shellcheck disable=SC2086
		a=$( . "$BT"
		     for c in $use; do
			printf '%s|' "$c"
			tput -T"$t" "$c" 2> /dev/null
			printf '|%s\n' "$?"
		     done )
		# shellcheck disable=SC2086
		b=$( for c in $use; do
			printf '%s|' "$c"
			"$RTPUT" -T"$t" "$c" 2> /dev/null
			printf '|%s\n' "$?"
		     done )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "tput -T$t"; fi
	done

	# the ones that take parameters, where the terminfo parameter machine
	# actually has something to do
	for t in $terms; do
		a=$( . "$BT"
		     for c in "cup 5 10" "cup 0 0" "setaf 3" "setab 4" "hpa 10" \
			      "vpa 4" "dch 3" "cud 7" "il 2" "ich 4" "cub 3" \
			      "cuf 9" "csr 2 20" "mrcup 1 2" "wind 1 2 3 4" \
			      "sgr 0 0 0 0 0 0 0 0 0" "sgr 0 1 0 0 1 0 0 0 0" \
			      "sgr 1 0 0 0 0 0 0 0 1" "tsl 3" "pfkey 1 abc"; do
			printf '%s|' "$c"
			# shellcheck disable=SC2086
			tput -T"$t" $c 2> /dev/null
			printf '|%s\n' "$?"
		     done )
		b=$( for c in "cup 5 10" "cup 0 0" "setaf 3" "setab 4" "hpa 10" \
			      "vpa 4" "dch 3" "cud 7" "il 2" "ich 4" "cub 3" \
			      "cuf 9" "csr 2 20" "mrcup 1 2" "wind 1 2 3 4" \
			      "sgr 0 0 0 0 0 0 0 0 0" "sgr 0 1 0 0 1 0 0 0 0" \
			      "sgr 1 0 0 0 0 0 0 0 1" "tsl 3" "pfkey 1 abc"; do
			printf '%s|' "$c"
			# shellcheck disable=SC2086
			"$RTPUT" -T"$t" $c 2> /dev/null
			printf '|%s\n' "$?"
		     done )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "tput -T$t with parameters"; fi
	done

	( . "$BT"; tput -T nosuchterminal clear ) > /dev/null 2>&1; a=$?
	"$RTPUT" -T nosuchterminal clear > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "tput on an unknown terminal ($a vs $b)"; fi
	( . "$BT"; tput ) > /dev/null 2>&1; a=$?
	"$RTPUT" > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "tput with no operand ($a vs $b)"; fi
fi

# --- what, uuencode, uudecode, write ---------------------------------------
# Nothing on this machine implements these, so they are held to the standard
# and to known-good encodings rather than to another program.
echo "### what uuencode uudecode write"

printf 'x\n@(#)hello world"trailing\nmore\n@(#)second>cut\n' > what1
printf 'nothing to see\n' > what2
printf 'AAA\000@(#)ident\000BBB\n' > what3
a=$( . "$BT"; what what1 2>&1 )
b=$( printf 'what1:\n\thello world\n\tsecond' )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "what: [$a]"; fi
a=$( . "$BT"; what -s what1 2>&1 )
b=$( printf 'what1:\n\thello world' )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "what -s: [$a]"; fi
a=$( . "$BT"; what what3 2>&1 )
b=$( printf 'what3:\n\tident' )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "what on a file with NUL bytes: [$a]"; fi
( . "$BT"; what what2 ) > /dev/null 2>&1
if [ "$?" -eq 1 ]; then pass=$((pass + 1)); else note_fail "what should exit 1 when it finds nothing"; fi
( . "$BT"; what what1 what2 ) > /dev/null 2>&1
if [ "$?" -eq 0 ]; then pass=$((pass + 1)); else note_fail "what should exit 0 when any file matches"; fi
a=$( . "$BT"; what what1 what2 2>&1 )
b=$( printf 'what1:\n\thello world\n\tsecond\nwhat2:' )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "what over several files: [$a]"; fi

# the encodings themselves, against vectors computed elsewhere
uuvec() {	# uuvec text expected
	local a
	a=$( . "$BT"; printf '%s' "$1" | uuencode n | sed -n 2p )
	if [ "$a" = "$2" ]; then pass=$((pass + 1))
	else note_fail "uuencode '$1': [$a] not [$2]"; fi
}
uuvec f '!9@``'
uuvec fo '"9F\`'
uuvec foo '#9F]O'
uuvec foob '$9F]O8@``'
uuvec fooba '%9F]O8F$`'
uuvec foobar '&9F]O8F%R'

b64vec() {	# b64vec text expected
	local a
	a=$( . "$BT"; printf '%s' "$1" | uuencode -m n | sed -n 2p )
	if [ "$a" = "$2" ]; then pass=$((pass + 1))
	else note_fail "uuencode -m '$1': [$a] not [$2]"; fi
}
b64vec f 'Zg=='
b64vec fo 'Zm8='
b64vec foo 'Zm9v'
b64vec foob 'Zm9vYg=='
b64vec fooba 'Zm9vYmE='
b64vec foobar 'Zm9vYmFy'

a=$( . "$BT"; printf 'abc' | uuencode name.txt )
b=$( printf 'begin 644 name.txt\n#86)C\n\140\nend' )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "uuencode header and terminator: [$a]"; fi
a=$( . "$BT"; printf 'abc' | uuencode -m name.txt )
b=$( printf 'begin-base64 644 name.txt\nYWJj\n====' )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "uuencode -m header and terminator: [$a]"; fi

# round trips, including the awkward lengths and a file full of NUL bytes
i=0
while [ "$i" -le 10 ]; do
	head -c "$i" /dev/urandom > uu.in
	for o in "" -m; do
		# shellcheck disable=SC2086
		( . "$BT"; uuencode $o uu.in carried ) > uu.enc 2>&1
		( . "$BT"; uudecode -o uu.out uu.enc ) 2>&1
		if cmp -s uu.in uu.out; then pass=$((pass + 1))
		else note_fail "uuencode${o:+ -m} round trip at $i bytes"; fi
	done
	i=$((i + 1))
done
for n in 44 45 46 90 1000; do
	head -c "$n" /dev/urandom > uu.in
	for o in "" -m; do
		# shellcheck disable=SC2086
		( . "$BT"; uuencode $o uu.in carried ) > uu.enc 2>&1
		( . "$BT"; uudecode -o uu.out uu.enc ) 2>&1
		if cmp -s uu.in uu.out; then pass=$((pass + 1))
		else note_fail "uuencode${o:+ -m} round trip at $n bytes"; fi
	done
done
"$(real_of tr)" '\000-\377' '\000' < /dev/zero 2>/dev/null | head -c 200 > uu.in
( . "$BT"; uuencode uu.in carried ) > uu.enc 2>&1
( . "$BT"; uudecode -o uu.out uu.enc ) 2>&1
if cmp -s uu.in uu.out; then pass=$((pass + 1)); else note_fail "uuencode round trip over NUL bytes"; fi

# the historical form encodes a zero as a space rather than a backquote, and
# uudecode has to take either
( . "$BT"; uuencode uu.in carried ) > uu.enc 2>&1
"$(real_of tr)" '\140' ' ' < uu.enc > uu.enc2
( . "$BT"; uudecode -o uu.out uu.enc2 ) 2>&1
if cmp -s uu.in uu.out; then pass=$((pass + 1)); else note_fail "uudecode of the space-padded form"; fi

# with no -o the name in the header decides where it lands
rm -f uu.named
printf 'hello\n' > uu.in
( . "$BT"; uuencode uu.in uu.named ) > uu.enc 2>&1
( . "$BT"; uudecode uu.enc ) 2>&1
if cmp -s uu.in uu.named; then pass=$((pass + 1)); else note_fail "uudecode using the name in the header"; fi
( . "$BT"; uudecode -o uu.out what2 ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "uudecode should refuse input with no begin line"; fi
( . "$BT"; uuencode ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "uuencode should refuse to run with no operand"; fi

# write: the paths that do not need a second user sitting at a terminal
a=$( . "$BT"; write nosuchuser 2>&1 < /dev/null )
if [ "$a" = "write: nosuchuser is not logged in" ]; then pass=$((pass + 1))
else note_fail "write to an absent user: [$a]"; fi
a=$( . "$BT"; write nosuchuser pts/99 2>&1 < /dev/null )
if [ "$a" = "write: nosuchuser is not logged in on pts/99" ]; then pass=$((pass + 1))
else note_fail "write naming a terminal: [$a]"; fi
( . "$BT"; write ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "write should refuse to run with no operand"; fi
( . "$BT"; write a b c ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "write should refuse three operands"; fi
# with a utmp of its own it finds the terminal, and then cannot open it
mkutmp 7 999 pts/99 '/99' fakeuser '' 1700000000 > utmp.write
a=$( . "$BT"; _BT_UTMP=utmp.write; write fakeuser 2>&1 < /dev/null )
case $a in
"write: permission denied on /dev/pts/99")	pass=$((pass + 1)) ;;
*)						note_fail "write to a terminal that is not there: [$a]" ;;
esac

# --- ps ---------------------------------------------------------------------
# A listing of everything running changes between two runs, so a process that
# will sit still is started first and compared in full, and the system-wide
# listings are compared only on the processes both runs saw and only on the
# columns that cannot change underneath them.
echo "### ps"
if command -v ps > /dev/null 2>&1 && [ -r /proc/1/stat ]; then
	RPS=$(real_of ps)
	"$(real_of sleep)" 30 &
	victim=$!
	"$(real_of sleep)" 0.3

	for spec in "-p $victim" "-fp $victim" "-lp $victim" "-p $victim -o pid,ppid,user,tty,stat,comm" \
		    "-p $victim -o pid=,comm=" "-p $victim -o pid=PROCESS,comm=NAME" \
		    "-p 1" "-p 1,$victim" "-p 999999" "-p 1 -o pid,ppid,uid,gid,vsz,sz,nice,pri,stat"; do
		# shellcheck disable=SC2086
		a=$( . "$BT"; ps $spec 2>&1; echo "rc=$?" )
		# shellcheck disable=SC2086
		b=$( "$RPS" $spec 2>&1; echo "rc=$?" )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ps $spec"; fi
	done

	for f in pid ppid pgid sid uid gid user euser ruser group egroup rgroup \
		 tty comm args stat state wchan nice pri opri vsz rss sz thcount \
		 nlwp f addr time stime c pcpu; do
		a=$( . "$BT"; ps -p "$victim" -o "$f" 2>&1 )
		b=$( "$RPS" -p "$victim" -o "$f" 2>&1 )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ps -o $f: [$a] vs [$b]"; fi
		a=$( . "$BT"; ps -p 1 -o "$f" 2>&1 )
		b=$( "$RPS" -p 1 -o "$f" 2>&1 )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ps -p 1 -o $f: [$a] vs [$b]"; fi
	done

	( . "$BT"; ps -o nosuchfield ) > /dev/null 2>&1
	if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "ps should refuse an unknown -o field"; fi
	( . "$BT"; ps -p 999999 ) > /dev/null 2>&1
	if [ "$?" -eq 1 ]; then pass=$((pass + 1)); else note_fail "ps should exit 1 when it selects nothing"; fi

	# the whole-system listings, on the columns that hold still
	for spec in "-e" "-A" "-d" "-a" "-u root" "-U root" "-G root"; do
		# shellcheck disable=SC2086
		( . "$BT"; ps $spec -o pid=,ppid=,uid=,pgid=,sid=,tty= ) > ps.ours 2>/dev/null
		# shellcheck disable=SC2086
		"$RPS" $spec -o pid=,ppid=,uid=,pgid=,sid=,tty= > ps.ref 2>/dev/null
		n=$( "$(real_of awk)" 'NR==FNR{r[$1]=$0; next} ($1 in r) && r[$1]!=$0 {n++} END{print n+0}' \
			ps.ref ps.ours )
		k=$( "$(real_of awk)" 'NR==FNR{r[$1]=1; next} ($1 in r){n++} END{print n+0}' ps.ref ps.ours )
		# -a can legitimately select nothing when no process has a terminal
		if [ "$n" = 0 ] && { [ "$k" -gt 5 ] ||
		     { [ ! -s ps.ours ] && [ ! -s ps.ref ]; }; }; then pass=$((pass + 1))
		else note_fail "ps $spec: $n of $k shared rows differ"; fi
	done

	# the heading of each fixed layout, which is the part that never moves
	for spec in "" "-f" "-l"; do
		# shellcheck disable=SC2086
		a=$( . "$BT"; ps -e $spec 2>/dev/null | head -1 )
		# shellcheck disable=SC2086
		b=$( "$RPS" -e $spec 2>/dev/null | head -1 )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ps -e $spec heading: [$a] vs [$b]"; fi
	done

	kill "$victim" 2>/dev/null
	wait "$victim" 2>/dev/null
fi

# --- ed ---------------------------------------------------------------------
# Nothing here implements ed either, so the strongest check available is the one
# ed was built for: diff -e writes an ed script, and running it has to turn one
# file into the other.
echo "### ed"
edchk() {	# edchk description script expected
	local a
	a=$( printf '%s\n' "$2" | ( . "$BT"; ed -s ed1 ) 2>&1 )
	if [ "$a" = "$3" ]; then pass=$((pass + 1))
	else note_fail "ed $1: [$a] not [$3]"; fi
}

printf 'one\ntwo\nthree\nfour\nfive\n' > ed1
printf 'a\tb\\c\n' > ed2

edchk "print the lot"     ',p'            "$(printf 'one\ntwo\nthree\nfour\nfive')"
edchk "print a range"     '2,4p'          "$(printf 'two\nthree\nfour')"
edchk "number the lines"  '2,3n'          "$(printf '2\ttwo\n3\tthree')"
edchk "a bare address"    '3'             'three'
edchk "delete"            "$(printf '2d\n,p')" "$(printf 'one\nthree\nfour\nfive')"
edchk "append"            "$(printf '2a\nX\n.\n,p')" "$(printf 'one\ntwo\nX\nthree\nfour\nfive')"
edchk "insert"            "$(printf '2i\nX\n.\n,p')" "$(printf 'one\nX\ntwo\nthree\nfour\nfive')"
edchk "append at zero"    "$(printf '0a\nX\n.\n,p')" "$(printf 'X\none\ntwo\nthree\nfour\nfive')"
edchk "change"            "$(printf '2,3c\nX\n.\n,p')" "$(printf 'one\nX\nfour\nfive')"
edchk "move"             "$(printf '1m$\n,p')" "$(printf 'two\nthree\nfour\nfive\none')"
edchk "copy"             "$(printf '1t$\n,p')" "$(printf 'one\ntwo\nthree\nfour\nfive\none')"
edchk "join"             "$(printf '1,2j\n,p')" "$(printf 'onetwo\nthree\nfour\nfive')"
edchk "substitute"       "$(printf ',s/o/0/g\n,p')" "$(printf '0ne\ntw0\nthree\nf0ur\nfive')"
edchk "substitute with &" "$(printf '2s/two/[&]/\n2p')" '[two]'
edchk "a backreference"  "$(printf '3s/\\(th\\)\\(ree\\)/\\2\\1/\n3p')" 'reeth'
edchk "the p flag"       '1s/one/1/p'    '1'
edchk "global"           "$(printf 'g/e/s/e/E/\n,p')" "$(printf 'onE\ntwo\nthrEe\nfour\nfivE')"
edchk "global inverted"  "$(printf 'v/o/s/^/X/\n,p')" "$(printf 'one\ntwo\nXthree\nfour\nXfive')"
edchk "search forwards"  '/three/'       'three'
edchk "search backwards" "$(printf '$\n?two?')" "$(printf 'five\ntwo')"
edchk "relative address" "$(printf '2\n+2p')" "$(printf 'two\nfour')"
edchk "semicolon range"  '2;4p'          "$(printf 'two\nthree\nfour')"
edchk "a mark"           "$(printf '2ka\n'"'"'a')" 'two'
edchk "undo"             "$(printf '1d\nu\n,p')" "$(printf 'one\ntwo\nthree\nfour\nfive')"
edchk "the last line"    '$='            '5'
edchk "an unknown command" 'Z'           '?'
edchk "an address past the end" '99p'    '?'
edchk "no match to substitute"  '1s/zzz/x/' '?'
edchk "quitting with changes"   "$(printf '1d\nq')" '?'
edchk "the H command"    "$(printf 'H\n99p')" "$(printf '?\nInvalid address')"

a=$( printf ',l\n' | ( . "$BT"; ed -s ed2 ) 2>&1 )
if [ "$a" = 'a\tb\\c$' ]; then pass=$((pass + 1)); else note_fail "ed -l: [$a]"; fi

# without -s it reports byte counts, and w writes what was read
a=$( printf 'w ed3\nq\n' | ( . "$BT"; ed ed1 ) 2>&1 )
if [ "$a" = "$(printf '24\n24')" ] && cmp -s ed3 ed1; then pass=$((pass + 1))
else note_fail "ed byte counts: [$a]"; fi
( . "$BT"; ed -s ed1 ) < /dev/null > /dev/null 2>&1
if [ "$?" -eq 0 ]; then pass=$((pass + 1)); else note_fail "ed on end of input should exit 0"; fi
a=$( printf '99p\nq\n' | ( . "$BT"; ed -s ed1 ) > /dev/null 2>&1; echo $? )
if [ "$a" = 1 ]; then pass=$((pass + 1)); else note_fail "ed should exit 1 after an error"; fi

# the round trip: diff writes the script, ed has to reproduce the file
for seed in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	RANDOM=$seed
	: > edx
	n=$(( 3 + RANDOM % 25 ))
	i=1
	while [ "$i" -le "$n" ]; do
		printf 'line%d  tail %d\n' "$((RANDOM % 9))" "$i" >> edx
		i=$((i + 1))
	done
	: > edy
	i=0
	while IFS= read -r ln; do
		i=$((i + 1))
		[ $(( RANDOM % 5 )) = 0 ] && continue
		[ $(( RANDOM % 5 )) = 0 ] && printf 'NEW-%d\n' "$i" >> edy
		printf '%s\n' "$ln" >> edy
	done < edx
	[ $(( RANDOM % 2 )) = 0 ] && printf 'TAILLINE\n' >> edy
	"$(real_of diff)" -e edx edy > edscript
	printf 'w edout\nq\n' >> edscript
	rm -f edout
	cp edx edwork
	( . "$BT"; ed -s edwork ) < edscript > /dev/null 2>&1
	if cmp -s edout edy; then pass=$((pass + 1))
	else note_fail "ed replaying diff -e (case $seed)"; fi
done

# --- m4 ---------------------------------------------------------------------
# Compared against the real m4 on inputs that exercise quoting, the argument
# rules, recursion, diversions and the arithmetic.
echo "### m4"
if command -v m4 > /dev/null 2>&1; then
	RM4=$(real_of m4)
	mkdir -p m4t
	cd m4t || exit 1

	cat > m1 <<'M4EOF'
define(`greet', `Hello, $1!')dnl
greet(`World')
greet
define(`count', `ifelse($1, 0, `', `$1 count(decr($1))')')dnl
count(5)
M4EOF
	cat > m2 <<'M4EOF'
changequote([,])dnl
[literal ` and ']
define([x],[y])x
changequote`'dnl
`back to normal' x
M4EOF
	cat > m3 <<'M4EOF'
divert(1)dnl
first diversion
divert(2)dnl
second diversion
divert(0)dnl
main text
undivert(2)
undivert(1)
M4EOF
	cat > m4f <<'M4EOF'
define(`f', `$#:$*:$@')dnl
f(a,b,c)
f()
f
define(`g', `$1-$2-$9-')dnl
g(1,2)
shift(a,b,c)
M4EOF
	cat > m5 <<'M4EOF'
eval(1+2*3) eval(2**10) eval(7/2) eval(7%3) eval(1<2) eval(1&&0) eval(!0)
eval(255, 16) eval(255, 2, 16) eval(-5)
incr(41) decr(0)
len() len(`abc') index(`abcabc',`ca') index(`abc',`z')
substr(`hello world', 6) substr(`hello', 1, 2) substr(`hello', 10)
translit(`abcdef', `a-f') translit(`hello',`lo',`LO')
M4EOF
	cat > m6 <<'M4EOF'
pushdef(`a', `one')a
pushdef(`a', `two')a
popdef(`a')a
popdef(`a')a
ifdef(`a', `still', `gone')
m4wrap(`wrapped
')dnl
before wrap
M4EOF
	cat > m7 <<'M4EOF'
# a comment with `quotes' and macros define(x,y)
changecom(`/*', `*/')dnl
/* another define(z,w) comment */
after
changecom()dnl
# no longer a comment
M4EOF
	cat > m8 <<'M4EOF'
define(`forloop', `pushdef(`$1', `$2')_forloop($@)popdef(`$1')')dnl
define(`_forloop', `$4`'ifelse($1, `$3', `', `define(`$1', incr($1))_forloop($@)')')dnl
forloop(`i', 1, 5, `i ')
define(`fib', `ifelse(eval($1<2), 1, $1, `eval(fib(decr($1)) + fib(decr(decr($1))))')')dnl
fib(10)
M4EOF
	cat > m9 <<'M4EOF'
define(`quoted', `he said ``hello'' loudly')dnl
quoted
define(`parens', `a (b, c) d')dnl
parens
define(`withcomma', `x`,'y')dnl
withcomma
len(`a(b,c)')
M4EOF
	cat > m10 <<'M4EOF'
defn(`len')
define(`mylen', defn(`len'))dnl
mylen(`abcd')
undefine(`len')dnl
len(`abcd')
M4EOF
	printf 'included content\n' > m4inc
	cat > m11 <<'M4EOF'
include(`m4inc')dnl
sinclude(`nosuchfile')dnl
after
M4EOF
	cat > m12 <<'M4EOF'
one
m4exit(3)
never printed
M4EOF
	cat > m13 <<'M4EOF'
errprint(`to stderr
')dnl
define(`a',`1')define(`b',`2')dnl
a b
changequote(`[[', `]]')dnl
[[quoted with a and b]] a
changequote(`', `')dnl
a
M4EOF
	cat > m14 <<'M4EOF'
define(`x', `line1
line2')dnl
x
substr(`abcdef', 2, 100)
eval(10/3) eval(-10/3)
ifelse(a,b,c)
ifelse(a,b,c,d,e,f)
ifelse(a,b,c,d,e,f,g)
M4EOF

	for f in m1 m2 m3 m4f m5 m6 m7 m8 m9 m10 m11 m12 m13 m14; do
		a=$( . "$BT"; m4 "$f" 2>/dev/null; echo "rc=$?" )
		b=$( "$RM4" "$f" 2>/dev/null; echo "rc=$?" )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "m4 $f"; fi
	done

	a=$( . "$BT"; m4 m13 2>&1 > /dev/null )
	b=$( "$RM4" m13 2>&1 > /dev/null )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "m4 errprint: [$a] vs [$b]"; fi

	a=$( . "$BT"; m4 < m1 2>/dev/null )
	b=$( "$RM4" < m1 2>/dev/null )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "m4 reading standard input"; fi
	a=$( . "$BT"; m4 m4inc m4inc 2>/dev/null )
	b=$( "$RM4" m4inc m4inc 2>/dev/null )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "m4 over two files"; fi
	a=$( . "$BT"; m4 nosuchfile 2>/dev/null; echo "rc=$?" )
	b=$( "$RM4" nosuchfile 2>/dev/null; echo "rc=$?" )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "m4 on a missing file"; fi
	printf 'FOO BAR BAZ\n' > m15
	a=$( . "$BT"; m4 -DFOO=1 -DBAR -UBAZ m15 2>/dev/null )
	b=$( "$RM4" -DFOO=1 -DBAR -UBAZ m15 2>/dev/null )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "m4 -D and -U"; fi

	cd .. || exit 1
fi

# --- iconv ------------------------------------------------------------------
# Every character set against every other, in both directions, plus input that
# is not valid in the set it claims to be.
echo "### iconv"
if command -v iconv > /dev/null 2>&1; then
	RICONV=$(real_of iconv)
	sets="UTF-8 ASCII ISO-8859-1 ISO-8859-15 CP1252 UTF-16 UTF-16LE UTF-16BE
	      UTF-32 UTF-32LE UTF-32BE"
	printf 'Hi \303\251\303\274\303\237 \342\202\254 \360\237\230\200 plain\n' > ic.utf8
	for t in $sets; do
		"$RICONV" -c -f UTF-8 -t "$t" < ic.utf8 > "ic.$t" 2>/dev/null
	done
	printf 'ok \377\376 bad \303\n' > ic.bad
	printf 'a\342\202' > ic.trunc
	for f in $sets; do
		for t in $sets; do
			for o in "" -c; do
				# shellcheck disable=SC2086
				a=$( . "$BT"; iconv $o -f "$f" -t "$t" < "ic.$f" 2>/dev/null | od -An -tx1; )
				# shellcheck disable=SC2086
				ra=$( . "$BT"; iconv $o -f "$f" -t "$t" < "ic.$f" > /dev/null 2>&1; echo $? )
				# shellcheck disable=SC2086
				b=$( "$RICONV" $o -f "$f" -t "$t" < "ic.$f" 2>/dev/null | od -An -tx1 )
				# shellcheck disable=SC2086
				rb=$( "$RICONV" $o -f "$f" -t "$t" < "ic.$f" > /dev/null 2>&1; echo $? )
				if [ "$a" = "$b" ] && [ "$ra" = "$rb" ]; then pass=$((pass + 1))
				else note_fail "iconv $f -> $t $o (rc $ra vs $rb)"; fi
			done
		done
	done
	for f in $sets; do
		for src in ic.bad ic.trunc; do
			for o in "" -c -s -cs; do
				# shellcheck disable=SC2086
				a=$( . "$BT"; iconv $o -f "$f" -t UTF-8 < "$src" 2>/dev/null | od -An -tx1 )
				# shellcheck disable=SC2086
				ra=$( . "$BT"; iconv $o -f "$f" -t UTF-8 < "$src" > /dev/null 2>&1; echo $? )
				# shellcheck disable=SC2086
				b=$( "$RICONV" $o -f "$f" -t UTF-8 < "$src" 2>/dev/null | od -An -tx1 )
				# shellcheck disable=SC2086
				rb=$( "$RICONV" $o -f "$f" -t UTF-8 < "$src" > /dev/null 2>&1; echo $? )
				if [ "$a" = "$b" ] && [ "$ra" = "$rb" ]; then pass=$((pass + 1))
				else note_fail "iconv $src as $f $o (rc $ra vs $rb)"; fi
			done
		done
	done
	a=$( . "$BT"; iconv -f UTF-8 -t ISO-8859-15 ic.utf8 2>/dev/null | od -An -tx1 )
	b=$( "$RICONV" -f UTF-8 -t ISO-8859-15 ic.utf8 2>/dev/null | od -An -tx1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "iconv naming a file"; fi
	( . "$BT"; iconv -f NOSUCHSET -t UTF-8 < ic.utf8 ) > /dev/null 2>&1; a=$?
	"$RICONV" -f NOSUCHSET -t UTF-8 < ic.utf8 > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "iconv on an unknown set ($a vs $b)"; fi
	a=$( . "$BT"; iconv -l 2>/dev/null | wc -l )
	if [ "$a" -ge 10 ]; then pass=$((pass + 1)); else note_fail "iconv -l should list what it knows"; fi
fi

# --- ar ---------------------------------------------------------------------
# Archives are compared byte for byte against the ones the real ar writes,
# which is possible because ar now defaults to putting zeroes in the date and
# owner fields -- the very fields a shell has no way to fill in.
echo "### ar"
if command -v ar > /dev/null 2>&1; then
	RAR=$(real_of ar)
	mkdir -p art
	cd art || exit 1
	printf 'hello file one\n' > a1
	printf 'second\n' > a2
	printf 'third file contents here\n' > a3
	printf 'odd' > aodd
	printf 'x\n' > a-very-long-member-name
	head -c 300 /dev/urandom > abin

	arboth() {	# arboth key args... with @ standing in for the archive
		local key=$1 i
		shift
		local -a oa=() ra=()
		for i in "$@"; do
			case $i in
			@)	oa+=(ours.a); ra+=(ref.a) ;;
			*)	oa+=("$i"); ra+=("$i") ;;
			esac
		done
		( . "$BT"; ar "$key" "${oa[@]}" ) > /dev/null 2>&1
		"$RAR" "$key" "${ra[@]}" > /dev/null 2>&1
		if cmp -s ours.a ref.a; then pass=$((pass + 1))
		else note_fail "ar $key $*"; fi
	}

	rm -f ours.a ref.a; arboth rc @ a1 a2 a3
	rm -f ours.a ref.a; arboth rc @ aodd a2
	rm -f ours.a ref.a; arboth rc @ a-very-long-member-name a1
	rm -f ours.a ref.a; arboth rc @ abin
	rm -f ours.a ref.a; arboth rc @ a1 a2 a3 a-very-long-member-name aodd abin

	"$RAR" rc base.a a1 a2 a3 a-very-long-member-name aodd abin 2>/dev/null
	for spec in "t base.a" "tv base.a" "t base.a a1 a3"; do
		# shellcheck disable=SC2086
		a=$( . "$BT"; ar $spec 2>&1 )
		# shellcheck disable=SC2086
		b=$( "$RAR" $spec 2>&1 )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ar $spec"; fi
	done
	a=$( . "$BT"; ar p base.a a2 2>&1 )
	b=$( "$RAR" p base.a a2 2>&1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ar p"; fi
	a=$( . "$BT"; ar p base.a abin | od -An -tx1 )
	b=$( "$RAR" p base.a abin | od -An -tx1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ar p over binary"; fi

	for spec in "d a2" "d abin" "q aodd" "r a1" "m a1" "m a3"; do
		cp base.a ours.a; cp base.a ref.a
		# shellcheck disable=SC2086
		set -- $spec
		key=$1; shift
		( . "$BT"; ar "$key" ours.a "$@" ) > /dev/null 2>&1
		"$RAR" "$key" ref.a "$@" > /dev/null 2>&1
		if cmp -s ours.a ref.a; then pass=$((pass + 1)); else note_fail "ar $spec"; fi
	done
	for spec in "rb a2" "ra a2" "ri a3"; do
		cp base.a ours.a; cp base.a ref.a
		# shellcheck disable=SC2086
		set -- $spec
		key=$1; shift
		( . "$BT"; ar "$key" "$1" ours.a a1 ) > /dev/null 2>&1
		"$RAR" "$key" "$1" ref.a a1 > /dev/null 2>&1
		if cmp -s ours.a ref.a; then pass=$((pass + 1)); else note_fail "ar $spec"; fi
	done

	rm -rf xo xr
	mkdir -p xo xr
	( cd xo && . "$BT"; ar x ../base.a ) > /dev/null 2>&1
	( cd xr && "$RAR" x ../base.a ) > /dev/null 2>&1
	n=0
	for f in a1 a2 a3 a-very-long-member-name aodd abin; do
		cmp -s "xo/$f" "xr/$f" || n=$((n + 1))
	done
	if [ "$n" = 0 ]; then pass=$((pass + 1)); else note_fail "ar x: $n members differ"; fi

	# the diagnostics, once the program's own name is taken off the front
	rm -f ours.a ref.a
	a=$( . "$BT"; ar r ours.a a1 2>&1 | "$(real_of sed)" 's|^.*/ar:|ar:|;s|ours\.a|A|' )
	b=$( "$RAR" r ref.a a1 2>&1 | "$(real_of sed)" 's|^.*/ar:|ar:|;s|ref\.a|A|' )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ar creating an archive: [$a] vs [$b]"; fi
	( . "$BT"; ar t nosuch.a ) > /dev/null 2>&1
	if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "ar should fail on a missing archive"; fi

	cd .. || exit 1
fi

# --- locale -----------------------------------------------------------------
echo "### locale"
if command -v locale > /dev/null 2>&1; then
	RLOCALE=$(real_of locale)
	a=$( . "$BT"; locale 2>/dev/null )
	b=$( "$RLOCALE" 2>/dev/null )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "locale with no operand"; fi
	a=$( LANG=C; export LANG; . "$BT"; locale 2>/dev/null )
	b=$( LANG=C "$RLOCALE" 2>/dev/null )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "locale with LANG set"; fi
	a=$( LC_CTYPE=C; export LC_CTYPE; . "$BT"; locale 2>/dev/null )
	b=$( LC_CTYPE=C "$RLOCALE" 2>/dev/null )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "locale with a category set"; fi
	a=$( . "$BT"; locale -a 2>/dev/null )
	b=$( "$RLOCALE" -a 2>/dev/null )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "locale -a"; fi
	a=$( . "$BT"; locale -m 2>/dev/null | wc -l )
	if [ "$a" -gt 100 ]; then pass=$((pass + 1)); else note_fail "locale -m should list the charmaps"; fi
	for k in decimal_point thousands_sep grouping int_curr_symbol currency_symbol \
		 mon_decimal_point mon_grouping positive_sign int_frac_digits frac_digits \
		 p_cs_precedes p_sign_posn abday day abmon mon d_t_fmt d_fmt t_fmt \
		 am_pm t_fmt_ampm yesexpr noexpr yesstr nostr charmap; do
		for o in "" -k -ck; do
			# shellcheck disable=SC2086
			a=$( . "$BT"; locale $o "$k" 2>&1 )
			# shellcheck disable=SC2086
			b=$( "$RLOCALE" $o "$k" 2>&1 )
			if [ "$a" = "$b" ]; then pass=$((pass + 1))
			else note_fail "locale $o $k: [$a] vs [$b]"; fi
		done
	done
	a=$( . "$BT"; locale nosuchname 2>&1 | "$(real_of sed)" 's|^.*/locale:|locale:|'; echo "rc=$?" )
	b=$( "$RLOCALE" nosuchname 2>&1 | "$(real_of sed)" 's|^.*/locale:|locale:|'; echo "rc=$?" )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "locale on an unknown name"; fi
fi

# --- nm ---------------------------------------------------------------------
# Object files are compiled on the spot when there is a compiler, and whatever
# object files the machine already has are read as well.
echo "### nm"
if command -v nm > /dev/null 2>&1; then
	RNM=$(real_of nm)
	objs=
	if command -v cc > /dev/null 2>&1; then
		cat > nm1.c <<'CEOF'
#include <stdio.h>
int global_var = 42;
static int static_var = 7;
int uninit_var;
static int static_uninit;
const char *ro_string = "hello";
extern int missing_func(int);
int add(int a, int b) { return a + b + static_var; }
static int helper(void) { return static_uninit; }
int main(void) { printf("%d\n", add(global_var, helper())); return missing_func(1); }
CEOF
		cat > nm2.c <<'CEOF'
__attribute__((weak)) int weak_func(void) { return 1; }
__attribute__((weak)) int weak_var = 3;
const int const_var = 5;
const char msg[] = "readonly";
extern int und_var;
int use(void) { return und_var + const_var + msg[0]; }
CEOF
		cat > nm3.c <<'CEOF'
#include <stdio.h>
static int s = 1;
int g = 2;
int f(void) { return s; }
int main(void) { printf("%d %d\n", g, f()); return 0; }
CEOF
		cc -c -o nm1.o nm1.c 2>/dev/null && objs="$objs nm1.o"
		cc -c -o nm2.o nm2.c 2>/dev/null && objs="$objs nm2.o"
		cc -o nmprog nm3.c 2>/dev/null && objs="$objs nmprog"
	fi
	for f in /usr/lib/x86_64-linux-gnu/crt1.o /usr/lib/x86_64-linux-gnu/Scrt1.o \
		 /usr/lib/gcc/x86_64-linux-gnu/*/crtbegin.o; do
		[ -f "$f" ] && objs="$objs $f"
	done
	if [ -n "$objs" ]; then
		for f in $objs; do
			for o in "" -a -n -P -g -u -p "-t d" "-t o" -A "-P -t d" -an -Pg -au; do
				# shellcheck disable=SC2086
				a=$( . "$BT"; nm $o "$f" 2>&1 | "$(real_of sed)" 's|^.*/nm:|nm:|' )
				# shellcheck disable=SC2086
				b=$( "$RNM" $o "$f" 2>&1 | "$(real_of sed)" 's|^.*/nm:|nm:|' )
				if [ "$a" = "$b" ]; then pass=$((pass + 1))
				else note_fail "nm $o $f"; fi
			done
		done
		# several files at once, which changes the headings
		set -- $objs
		if [ "$#" -ge 2 ]; then
			a=$( . "$BT"; nm "$1" "$2" 2>&1 )
			b=$( "$RNM" "$1" "$2" 2>&1 )
			if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "nm over two files"; fi
		fi
	fi
	a=$( . "$BT"; nm nm1.c 2>&1 | "$(real_of sed)" 's|^.*/nm:|nm:|'; echo "rc=$?" )
	b=$( "$RNM" nm1.c 2>&1 | "$(real_of sed)" 's|^.*/nm:|nm:|'; echo "rc=$?" )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "nm on something that is not an object"; fi
	if [ -f /bin/true ]; then
		a=$( . "$BT"; nm /bin/true 2>&1 | "$(real_of sed)" 's|^.*/nm:|nm:|' )
		b=$( "$RNM" /bin/true 2>&1 | "$(real_of sed)" 's|^.*/nm:|nm:|' )
		if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "nm on a stripped binary"; fi
	fi
fi

# --- the SCCS utilities -----------------------------------------------------
# Nothing on this machine has an SCCS to compare against, so these are held to
# the property that matters: whatever went in has to come back out. A file is
# put under SCCS, edited and delta'd several times over, and then every version
# it ever had is retrieved and compared with what was recorded at the time.
echo "### admin delta get prs rmdel sact unget val sccs"
mkdir -p sccst
cd sccst || exit 1

for seed in 1 2 3 4 5 6 7 8; do
	rm -rf "r$seed"
	mkdir "r$seed"
	cd "r$seed" || exit 1
	RANDOM=$seed
	: > w.txt
	n=$(( 3 + RANDOM % 12 ))
	i=1
	while [ "$i" -le "$n" ]; do
		printf 'line %d value %d\n' "$i" "$((RANDOM % 9))" >> w.txt
		i=$((i + 1))
	done
	cp w.txt v1.txt
	( . "$BT"; admin -iw.txt s.w.txt ) > /dev/null 2>&1
	vers=1
	for round in 1 2 3 4; do
		( . "$BT"; get -e -s s.w.txt ) > /dev/null 2>&1
		: > tmp.txt
		while IFS= read -r ln; do
			r=$(( RANDOM % 6 ))
			[ "$r" = 0 ] && continue
			[ "$r" = 1 ] && printf 'INSERT-%d-%d\n' "$round" "$RANDOM" >> tmp.txt
			printf '%s\n' "$ln" >> tmp.txt
		done < w.txt
		[ $(( RANDOM % 2 )) = 0 ] && printf 'TAIL-%d\n' "$round" >> tmp.txt
		cp tmp.txt w.txt
		vers=$((vers + 1))
		cp w.txt "v$vers.txt"
		( . "$BT"; delta -y"round $round" s.w.txt ) > /dev/null 2>&1
	done
	bad=0
	v=1
	while [ "$v" -le "$vers" ]; do
		rm -f w.txt
		( . "$BT"; get -s -r"1.$v" s.w.txt ) > /dev/null 2>&1
		cmp -s w.txt "v$v.txt" || bad=$((bad + 1))
		v=$((v + 1))
	done
	( . "$BT"; val s.w.txt ) > /dev/null 2>&1 || bad=$((bad + 1))
	if [ "$bad" = 0 ]; then pass=$((pass + 1))
	else note_fail "sccs round trip (seed $seed): $bad of $vers versions wrong"; fi
	cd .. || exit 1
done

# the pieces, one at a time
rm -rf one
mkdir one
cd one || exit 1
printf 'alpha\nbravo\ncharlie\n' > m.txt
( . "$BT"; admin -im.txt s.m.txt ) > /dev/null 2>&1
if [ -s s.m.txt ]; then pass=$((pass + 1)); else note_fail "admin should create the SCCS file"; fi
a=$( "$(real_of sed)" -n '1p' s.m.txt | "$(real_of tr)" -d '\001' )
case $a in
h[0-9][0-9][0-9][0-9][0-9])	pass=$((pass + 1)) ;;
*)				note_fail "admin should write a checksum line: [$a]" ;;
esac
( . "$BT"; val s.m.txt ) > /dev/null 2>&1
if [ "$?" = 0 ]; then pass=$((pass + 1)); else note_fail "val should accept a fresh SCCS file"; fi
( . "$BT"; val nosuch.txt ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "val should refuse a name that is not an SCCS name"; fi
a=$( . "$BT"; val s.m.txt -r9.9 > /dev/null 2>&1; echo $? )
if [ "$a" -ne 0 ]; then pass=$((pass + 1)); else note_fail "val should refuse an SID that is not there"; fi

rm -f m.txt
a=$( . "$BT"; get s.m.txt 2>&1 )
if [ "$a" = "$(printf '1.1\n3 lines')" ]; then pass=$((pass + 1))
else note_fail "get should report the SID and the count: [$a]"; fi
if [ "$(cat m.txt)" = "$(printf 'alpha\nbravo\ncharlie')" ]; then pass=$((pass + 1))
else note_fail "get should write the file back"; fi

a=$( . "$BT"; get -e s.m.txt 2>&1 )
if [ "$a" = "$(printf '1.1\nnew delta 1.2\n3 lines')" ]; then pass=$((pass + 1))
else note_fail "get -e should announce the new delta: [$a]"; fi
a=$( . "$BT"; sact s.m.txt 2>&1 )
case $a in
"1.1 1.2 "*)	pass=$((pass + 1)) ;;
*)		note_fail "sact should report the pending edit: [$a]" ;;
esac
( . "$BT"; unget s.m.txt ) > /dev/null 2>&1
a=$( . "$BT"; sact s.m.txt 2>&1 )
case $a in
*"no edits pending")	pass=$((pass + 1)) ;;
*)			note_fail "unget should clear the pending edit: [$a]" ;;
esac

( . "$BT"; get -e -s s.m.txt ) > /dev/null 2>&1
printf 'alpha\nBRAVO\ncharlie\ndelta\n' > m.txt
a=$( . "$BT"; delta -y'a change' s.m.txt 2>&1 )
if [ "$a" = "$(printf '1.2\n2 inserted\n1 deleted\n2 unchanged')" ]; then pass=$((pass + 1))
else note_fail "delta should count what changed: [$a]"; fi
rm -f m.txt
( . "$BT"; get -s s.m.txt ) > /dev/null 2>&1
if [ "$(cat m.txt)" = "$(printf 'alpha\nBRAVO\ncharlie\ndelta')" ]; then pass=$((pass + 1))
else note_fail "get should hand back what delta recorded"; fi
rm -f m.txt
( . "$BT"; get -s -r1.1 s.m.txt ) > /dev/null 2>&1
if [ "$(cat m.txt)" = "$(printf 'alpha\nbravo\ncharlie')" ]; then pass=$((pass + 1))
else note_fail "get -r should hand back the older version"; fi
a=$( . "$BT"; get -p -s -r1.1 s.m.txt 2>/dev/null )
if [ "$a" = "$(printf 'alpha\nbravo\ncharlie')" ]; then pass=$((pass + 1))
else note_fail "get -p should write to standard output"; fi

a=$( . "$BT"; prs -d':I: :P:' s.m.txt 2>&1 )
case $a in
"1.2 "*)	pass=$((pass + 1)) ;;
*)		note_fail "prs -d should expand the data specification: [$a]" ;;
esac
a=$( . "$BT"; prs -e s.m.txt 2>&1 | "$(real_of grep)" -c '^D 1\.' )
if [ "$a" = 2 ]; then pass=$((pass + 1)); else note_fail "prs -e should report both deltas"; fi

( . "$BT"; rmdel -r1.2 s.m.txt ) > /dev/null 2>&1
a=$( . "$BT"; prs -d:I: s.m.txt 2>&1 )
if [ "$a" = 1.1 ]; then pass=$((pass + 1)); else note_fail "rmdel should take the newest delta away: [$a]"; fi
rm -f m.txt
( . "$BT"; get -s s.m.txt ) > /dev/null 2>&1
if [ "$(cat m.txt)" = "$(printf 'alpha\nbravo\ncharlie')" ]; then pass=$((pass + 1))
else note_fail "what is left after rmdel should be the older text"; fi
( . "$BT"; val s.m.txt ) > /dev/null 2>&1
if [ "$?" = 0 ]; then pass=$((pass + 1)); else note_fail "val should still accept the file after rmdel"; fi

# a checksum that no longer matches is what val is for
"$(real_of sed)" '$a tampered' s.m.txt > s.bad.txt
( . "$BT"; val s.bad.txt ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "val should notice a file that was meddled with"; fi

# the front end, which finds the SCCS directory itself
mkdir -p SCCS
printf 'one\ntwo\n' > front.txt
( . "$BT"; sccs create -ifront.txt front.txt ) > /dev/null 2>&1
if [ -s SCCS/s.front.txt ]; then pass=$((pass + 1)); else note_fail "sccs create should make SCCS/s.front.txt"; fi
rm -f front.txt
a=$( . "$BT"; sccs get front.txt 2>&1 )
if [ "$a" = "$(printf '1.1\n2 lines')" ]; then pass=$((pass + 1))
else note_fail "sccs get should retrieve through the front end: [$a]"; fi
a=$( . "$BT"; sccs cat front.txt 2>/dev/null )
if [ "$a" = "$(printf 'one\ntwo')" ]; then pass=$((pass + 1))
else note_fail "sccs cat should print the file: [$a]"; fi
( . "$BT"; sccs nosuchcommand front.txt ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "sccs should refuse a command it does not have"; fi

cd .. || exit 1
cd .. || exit 1

# --- compress, uncompress, zcat ---------------------------------------------
# Nothing here writes the .Z format any more, but gzip still reads it, so what
# compress produces is handed to gzip to check; uncompress is then asked to read
# it back, and to read a stream this suite builds for itself.
echo "### compress uncompress zcat"
mkdir -p zt
cd zt || exit 1
printf 'a\n' > z1
head -c 3000 /dev/urandom > z2
i=1
: > z3
while [ "$i" -le 200 ]; do
	printf 'line %d of some text with repetition repetition\n' "$i" >> z3
	i=$((i + 1))
done
i=1
: > z4
while [ "$i" -le 500 ]; do printf 'aaaaaaaaaabbbbbbbbbb' >> z4; i=$((i + 1)); done
i=1
: > z5
while [ "$i" -le 400 ]; do
	printf 'a longer line number %d with some words and %d numbers\n' "$i" "$((i * 7))" >> z5
	i=$((i + 1))
done
: > z6
printf '' > z6

for f in z1 z2 z3 z4 z5 z6; do
	for b in 9 10 12 14 16; do
		( . "$BT"; compress -b "$b" -c "$f" ) > zc.Z 2>/dev/null
		if command -v gzip > /dev/null 2>&1; then
			if "$(real_of gzip)" -dc < zc.Z > zg.out 2>/dev/null && cmp -s "$f" zg.out
			then pass=$((pass + 1))
			else note_fail "compress -b$b $f is not what gzip reads back"; fi
		fi
		( . "$BT"; uncompress -c zc.Z ) > zu.out 2>/dev/null
		if cmp -s "$f" zu.out; then pass=$((pass + 1))
		else note_fail "compress -b$b $f does not survive uncompress"; fi
		a=$( . "$BT"; zcat zc.Z 2>/dev/null | wc -c )
		if [ "$a" = "$(wc -c < "$f")" ]; then pass=$((pass + 1))
		else note_fail "zcat -b$b $f"; fi
	done
done

# a file rather than a pipe, and the suffix rules that go with it
cp z3 zf
( . "$BT"; compress zf ) > /dev/null 2>&1
if [ -s zf.Z ]; then pass=$((pass + 1)); else note_fail "compress should write zf.Z"; fi
( . "$BT"; uncompress -c zf.Z ) > zu.out 2>/dev/null
if cmp -s z3 zu.out; then pass=$((pass + 1)); else note_fail "the file compress wrote does not read back"; fi
( . "$BT"; uncompress -f zf.Z ) > /dev/null 2>&1
if cmp -s z3 zf; then pass=$((pass + 1)); else note_fail "uncompress should write the file back"; fi
( . "$BT"; compress -c z3 ) 2>/dev/null | ( . "$BT"; uncompress -c ) > zu.out 2>/dev/null
if cmp -s z3 zu.out; then pass=$((pass + 1)); else note_fail "compress into uncompress down a pipe"; fi
printf 'not compressed at all\n' > znot
( . "$BT"; uncompress -c znot ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "uncompress should refuse what is not compressed"; fi
( . "$BT"; compress -b 20 -c z1 ) > /dev/null 2>&1
if [ "$?" -ne 0 ]; then pass=$((pass + 1)); else note_fail "compress should refuse 20 bits"; fi

cd .. || exit 1

# --- bc ---------------------------------------------------------------------
# Every expression is put to both calculators and the answers compared, digit
# for digit.  The library behind -l is written in bc itself and read by the same
# parser as everything else, so it is checked the same way.
echo "### bc"
if command -v bc > /dev/null 2>&1; then
	RBC=$(real_of bc)
	bcchk() {	# bcchk expression [-l]
		local a b
		a=$( printf '%s\n' "$1" | ( . "$BT"; bc $2 ) 2>&1 )
		b=$( printf '%s\n' "$1" | "$RBC" $2 2>&1 )
		if [ "$a" = "$b" ]; then pass=$((pass + 1))
		else note_fail "bc $2 [$1]: [$a] not [$b]"; fi
	}

	bcchk '1+2'
	bcchk '2*3+4'
	bcchk '10/3'
	bcchk 'scale=3; 10/3'
	bcchk 'scale=10; 1/7'
	bcchk 'scale=20; 1/3*3'
	bcchk '2^10'
	bcchk '2^200'
	bcchk 'scale=10; 2^-3'
	bcchk '-2^2'
	bcchk '1.5*1.5'
	bcchk '100000000000000000000 + 1'
	bcchk '99999999999999999999 * 99999999999999999999'
	bcchk 'scale=5; 22/7'
	bcchk 'scale=0; 22/7'
	bcchk '10 % 3'
	bcchk 'scale=5; 10 % 3'
	bcchk 'scale=5; 1 % 6.28318'
	bcchk '-10 % 3'
	bcchk 'sqrt(16)'
	bcchk 'scale=30; sqrt(2)'
	bcchk 'scale=10; sqrt(1000)'
	bcchk 'length(12345)'
	bcchk 'length(0.001)'
	bcchk 'scale(1.234)'
	bcchk 'scale=20; scale'
	bcchk 'x=5; x*2'
	bcchk 'x=3; x+=4; x'
	bcchk 'x=3; x*=4; x'
	bcchk 'x=10; x/=4; x'
	bcchk 'y=5; y++; y'
	bcchk 'y=5; y--; y'
	bcchk '++x'
	bcchk 'x[0]=1; x[1]=2; x[0]+x[1]'
	bcchk 'if (1 < 2) 42'
	bcchk 'if (0) 1 else 2'
	bcchk 'i=0; while (i<3) { i; i=i+1 }'
	bcchk 'for (i=0;i<3;i++) i'
	bcchk 'for (i=1;i<=5;i++) { if (i==3) continue; i }'
	bcchk 'for (i=1;i<=5;i++) { if (i==3) break; i }'
	bcchk 'define f(x) { return (x*x) } f(7)'
	bcchk 'define g(a,b) { auto c; c=a+b; return (c*2) } g(3,4)'
	bcchk 'define f(n) { if (n<2) return (1); return (n*f(n-1)) } f(10)'
	bcchk '"hello"'
	bcchk '1==1'
	bcchk '3<2'
	bcchk '(2+3)*4'
	bcchk 'ibase=16; FF'
	bcchk 'obase=16; 255'
	bcchk 'obase=2; 10'
	bcchk '/* a comment */ 7'
	bcchk 'quit'
	bcchk '1;quit;2'
	bcchk 'x'

	# the library, at a scale that does not take all afternoon
	bcchk 'scale=10; a(1)' -l
	bcchk 'scale=10; e(1)' -l
	bcchk 'scale=10; l(2)' -l
	bcchk 'scale=10; s(1)' -l
	bcchk 'scale=10; c(1)' -l
	bcchk 'scale=10; e(l(5))' -l
	bcchk 'a(1)' -l
fi

# --- make -------------------------------------------------------------------
# Compared against the real make with -r, so that both start from the same
# (empty) set of built-in rules and only what the makefile says counts.
echo "### make"
if command -v make > /dev/null 2>&1; then
	RMAKE=$(real_of make)
	mkdir -p mkt
	cd mkt || exit 1

	MKCLEAN=
	mkchk() {	# mkchk description makefile-name [args...]
		local desc=$1 mf=$2 a b
		shift 2
		# both sides must start from the same files, or whichever runs
		# first leaves the other with nothing to do
		# shellcheck disable=SC2086
		[ -n "$MKCLEAN" ] && rm -f $MKCLEAN
		# shellcheck disable=SC2086
		a=$( . "$BT"; make -r -f "$mf" "$@" 2>&1 |
		     "$(real_of sed)" 's/\[[^]]*\]/[T]/'; echo "rc=${PIPESTATUS[0]}" )
		# shellcheck disable=SC2086
		[ -n "$MKCLEAN" ] && rm -f $MKCLEAN
		# shellcheck disable=SC2086
		b=$( "$RMAKE" -r -f "$mf" "$@" 2>&1 |
		     "$(real_of sed)" 's/\[[^]]*\]/[T]/'; echo "rc=${PIPESTATUS[0]}" )
		if [ "$a" = "$b" ]; then pass=$((pass + 1))
		else note_fail "make -f $mf $*: [$a] not [$b]"; fi
	}

	cat > mf1 <<'MKEOF'
CC = echo cc
OBJS = a.o b.o

all: prog
	@echo done $(OBJS)

prog: $(OBJS)
	$(CC) -o prog $(OBJS)

a.o: a.c
	$(CC) -c a.c

b.o: b.c
	$(CC) -c b.c
MKEOF
	touch a.c b.c
	mkchk "a small build" mf1
	mkchk "the same build, not run" mf1 -n
	mkchk "one target of it" mf1 a.o
	mkchk "silently" mf1 -s

	cat > mf2 <<'MKEOF'
out: a b
	@echo target=$@ first=$< newer=$? stem=$*
MKEOF
	touch a b
	mkchk "the internal macros" mf2

	cat > mf3 <<'MKEOF'
.SUFFIXES: .in .out

all: x.out

.in.out:
	@echo making $@ from $< stem $*
	cp $< $@
MKEOF
	printf 'data\n' > x.in
	rm -f x.out
	( . "$BT"; make -r -f mf3 ) > /dev/null 2>&1
	cp -f x.out mkours 2>/dev/null
	rm -f x.out
	"$RMAKE" -r -f mf3 > /dev/null 2>&1
	if cmp -s mkours x.out; then pass=$((pass + 1))
	else note_fail "make should make x.out from x.in"; fi
	rm -f x.out
	MKCLEAN=x.out
	mkchk "an inference rule" mf3
	MKCLEAN=

	cat > mf4 <<'MKEOF'
.SUFFIXES:
.SUFFIXES: .p .q

SRC = one.p two.p
OBJ = $(SRC:.p=.q)

all: $(OBJ)
	@echo built $(OBJ)

.p.q:
	@echo compiling $< to $@
	cp $< $@
MKEOF
	printf 'p1\n' > one.p
	printf 'p2\n' > two.p
	rm -f one.q two.q
	MKCLEAN="one.q two.q"
	mkchk "substitution in a macro" mf4
	MKCLEAN=
	rm -f one.q two.q

	cat > mf5 <<'MKEOF'
X = one
Y += first
Y += second
show:
	@echo X=$(X) Y=$(Y) Z=$(Z)
MKEOF
	mkchk "macros" mf5
	mkchk "a macro from the command line" mf5 X=two
	Z=fromenv; export Z
	mkchk "a macro from the environment" mf5
	mkchk "the environment winning with -e" mf5 -e
	unset Z

	cat > mf6 <<'MKEOF'
bad:
	false
	@echo not reached

ignored:
	-false
	@echo reached

quiet:
	@false
	@echo after
MKEOF
	mkchk "a command that fails" mf6 bad
	mkchk "a failure that is ignored" mf6 ignored
	mkchk "failing quietly" mf6 quiet
	mkchk "ignoring every failure" mf6 -i bad

	cat > mf7 <<'MKEOF'
all: t1 t2
t1:
	@echo t1; false
t2:
	@echo t2
MKEOF
	mkchk "stopping at the first error" mf7
	mkchk "carrying on past it" mf7 -k

	cat > mf8 <<'MKEOF'
LONG = one \
       two \
       three

all:; @echo $(LONG)
MKEOF
	mkchk "a line that carries on" mf8
	mkchk "a command on the rule line" mf8

	cat > mf9 <<'MKEOF'
all: made
	@echo all
made:
	@echo making
MKEOF
	mkchk "a target with no file" mf9
	mkchk "asking for a target that is not there" mf9 nosuch

	# a real build, twice over, to see that the second time nothing happens
	cat > mfa <<'MKEOF'
out.txt: in1.txt in2.txt
	cat in1.txt in2.txt > out.txt
MKEOF
	printf 'one\n' > in1.txt
	printf 'two\n' > in2.txt
	rm -f out.txt
	a=$( . "$BT"; make -r -f mfa 2>&1; make -r -f mfa 2>&1; echo "rc=$?" )
	cp -f out.txt mkours 2>/dev/null
	rm -f out.txt
	b=$( "$RMAKE" -r -f mfa 2>&1; "$RMAKE" -r -f mfa 2>&1; echo "rc=$?" )
	if [ "$a" = "$b" ] && cmp -s mkours out.txt; then pass=$((pass + 1))
	else note_fail "make twice over: [$a] not [$b]"; fi

	mkdir -p mkempty
	( cd mkempty && . "$BT"; make -r ) > /dev/null 2>&1; a=$?
	( cd mkempty && "$RMAKE" -r ) > /dev/null 2>&1; b=$?
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "make with no makefile ($a vs $b)"; fi

	# -q asks the question without doing the work, -t answers it by moving
	# the timestamps
	cat > mfq <<'MKEOF'
all: q.out
	@echo all

q.out: q.in
	cat q.in > q.out
MKEOF
	mkq() {	# mkq description [args...]
		local desc=$1 a b
		shift
		rm -f q.out; printf 'in\n' > q.in
		a=$( . "$BT"; make -r -f mfq "$@" 2>&1; echo "rc=$?" )
		rm -f q.out; printf 'in\n' > q.in
		b=$( "$RMAKE" -r -f mfq "$@" 2>&1; echo "rc=$?" )
		if [ "$a" = "$b" ]; then pass=$((pass + 1))
		else note_fail "make $*: [$a] not [$b]"; fi
	}
	mkq "asking whether it is up to date" -q
	mkq "touching instead of building" -t
	mkq "touching quietly" -t -s

	# -t leaves the file it touches alone
	printf 'keep\nthis\n' > q.out
	printf 'in\n' > q.in
	( . "$BT"; make -r -f mfq -t q.out ) > /dev/null 2>&1
	if [ "$( cat q.out )" = "keep
this" ]; then pass=$((pass + 1)); else note_fail "make -t changed the file"; fi
	rm -f q.out; printf 'in\n' > q.in
	( . "$BT"; make -r -f mfq -t q.out ) > /dev/null 2>&1
	a=$( . "$BT"; make -r -f mfq -q q.out > /dev/null 2>&1; echo $? )
	if [ "$a" = 0 ]; then pass=$((pass + 1)); else note_fail "make -t did not bring the target up to date"; fi

	# -p writes out what it read: every macro and every rule
	a=$( . "$BT"; make -r -f mfq -q -p 2>&1 )
	case $a in
	*"# Macros"*"# Targets"*"all: q.out"*"q.out: q.in"*)
		pass=$((pass + 1)) ;;
	*)	note_fail "make -p: [$a]" ;;
	esac

	cd .. || exit 1
fi


# --- awk --------------------------------------------------------------------
# Compared against the system awk, program by program: the output of both, and
# the exit status.  Where the standard and this machine's awk disagree the
# answer is checked against the standard instead.
echo "### awk"
if command -v awk > /dev/null 2>&1; then
	RAWK=$(real_of awk)
	mkdir -p awkt
	cd awkt || exit 1

	printf 'a b c\n1 2 3\nx  y   z\n10 -3 4.5\n' > w1
	printf 'alice 30 engineer\nbob 25 doctor\ncarol 35 artist\n' > w2
	printf 'x,1\ny,2\nz,3\n' > w3
	printf 'one\n\ntwo\nthree\n\n\nfour\n' > w4

	awkin() {	# awkin program input-file
		local prog=$1 in=$2 a b
		a=$( . "$BT"; awk "$prog" < "$in" 2>&1; echo "rc=$?" )
		b=$( "$RAWK" "$prog" < "$in" 2>&1; echo "rc=$?" )
		if [ "$a" = "$b" ]; then pass=$((pass + 1))
		else note_fail "awk [$prog]: [$a] not [$b]"; fi
	}
	awkarg() {	# awkarg argument...
		local a b
		a=$( . "$BT"; awk "$@" < /dev/null 2>&1; echo "rc=$?" )
		b=$( "$RAWK" "$@" < /dev/null 2>&1; echo "rc=$?" )
		if [ "$a" = "$b" ]; then pass=$((pass + 1))
		else note_fail "awk $*: [$a] not [$b]"; fi
	}
	awkis() {	# awkis expected program [input-file]
		local want=$1 prog=$2 in=${3-/dev/null} a
		a=$( . "$BT"; awk "$prog" < "$in" 2>/dev/null )
		if [ "$a" = "$want" ]; then pass=$((pass + 1))
		else note_fail "awk [$prog]: [$a] not [$want]"; fi
	}

	# arithmetic and numbers
	awkarg 'BEGIN{print 1+1, 2*3, 7/2, 7%3, 2^10, -2^2}'
	awkarg 'BEGIN{print 1/3, 2/3, 1e10, 1e-7}'
	awkarg 'BEGIN{print 10%3, -10%3, 10%-3, 10.5%3}'
	awkarg 'BEGIN{print int(3.9), int(-3.9), sqrt(16), 2^31, 2^53}'
	awkarg 'BEGIN{printf "%.6f %.6f %.6f %.6f\n", sin(1), cos(1), exp(1), log(10)}'
	awkarg 'BEGIN{printf "%.6f %.6f\n", atan2(1,1), atan2(-1,-1)}'
	awkarg 'BEGIN{x="3x"; print x+1, "10"+5, "abc"+0, "010"+0}'
	awkarg 'BEGIN{print 2147483647+1, int(2^31), 07, 010}'

	# strings
	awkarg 'BEGIN{print length("hello"), substr("hello",2,3), substr("hello",4), index("hello","ll")}'
	awkarg 'BEGIN{print toupper("aBc"), tolower("aBc"), index("", "a"), index("a", "")}'
	awkarg 'BEGIN{s="hello world"; n=gsub(/o/,"0",s); print n, s}'
	awkarg 'BEGIN{s="aaa"; n=sub(/a/,"[&]",s); print n, s}'
	awkarg 'BEGIN{s="abc"; gsub(/x*/,"-",s); print s}'
	awkarg 'BEGIN{print match("foobar", /o+/), RSTART, RLENGTH}'
	awkarg 'BEGIN{print match("x","y"), RSTART, RLENGTH}'
	awkarg 'BEGIN{n=split("a:b:c", arr, ":"); print n, arr[1], arr[3]}'
	awkarg 'BEGIN{n=split("  a  b ", arr); print n, "["arr[1]"]", "["arr[2]"]"}'
	awkarg 'BEGIN{n=split("a1b2c", a, /[0-9]/); print n, a[1], a[3]}'
	awkarg 'BEGIN{print "a.b" ~ /a\.b/, "axb" ~ /a\.b/, "a+b" ~ /a\+b/}'
	awkarg 'BEGIN{s=sprintf("%d-%s", 5, "x"); print s, length(s)}'
	awkarg 'BEGIN{x="a"; x = x x x; print x, length(x)}'

	# printf
	awkarg 'BEGIN{printf "%d|%5.2f|%s|%c|%x|%o|%e\n", 42, 3.14159, "hi", 65, 255, 8, 1234.5}'
	awkarg 'BEGIN{printf "%-5s|%5s|%.3s|%*d\n", "a", "b", "abcdef", 5, 42}'
	awkarg 'BEGIN{printf "%5.1f|%+d|% d|%05d\n", 3.14159, 5, 5, 42}'
	awkarg 'BEGIN{printf "%i %d\n", 3.9, -3.9}'
	awkarg 'BEGIN{printf "%c%c\n", 104, "hi"}'
	awkarg 'BEGIN{printf "%.10f\n", 1/3}'

	# records and fields
	awkin '{print NR, NF, $1, $NF}' w1
	awkin '{ $2 = "X"; print }' w1
	awkin '{ NF = 2; print; print NF }' w1
	awkin '{ $7 = "seven"; print NF; print }' w1
	awkin '{ print $(NF-1) }' w1
	awkin '$1 > 5 { print "big", $1 }' w1
	awkin '/^1/ { print "starts with 1:", $0 }' w1
	awkin '$0 ~ /b/ { print "has b" }' w1
	awkin '!/^a/ { print "no a", $1 }' w1
	awkin 'NR==2, NR==3 { print "range", NR }' w1
	awkin 'END { print NR }' w1
	awkin 'BEGIN{OFS="-"} { $1=$1; print }' w1
	awkin 'BEGIN{FS=":"} {print $2}' w3
	awkin 'BEGIN{FS=","} {print NF, $2}' w3
	awkin 'BEGIN{FS=""} {print NF, $1}' w3
	awkin 'BEGIN{FS="[0-9]+"} {print NF, $2}' w1
	awkin 'BEGIN{RS=""} {print NR": "$0; print "NF="NF}' w4
	awkin 'BEGIN{OFS="|"; ORS="!\n"} { $1=$1; print $1, $2 }' w3
	awkin '{ s+=$1 } END { print s }' w1
	awkin '{ a[NR]=$0 } END { for (i=NR;i>=1;i--) print a[i] }' w1
	awkin '{ printf "%-10s %3d %s\n", $1, $2, toupper($3) }' w2
	awkin '{ if ($2 == 25) next; print $1 }' w2
	awkin '{ print; nextfile }' w2
	awkin 'END { $0 = "x y"; print NF, $2 }' w2

	# arrays, functions, control flow
	awkarg 'BEGIN{a["x"]=1; a["y"]=2; print length(a), ("x" in a), ("z" in a)}'
	awkarg 'BEGIN{a[1]=1; delete a[1]; print (1 in a), length(a)}'
	awkarg 'BEGIN{SUBSEP=":"; a[1,2]=3; for (k in a) print k; print ((1,2) in a)}'
	awkarg 'BEGIN{a[1]=1; a[2]=2; n=0; for (i in a) { delete a[i]; n++ }; print n, length(a)}'
	awkarg 'function f(x) { return x*2 } BEGIN { print f(21) }'
	awkarg 'function fib(n) { return n<2 ? n : fib(n-1)+fib(n-2) } BEGIN { print fib(10) }'
	awkarg 'function g(a,   i) { for (i=1;i<=3;i++) a[i]=i*i } BEGIN { g(arr); print arr[3], length(arr) }'
	awkarg 'function f(a) { a[1] = "changed" } BEGIN { b[1]="orig"; f(b); print b[1] }'
	awkarg 'function f(x) { x = 99 } BEGIN { y = 1; f(y); print y }'
	awkarg 'function cnt(arr) { return length(arr) } BEGIN { split("a b c", z); print cnt(z) }'
	awkarg 'function r(n) { if (n <= 0) return 0; return n + r(n-1) } BEGIN { print r(50) }'
	awkarg 'BEGIN{ while (i<3) { i++; if (i==2) continue; print i } }'
	awkarg 'BEGIN{ do { i++ } while (i<5); print i }'
	awkarg 'BEGIN{ for (i=0;i<3;i++) for (j=0;j<2;j++) s = s i j " "; print s }'
	awkarg 'BEGIN{ print 1; exit 3; print 2 } END { print "end" }'
	awkarg 'BEGIN{ i=5; print i++, i, ++i, i--, i }'
	awkarg 'BEGIN{ x = 5; x += 2; x -= 1; x *= 3; x /= 2; x %= 5; x ^= 2; print x }'
	awkarg 'BEGIN{ print (1>2 ? "a" : "b"), (1==1), (1=="1"), ("a"<"b"), (2<10), ("10"<"9") }'
	awkarg 'BEGIN{ x; print x+0, "["x"]", length(x) }'
	awkarg 'BEGIN{ print 3 == "3", "3" == "3.0", 3 == "3.0" }'
	awkarg 'BEGIN{ n=split("", a); print n, length(a) }'

	# the command line
	awkarg -v 'x=5' 'BEGIN{print x, x+1}'
	awkarg -v 'x=a\tb' 'BEGIN{print x}'
	awkarg -v 'OFS=-' 'BEGIN{print "a","b"}'
	a=$( . "$BT"; awk '{print FILENAME, FNR, NR}' w1 w2 2>&1; echo "rc=$?" )
	b=$( "$RAWK" '{print FILENAME, FNR, NR}' w1 w2 2>&1; echo "rc=$?" )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "awk over two files: [$a] not [$b]"; fi
	a=$( . "$BT"; awk '{print v, $1}' w1 v=9 w2 2>&1 )
	b=$( "$RAWK" '{print v, $1}' w1 v=9 w2 2>&1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "awk with an assignment between files: [$a] not [$b]"; fi
	a=$( . "$BT"; awk 'BEGIN{print ARGC, ARGV[0], ARGV[1]}' w1 w2 2>&1 )
	b=$( "$RAWK" 'BEGIN{print ARGC, ARGV[0], ARGV[1]}' w1 w2 2>&1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "awk ARGV: [$a] not [$b]"; fi
	cat > wprog <<'PEOF'
BEGIN { FS = "," ; total = 0 }
{ total += $2 ; names = names (NR>1 ? "," : "") $1 }
END { printf "%s = %d\n", names, total }
PEOF
	a=$( . "$BT"; awk -f wprog w3 2>&1 )
	b=$( "$RAWK" -f wprog w3 2>&1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "awk -f: [$a] not [$b]"; fi
	a=$( . "$BT"; awk -F: '{print $2}' <<< 'a:b:c' 2>&1 )
	b=$( "$RAWK" -F: '{print $2}' <<< 'a:b:c' 2>&1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "awk -F: [$a] not [$b]"; fi

	# getline, and writing to files
	awkin '{ if ((getline nxt) > 0) print $0 "+" nxt; else print $0 "+EOF" }' w1
	awkin 'NR==1 { while ((getline x) > 0) n++; print n }' w1
	a=$( . "$BT"; awk 'BEGIN { while ((getline l < "w3") > 0) print "got", l }' 2>&1 )
	b=$( "$RAWK" 'BEGIN { while ((getline l < "w3") > 0) print "got", l }' 2>&1 )
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "awk getline from a file: [$a] not [$b]"; fi
	awkarg 'BEGIN { print (getline l < "nosuchfile") }'
	a=$( . "$BT"; awk 'BEGIN { print "x" > "wo"; print "y" >> "wo"; close("wo"); while ((getline l < "wo")>0) print "read", l }' 2>&1 )
	b='read x
read y'
	if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "awk writing and reading back: [$a] not [$b]"; fi

	# where this awk follows the standard and the system awk does not
	awkis 'he' 'BEGIN { print substr("hello", 0, 3) }'
	awkis 'h' 'BEGIN { print substr("hello", -1, 3) }'
	awkis 'a ' 'BEGIN { printf "%s %s\n", "a" }'
	awkis '1' 'BEGIN { print 0.1 + 0.2 == 0.3 }'
	awkis '-1' 'BEGIN { print system("true") }'

	cd .. || exit 1
fi

# --- gencat -----------------------------------------------------------------
# The catalogue is a binary file with a hash table in it, so the test is a
# byte for byte comparison with the system gencat.
echo "### gencat"
if command -v gencat > /dev/null 2>&1; then
	RGEN=$(real_of gencat)
	mkdir -p gct
	cd gct || exit 1

	gcchk() {	# gcchk description msgfile...
		local desc=$1 a b
		shift
		rm -f ga.cat gb.cat
		"$RGEN" ga.cat "$@" > /dev/null 2>&1; a=$?
		( . "$BT"; gencat gb.cat "$@" ) > /dev/null 2>&1; b=$?
		if [ "$a" = "$b" ] &&
		   { cmp -s ga.cat gb.cat ||
		     { [ ! -e ga.cat ] && [ ! -e gb.cat ]; }; }; then
			pass=$((pass + 1))
		else note_fail "gencat $desc ($a vs $b)"; fi
	}

	printf '$set 1\n1 Hello\n2 World\n' > g1.msg
	printf '1 no set given\n2 second message\n' > g2.msg
	printf '$set 1\n1 A\n2 B\n$set 2\n1 C\n' > g3.msg
	printf '$set 5\n1 five\n$set 2\n7 two\n$set 9\n3 nine\n$set 1\n4 one\n' > g4.msg
	printf '$set 1\n1 tab\\there\n2 newline\\nhere\n3 octal\\101\\102\n4 back\\\\slash\n5 unknown \\q escape\n' > g5.msg
	printf '$quote "\n$set 1\n1 "quoted text"\n2 "with \\"inner\\" quotes"\n$quote\n3 "not quoted now"\n' > g6.msg
	printf '$set 1\n1 first part \\\n and the rest\n2 plain\n' > g7.msg
	printf '$ a comment\n$set 1\n1 A\n$ another comment\n2 B\n' > g8.msg
	printf '$set 1\n1 first\n1 second definition\n' > g9.msg
	printf '' > g10.msg
	printf '$set 3\n1 m1\n7 m7\n55 m55\n100 m100\n1000 m1000\n' > g11.msg
	: > g12.msg
	i=1
	{ echo '$set 1'; while [ "$i" -le 60 ]; do echo "$i message number $i"; i=$((i + 1)); done; } > g12.msg

	gcchk "a small catalogue" g1.msg
	gcchk "messages with no set of their own" g2.msg
	gcchk "two sets" g3.msg
	gcchk "sets out of order" g4.msg
	gcchk "escape sequences" g5.msg
	gcchk "quoted messages" g6.msg
	gcchk "a continued line" g7.msg
	gcchk "comments" g8.msg
	gcchk "a repeated message number" g9.msg
	gcchk "an empty source file" g10.msg
	gcchk "sparse message numbers" g11.msg
	gcchk "sixty messages" g12.msg
	gcchk "two source files" g1.msg g3.msg
	gcchk "a source file that is not there" nosuch.msg
	gcchk "one good source and one missing" g1.msg nosuch.msg

	# merging into a catalogue that is already there
	gcmerge() {	# gcmerge description msgfile...
		local desc=$1 a b
		shift
		rm -f ga.cat gb.cat
		for f in "$@"; do
			"$RGEN" ga.cat "$f" > /dev/null 2>&1
			( . "$BT"; gencat gb.cat "$f" ) > /dev/null 2>&1
		done
		if cmp -s ga.cat gb.cat; then pass=$((pass + 1))
		else note_fail "gencat merging $desc"; fi
	}
	printf '$set 2\n1 C\n2 D\n' > gm1.msg
	printf '$set 1\n3 added later\n' > gm2.msg
	printf '$set 1\n1 replaced\n' > gm3.msg
	gcmerge "a new set" g1.msg gm1.msg
	gcmerge "into the same set" g1.msg gm2.msg
	gcmerge "replacing a message" g1.msg gm3.msg
	gcmerge "three times over" g1.msg gm1.msg gm2.msg
	gcmerge "a big one twice" g12.msg g11.msg

	# reading back what was written proves the table can be walked
	rm -f gb.cat
	( . "$BT"; gencat gb.cat g4.msg ) > /dev/null 2>&1
	printf '$set 7\n1 fresh\n' > gm4.msg
	a=$( . "$BT"; gencat gb.cat gm4.msg > /dev/null 2>&1; echo $? )
	rm -f ga.cat
	"$RGEN" ga.cat g4.msg > /dev/null 2>&1
	"$RGEN" ga.cat gm4.msg > /dev/null 2>&1
	if [ "$a" = 0 ] && cmp -s ga.cat gb.cat; then pass=$((pass + 1))
	else note_fail "gencat reading back its own catalogue"; fi

	# where the standard and the system gencat part company
	printf '$set 1\n1 A\n2 B\n$delset 1\n' > gd.msg
	rm -f gb.cat
	( . "$BT"; gencat gb.cat gd.msg ) > /dev/null 2>&1
	if ! od -An -c gb.cat | grep -q '[AB]'; then pass=$((pass + 1))
	else note_fail "gencat: \$delset should empty the set"; fi
	printf '$set 1\n1 A\n2 B\n' > ge1.msg
	printf '$set 1\n1\n' > ge2.msg
	rm -f gb.cat
	( . "$BT"; gencat gb.cat ge1.msg ) > /dev/null 2>&1
	( . "$BT"; gencat gb.cat ge2.msg ) > /dev/null 2>&1
	if od -An -c gb.cat | tr -d ' \n' | grep -q 'B\\0$'; then pass=$((pass + 1))
	else note_fail "gencat: an empty message should take the message away"; fi

	cd .. || exit 1
fi

# --- ctags ------------------------------------------------------------------
# There is no ctags on this system to compare against, so the objects it finds
# in a file written for the purpose are checked one by one, and every search
# pattern it writes has to find the line it points at.
echo "### ctags"
mkdir -p ctt
cd ctt || exit 1

cat > c1.c <<'CEOF'
/* a sample file: braces in a comment { } */
#include <stdio.h>

#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define LIMIT 100

typedef struct node {
	int value;
	struct node *next;
} node_t, *node_p;

typedef int (*compare_fn)(const void *, const void *);

static int counter = 0;
static const char *table[] = { "a", "b" };
char *s = "a string with { } and /* not a comment */";

int add(int a, int b)
{
	return a + b;
}

static void
helper(node_t *n)
{
	if (n != NULL) { counter++; }
}

int forward(int, int);

int kr(a, b)
	int a;
	int b;
{
	return a;
}

struct node *make(int v)
{
	return NULL;
}

void outer(void)
{
	struct local { int x; };
}

int main(int argc, char **argv)
{
	printf("%d\n", add(1, 2));
	return 0;
}
CEOF

want='LIMIT
MAX
Mc1
add
compare_fn
helper
kr
make
node_p
node_t
outer'
got=$( . "$BT"; ctags -f c1.tags c1.c && cut -f1 c1.tags )
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "ctags found [$got] not [$want]"; fi

# the file must come out sorted, and in the format the standard gives
a=$( "$(real_of sort)" c1.tags )
b=$( "$(real_of cat)" c1.tags )
if [ "$a" = "$b" ]; then pass=$((pass + 1)); else note_fail "ctags output is not sorted"; fi
if [ "$( "$(real_of awk)" -F'\t' 'NF != 3 || $3 !~ /^\/\^.*\$\/$/ { n++ } END { print n+0 }' c1.tags )" = 0 ]; then
	pass=$((pass + 1))
else note_fail "ctags wrote a line that is not name, file, pattern"; fi

# every pattern has to find the line it points at
bad=0
while IFS=$'\t' read -r name file pat; do
	pat=${pat#/^}
	pat=${pat%\$/}
	pat=$( printf '%s' "$pat" | "$(real_of sed)" 's/\\\(.\)/\1/g' )
	"$(real_of grep)" -qxF -- "$pat" "$file" || { bad=1; note_fail "ctags pattern for $name does not match"; }
done < c1.tags
[ "$bad" = 0 ] && pass=$((pass + 1))

# -x writes the same objects with their line numbers and the line itself
x=$( . "$BT"; ctags -x c1.c )
if [ "$( printf '%s\n' "$x" | cut -d' ' -f1 )" = "$want" ]; then pass=$((pass + 1))
else note_fail "ctags -x listed [$( printf '%s\n' "$x" | cut -d' ' -f1 )]"; fi
if [ "$( printf '%s\n' "$x" | "$(real_of grep)" '^add ' )" = "add 18 c1.c int add(int a, int b)" ]; then
	pass=$((pass + 1))
else note_fail "ctags -x line: [$( printf '%s\n' "$x" | "$(real_of grep)" '^add ' )]"; fi
# -x writes nothing to a tags file
rm -f tags
( . "$BT"; ctags -x c1.c ) > /dev/null
if [ ! -e tags ]; then pass=$((pass + 1)); else note_fail "ctags -x wrote a tags file"; fi

# a header is C as well, and the default file is called tags
cat > c2.h <<'CEOF'
#define HDR 1
typedef unsigned long ulong_t;
int declared_only(void);
CEOF
rm -f tags
( . "$BT"; ctags c2.h )
if [ "$( cut -f1 tags | tr '\n' ' ' )" = "HDR ulong_t " ]; then pass=$((pass + 1))
else note_fail "ctags on a header: [$( cut -f1 tags | tr '\n' ' ' )]"; fi

# -a adds to what is there already, and the whole file stays sorted
( . "$BT"; ctags -a -f c1.tags c2.h )
if [ "$( cut -f1 c1.tags | tr '\n' ' ' )" = "HDR LIMIT MAX Mc1 add compare_fn helper kr make node_p node_t outer ulong_t " ]; then
	pass=$((pass + 1))
else note_fail "ctags -a: [$( cut -f1 c1.tags | tr '\n' ' ' )]"; fi

# fortran, fixed form, with continuation lines and comments
cat > f1.f <<'FEOF'
C     a fortran sample
      PROGRAM MAIN
      CALL GREET
      END
      SUBROUTINE GREET
      WRITE(*,*) 'hi'
      END
      INTEGER FUNCTION SQUARE(N)
      INTEGER N
      SQUARE = N * N
      END
      REAL FUNCTION AVG(A,
     +                  B)
      REAL A, B
      AVG = (A + B) / 2.0
      END
FEOF
got=$( . "$BT"; ctags -x f1.f | cut -d' ' -f1 | tr '\n' ' ' )
if [ "$got" = "AVG GREET MAIN SQUARE " ]; then pass=$((pass + 1))
else note_fail "ctags on fortran: [$got]"; fi

# a file that is not there is an error, and the ones that are still get read
a=$( . "$BT"; ctags -f c3.tags c1.c nosuch.c 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=1" ] && [ -s c3.tags ]; then pass=$((pass + 1))
else note_fail "ctags with a missing file: [$a]"; fi

# a slash in the line has to be spelt out in the pattern
printf 'int div_it(int a) /* a / b */\n{\n\treturn a;\n}\n' > c4.c
( . "$BT"; ctags -f c4.tags c4.c )
if [ "$( cut -f3 c4.tags )" = '/^int div_it(int a) \/* a \/ b *\/$/' ]; then pass=$((pass + 1))
else note_fail "ctags escaping: [$( cut -f3 c4.tags )]"; fi

cd .. || exit 1

# --- cflow ------------------------------------------------------------------
# The standard gives an example program and the graph it should produce, which
# is the strongest thing to test against; the rest is checked by construction.
echo "### cflow"
mkdir -p cft
cd cft || exit 1

cat > x1.c <<'CEOF'
int i;
int f();
int g();
int h();
int
main()
{
    f();
    g();
    f();
}
int
f()
{
    i = h();
}
CEOF

want='1 main: int(), <x1.c 6>
2    f: int(), <x1.c 13>
3        h: <>
4        i: int, <x1.c 1>
5    g: <>'
got=$( . "$BT"; cflow -i x x1.c )
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "cflow on the standard's example: [$got]"; fi

# without -i x the data is left out
want='1 main: int(), <x1.c 6>
2    f: int(), <x1.c 13>
3        h: <>
4    g: <>'
got=$( . "$BT"; cflow x1.c )
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "cflow without -i x: [$got]"; fi

# -d cuts the graph off
want='1 main: int(), <x1.c 6>
2    f: int(), <x1.c 13>
3    g: <>'
got=$( . "$BT"; cflow -d 2 x1.c )
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "cflow -d 2: [$got]"; fi
got=$( . "$BT"; cflow -d 0 x1.c )
if [ "$got" = "$( . "$BT"; cflow x1.c )" ]; then pass=$((pass + 1))
else note_fail "cflow -d 0 should be ignored"; fi

# -r turns it round and sorts by the thing being called
want='1 f: int(), <x1.c 13>
2    main: int(), <x1.c 6>
3 g: <>
4 h: <>
5 main: 2'
got=$( . "$BT"; cflow -r x1.c )
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "cflow -r: [$got]"; fi

# a name already written out is referred to by its number
cat > x2.c <<'CEOF'
int fact(int n)
{
	if (n <= 1) return 1;
	return n * fact(n - 1);
}
int even(int n) { return odd(n); }
int odd(int n) { return even(n); }
CEOF
want='1 fact: int(), <x2.c 1>
2    fact: 1
3 even: int(), <x2.c 6>
4    odd: int(), <x2.c 7>
5        even: 3'
got=$( . "$BT"; cflow x2.c )
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "cflow with recursion: [$got]"; fi

# names beginning with an underscore are left out unless asked for
cat > x3.c <<'CEOF'
static void _hidden(void) { }
void shown(void)
{
	_hidden();
	other();
}
CEOF
got=$( . "$BT"; cflow x3.c )
case $got in
*_hidden*)	note_fail "cflow showed an underscore name: [$got]" ;;
*)		pass=$((pass + 1)) ;;
esac
got=$( . "$BT"; cflow -i _ x3.c )
case $got in
*_hidden*)	pass=$((pass + 1)) ;;
*)		note_fail "cflow -i _ hid an underscore name: [$got]" ;;
esac

# the types come out as abstract declarations
cat > x4.c <<'CEOF'
struct node { int v; };
static struct node *make(void) { return 0; }
char *name(void) { return 0; }
static const char *table[] = { "a", "b" };
CEOF
got=$( . "$BT"; cflow -i x x4.c )
want='1 make: struct node *(), <x4.c 2>
2 name: char *(), <x4.c 3>'
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "cflow types: [$got]"; fi

# a file that is not there
a=$( . "$BT"; cflow nosuch.c 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=1" ]; then pass=$((pass + 1))
else note_fail "cflow with a missing file: [$a]"; fi

cd .. || exit 1

# --- cxref ------------------------------------------------------------------
# The standard leaves the layout of the listing open and asks only for the
# name, the file, the function it was written in and the line numbers, with a
# star on the declaring reference.  What is checked here is that those are
# right, and that every line number really holds the name.
echo "### cxref"
mkdir -p cxt
cd cxt || exit 1

cat > y1.c <<'CEOF'
#define LIMIT 10
int total;

int add(int a, int b)
{
	int sum;
	sum = a + b;
	return sum;
}

int main(void)
{
	total = add(1, LIMIT);
	return total;
}
CEOF

want='y1.c
LIMIT           y1.c            --              *1
LIMIT           y1.c            main            13
a               y1.c            add             *4 7
add             y1.c            --              *4
add             y1.c            main            13
b               y1.c            add             *4 7
main            y1.c            --              *11
sum             y1.c            add             *6 7 8
total           y1.c            --              *2
total           y1.c            main            13 14'
got=$( . "$BT"; cxref y1.c )
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "cxref listing: [$got]"; fi

# -s leaves the file name out, the rest is the same
got=$( . "$BT"; cxref -s y1.c )
if [ "$got" = "$( printf '%s\n' "$want" | "$(real_of tail)" -n +2 )" ]; then pass=$((pass + 1))
else note_fail "cxref -s: [$got]"; fi

# every line a name is said to be on has to hold that name
bad=0
while read -r name file fn rest; do
	[ "$file" = "$fn" ] && continue
	case $name in
	*.c)	continue ;;
	esac
	for ref in $rest; do
		ref=${ref#\*}
		"$(real_of sed)" -n "${ref}p" "$file" | "$(real_of grep)" -q "$name" ||
			{ bad=1; note_fail "cxref says $name is on line $ref of $file"; }
	done
done < <( . "$BT"; cxref -s y1.c )
[ "$bad" = 0 ] && pass=$((pass + 1))

# a second file gets its own heading, and -c runs them together
cat > y2.c <<'CEOF'
extern int total;
int helper(int x)
{
	return total + x;
}
CEOF
got=$( . "$BT"; cxref y1.c y2.c | "$(real_of grep)" -c '^y[12]\.c$' )
if [ "$got" = 2 ]; then pass=$((pass + 1))
else note_fail "cxref over two files headed [$got] of them"; fi
got=$( . "$BT"; cxref -c y1.c y2.c )
case $got in
y1.c*|*$'\n'y2.c$'\n'*)	note_fail "cxref -c wrote a file heading" ;;
*)			pass=$((pass + 1)) ;;
esac
# combined, the names run in one order across both files
got=$( . "$BT"; cxref -c y1.c y2.c | "$(real_of awk)" '{print $1}' | "$(real_of uniq)" | "$(real_of tr)" '\n' ' ' )
if [ "$got" = "LIMIT a add b helper main sum total x " ]; then pass=$((pass + 1))
else note_fail "cxref -c order: [$got]"; fi

# -w folds the line numbers to the width asked for
cat > y3.c <<'CEOF'
int spread(void)
{
	int x;
	x = 1; x = 2; x = 3; x = 4; x = 5; x = 6; x = 7; x = 8;
	x = 9;
	x = 10;
	x = 11;
	x = 12;
	return x;
}
CEOF
got=$( . "$BT"; cxref -w 51 y3.c | "$(real_of awk)" '{ if (length($0) > n) n = length($0) } END { print n }' )
if [ "$got" -le 51 ]; then pass=$((pass + 1))
else note_fail "cxref -w 51 wrote a line $got wide"; fi
got=$( . "$BT"; cxref y3.c | "$(real_of grep)" -c '^x ' )
if [ "$got" = 1 ]; then pass=$((pass + 1))
else note_fail "cxref folded when it did not need to"; fi
# a width below 51 is ignored, as the standard says
a=$( . "$BT"; cxref -w 10 y3.c )
b=$( . "$BT"; cxref y3.c )
if [ "$a" = "$b" ]; then pass=$((pass + 1))
else note_fail "cxref -w 10 should have been ignored"; fi

# -o writes to the file instead of the standard output
rm -f y.out
a=$( . "$BT"; cxref -o y.out y1.c )
if [ -z "$a" ] && [ "$( "$(real_of cat)" y.out )" = "$want" ]; then pass=$((pass + 1))
else note_fail "cxref -o"; fi

# a file that is not there
a=$( . "$BT"; cxref nosuch.c 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=1" ]; then pass=$((pass + 1))
else note_fail "cxref with a missing file: [$a]"; fi

cd .. || exit 1

# --- file -------------------------------------------------------------------
# The standard gives a table of strings the output has to contain for each
# sort of file, and that table is the test.  The magic file format it defines
# for -m and -M is tested on magic files written here.
echo "### file"
mkdir -p flt
cd flt || exit 1

fchk() {	# fchk file expected-substring
	local f=$1 want=$2 got
	got=$( . "$BT"; file "$f" 2>/dev/null )
	case $got in
	"$f: "*"$want"*)	pass=$((pass + 1)) ;;
	*)			note_fail "file $f: [$got] does not hold [$want]" ;;
	esac
}

: > f_empty
printf 'hello world\nsecond line\n' > f_text
printf '#!/bin/sh\necho hi\n' > f_sh
printf '#include <stdio.h>\nint main(void) { return 0; }\n' > f_c
printf 'C     a comment\n      PROGRAM MAIN\n      END\n' > f_f
printf 'a\000b\001\002\003\004\005\006' > f_data
mkdir -p f_dir
"$(real_of tar)" cf f_tar f_text 2>/dev/null
"$(real_of ar)" rc f_ar f_text 2>/dev/null
printf '070701000000000000000000' > f_cpio
"$(real_of cp)" "$(real_of cat)" f_exec 2>/dev/null

fchk f_empty empty
fchk f_text text
fchk f_sh 'commands text'
fchk f_c 'c program text'
fchk f_f 'fortran program text'
fchk f_data data
fchk f_dir directory
fchk f_tar 'tar archive'
fchk f_ar archive
fchk f_cpio 'cpio archive'
fchk f_exec executable
fchk /dev/null 'character special'

# things that are not files of their own
got=$( . "$BT"; file f_missing 2>/dev/null )
if [ "$got" = "f_missing: cannot open" ]; then pass=$((pass + 1))
else note_fail "file on a missing file: [$got]"; fi
a=$( . "$BT"; file f_missing > /dev/null 2>&1; echo $? )
if [ "$a" = 0 ]; then pass=$((pass + 1))
else note_fail "file on a missing file should still succeed ($a)"; fi

"$(real_of mkfifo)" f_fifo 2>/dev/null && fchk f_fifo fifo
"$(real_of ln)" -sf f_text f_link
got=$( . "$BT"; file -h f_link 2>/dev/null )
case $got in
"f_link: symbolic link to"*)	pass=$((pass + 1)) ;;
*)				note_fail "file -h on a link: [$got]" ;;
esac
got=$( . "$BT"; file f_link 2>/dev/null )
case $got in
*text*)	pass=$((pass + 1)) ;;
*)	note_fail "file should follow a link: [$got]" ;;
esac
"$(real_of ln)" -sf nowhere f_broken
got=$( . "$BT"; file f_broken 2>/dev/null )
case $got in
"f_broken: symbolic link to"*)	pass=$((pass + 1)) ;;
*)				note_fail "file on a broken link: [$got]" ;;
esac

# -i stops at the file type
got=$( . "$BT"; file -i f_text 2>/dev/null )
if [ "$got" = "f_text: regular file" ]; then pass=$((pass + 1))
else note_fail "file -i: [$got]"; fi
got=$( . "$BT"; file -i f_dir 2>/dev/null )
if [ "$got" = "f_dir: directory" ]; then pass=$((pass + 1))
else note_fail "file -i on a directory: [$got]"; fi

# magic files
printf 'MAGICTEST and the rest\n' > m_one
printf 'XYZZY\001\002\003' > m_two
printf 'AB\n' > m_short
{
	printf '0\tstring\tMAGICTEST\ta magic test file\n'
	printf '0\tstring\tXYZZY\tan xyzzy file\n'
	printf '>5\tbyte\t1\t\\ with a one after it\n'
	printf '>6\tbyte\t>1\t\\ and something above one\n'
} > m.magic
printf '0\tshort\t0x4241\ttwo bytes, smallest first\n' > m2.magic
printf '0\tstring\tXYZZY\tit says %%s\n' > m3.magic

got=$( . "$BT"; file -m m.magic m_one 2>/dev/null )
if [ "$got" = "m_one: a magic test file" ]; then pass=$((pass + 1))
else note_fail "file -m: [$got]"; fi
got=$( . "$BT"; file -m m.magic m_two 2>/dev/null )
if [ "$got" = "m_two: an xyzzy file with a one after it and something above one" ]; then pass=$((pass + 1))
else note_fail "file -m with continuation lines: [$got]"; fi
got=$( . "$BT"; file -M m2.magic m_short 2>/dev/null )
if [ "$got" = "m_short: two bytes, smallest first" ]; then pass=$((pass + 1))
else note_fail "file -M with a number: [$got]"; fi
got=$( . "$BT"; file -M m3.magic m_two 2>/dev/null )
if [ "$got" = "m_two: it says XYZZY" ]; then pass=$((pass + 1))
else note_fail "file magic message: [$got]"; fi
# -M on its own turns the built-in tests off, -d turns them back on
got=$( . "$BT"; file -M m.magic f_text 2>/dev/null )
if [ "$got" = "f_text: data" ]; then pass=$((pass + 1))
else note_fail "file -M should leave the default tests out: [$got]"; fi
got=$( . "$BT"; file -M m.magic -d f_text 2>/dev/null )
case $got in
*text*)	pass=$((pass + 1)) ;;
*)	note_fail "file -M -d: [$got]" ;;
esac
# -m keeps them
got=$( . "$BT"; file -m m.magic f_text 2>/dev/null )
case $got in
*text*)	pass=$((pass + 1)) ;;
*)	note_fail "file -m should keep the default tests: [$got]" ;;
esac

# the format is one line to a file, with no padding
got=$( . "$BT"; file f_empty f_text 2>/dev/null )
if [ "$got" = "f_empty: empty
f_text: ascii text" ]; then pass=$((pass + 1))
else note_fail "file with two operands: [$got]"; fi

cd .. || exit 1

# --- lex --------------------------------------------------------------------
# The scanners lex writes are C, so the test compiles them and runs them: the
# only way to know a generated program is right is to generate it, build it
# and feed it something.
echo "### lex"
if command -v cc > /dev/null 2>&1; then
	CC=$(real_of cc)
	mkdir -p lxt
	cd lxt || exit 1

	cat > lmain.c <<'CEOF'
extern int yylex(void);
int yywrap(void) { return 1; }
int main(void) { yylex(); return 0; }
CEOF

	lexrun() {	# lexrun description lexfile input expected [lexargs...]
		local desc=$1 lf=$2 in=$3 want=$4 got out
		shift 4
		rm -f lex.yy.c a.out
		if ! ( . "$BT"; lex "$@" "$lf" ) > /dev/null 2>&1; then
			note_fail "lex $desc: lex itself failed"
			return
		fi
		if ! "$CC" -o a.out lex.yy.c lmain.c > /dev/null 2>&1; then
			note_fail "lex $desc: the C it wrote does not compile"
			return
		fi
		got=$( printf '%s' "$in" | ./a.out 2>&1 )
		if [ "$got" = "$want" ]; then pass=$((pass + 1))
		else note_fail "lex $desc: [$got] not [$want]"; fi
	}

	# the smallest program there is: %% and nothing else copies its input
	printf '%%%%\n' > l0.l
	lexrun "the empty program" l0.l 'copy me
and me
' 'copy me
and me'

	# the longest match wins, and among equals the rule written first
	cat > l1.l <<'CEOF'
%{
#include <stdio.h>
%}
%%
[a-zA-Z]+	{ printf("W(%s)", yytext); }
[0-9]+		{ printf("N(%s)", yytext); }
[0-9]+"."[0-9]+	{ printf("R(%s)", yytext); }
[ \t]+		;
\n		{ printf("|"); }
.		{ printf("?"); }
%%
CEOF
	lexrun "words and numbers" l1.l 'abc 42 3.14 !
' 'W(abc)N(42)R(3.14)?|'

	# definitions, start conditions, anchors and trailing context
	cat > l2.l <<'CEOF'
D	[0-9]
ID	[a-zA-Z_][a-zA-Z_0-9]*
%x STR
%{
#include <stdio.h>
%}
%%
\"		{ printf("[str"); BEGIN STR; }
<STR>[^"\n]*	{ printf(":%s", yytext); }
<STR>\"		{ printf("]"); BEGIN INITIAL; }
{D}+		{ printf("<n %s>", yytext); }
{ID}		{ printf("<i %s>", yytext); }
^"#"[^\n]*	{ printf("<cpp>"); }
"end"$		{ printf("<END>"); }
[ \t]+		;
\n		{ printf("|"); }
.		{ printf("?"); }
%%
CEOF
	lexrun "definitions, conditions and anchors" l2.l '#line 1
foo 42 "a b" end
end here
' '<cpp>|<i foo><n 42>[str:a b]<END>|<i end><i here>|'

	# REJECT, yymore, yyless, ECHO and the | action
	cat > l3.l <<'CEOF'
%{
#include <stdio.h>
%}
%%
xyz		{ printf("[xyz]"); REJECT; }
xy		{ printf("[xy]"); }
z		{ printf("[z]"); }
a{2,3}		{ printf("[a%d]", yyleng); }
"more"		{ yymore(); }
"over"		{ printf("[%s]", yytext); }
less..		{ yyless(4); printf("[%s]", yytext); }
ECHOME		ECHO;
[0-9]+		|
[A-F]+		{ printf("<%s>", yytext); }
\n		{ printf("|"); }
%%
CEOF
	lexrun "the special actions" l3.l 'xyz
aaa aa
moreover
lessXY
ECHOME
123 ABC
' '[xyz][xy][z]|[a3] [a2]|[moreover]|[less]XY|ECHOME|<123> <ABC>|'

	# yytext as an array rather than a pointer
	cat > l4.l <<'CEOF'
%array
%{
#include <stdio.h>
%}
%%
[a-z]+	{ printf("(%s)", yytext); }
.|\n	;
%%
CEOF
	lexrun "%array" l4.l 'ab CD ef
' '(ab)(ef)'

	# a lexer of the sort someone would really write
	cat > l5.l <<'CEOF'
%{
#include <stdio.h>
%}
D	[0-9]
L	[a-zA-Z_]
H	[a-fA-F0-9]
E	[Ee][+-]?{D}+
%%
"/*"([^*]|"*"[^/])*"*/"		{ printf("C"); }
"int"|"char"|"return"|"void"|"if"|"else"	{ printf("K"); }
{L}({L}|{D})*			{ printf("I"); }
0[xX]{H}+			{ printf("N"); }
{D}+"."{D}*({E})?		{ printf("F"); }
{D}+				{ printf("N"); }
\"(\\.|[^\\"])*\"		{ printf("S"); }
"=="|"!="|"<="|">="|"&&"|"||"|"++"|"--"|"->"	{ printf("O"); }
[-+*/%&|^!~<>=(){}\[\];,.?:]	{ printf("p"); }
[ \t\n]+			;
.				{ printf("?"); }
%%
CEOF
	lexrun "a C tokeniser" l5.l 'int main(void) { /* hi */ int x = 0x1F; return x >= 3.5 ? "s" : 0; }
' 'KIpKppCKIpNpKIOFpSpNpp'

	# -t writes the program to the standard output and leaves no file
	rm -f lex.yy.c
	out=$( . "$BT"; lex -t l1.l 2>/dev/null )
	case $out in
	*yylex*)	if [ ! -e lex.yy.c ]; then pass=$((pass + 1))
			else note_fail "lex -t wrote lex.yy.c as well"; fi ;;
	*)		note_fail "lex -t wrote nothing useful" ;;
	esac
	# -v says something about the tables, -n keeps it quiet
	out=$( . "$BT"; lex -v l1.l 2>/dev/null )
	case $out in
	*rules*)	pass=$((pass + 1)) ;;
	*)		note_fail "lex -v: [$out]" ;;
	esac
	out=$( . "$BT"; lex -n l1.l 2>/dev/null )
	if [ -z "$out" ]; then pass=$((pass + 1))
	else note_fail "lex -n wrote [$out]"; fi
	# the source can come from the standard input
	rm -f lex.yy.c
	( . "$BT"; lex < l1.l ) > /dev/null 2>&1
	if [ -s lex.yy.c ]; then pass=$((pass + 1))
	else note_fail "lex reading its source from stdin"; fi
	# a file that is not there
	a=$( . "$BT"; lex nosuch.l 2>/dev/null; echo "rc=$?" )
	if [ "$a" = "rc=1" ]; then pass=$((pass + 1))
	else note_fail "lex with a missing file: [$a]"; fi

	cd .. || exit 1
fi

# --- yacc -------------------------------------------------------------------
# What yacc writes is a C program, so the test compiles it and runs it against
# input the grammar describes.
echo "### yacc"
if command -v cc > /dev/null 2>&1; then
	CC=$(real_of cc)
	mkdir -p yct
	cd yct || exit 1

	yaccrun() {	# yaccrun description grammar input expected [args...]
		local desc=$1 gr=$2 in=$3 want=$4 got
		shift 4
		rm -f y.tab.c y.tab.h a.out
		if ! ( . "$BT"; yacc "$@" "$gr" ) > /dev/null 2>&1; then
			note_fail "yacc $desc: yacc itself failed"
			return
		fi
		if ! "$CC" -o a.out y.tab.c > /dev/null 2>&1; then
			note_fail "yacc $desc: the C it wrote does not compile"
			return
		fi
		got=$( printf '%s' "$in" | ./a.out 2>/dev/null )
		if [ "$got" = "$want" ]; then pass=$((pass + 1))
		else note_fail "yacc $desc: [$got] not [$want]"; fi
	}

	cat > calc.y <<'GEOF'
%{
#include <stdio.h>
#include <ctype.h>
int yylex(void);
void yyerror(const char *s);
%}
%token NUMBER
%left '+' '-'
%left '*' '/'
%%
input	: /* empty */
	| input line
	;
line	: '\n'
	| expr '\n'	{ printf("%d\n", $1); }
	;
expr	: NUMBER		{ $$ = $1; }
	| expr '+' expr		{ $$ = $1 + $3; }
	| expr '-' expr		{ $$ = $1 - $3; }
	| expr '*' expr		{ $$ = $1 * $3; }
	| expr '/' expr		{ $$ = $1 / $3; }
	| '(' expr ')'		{ $$ = $2; }
	| '-' expr		{ $$ = -$2; }
	;
%%
int yylex(void)
{
	int c;
	do { c = getchar(); } while (c == ' ' || c == '\t');
	if (c == EOF) return 0;
	if (isdigit(c)) {
		int v = 0;
		while (isdigit(c)) { v = v * 10 + (c - '0'); c = getchar(); }
		ungetc(c, stdin);
		yylval = v;
		return NUMBER;
	}
	return c;
}
void yyerror(const char *s) { fprintf(stderr, "%s\n", s); }
int main(void) { return yyparse(); }
GEOF
	yaccrun "precedence and grouping" calc.y '1+2*3
(1+2)*3
10/2-3
-5+1
2*-3
' '7
9
2
-4
-6'

	# error recovery with the error token
	cat > err.y <<'GEOF'
%{
#include <stdio.h>
#include <ctype.h>
int yylex(void);
void yyerror(const char *s);
%}
%token NUM
%%
list	: /* empty */
	| list stmt
	;
stmt	: NUM ';'	{ printf("ok %d\n", $1); }
	| error ';'	{ printf("recovered\n"); yyerrok; }
	;
%%
int yylex(void)
{
	int c;
	do { c = getchar(); } while (c == ' ' || c == '\n');
	if (c == EOF) return 0;
	if (isdigit(c)) { yylval = c - '0'; return NUM; }
	return c;
}
void yyerror(const char *s) { fprintf(stderr, "error: %s\n", s); }
int main(void) { return yyparse(); }
GEOF
	yaccrun "error recovery" err.y '1; x y; 2;
' 'ok 1
recovered
ok 2'

	# a value type of one's own, and the header that goes with it
	cat > un.y <<'GEOF'
%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
int yylex(void);
void yyerror(const char *s);
%}
%union {
	int num;
	char *str;
}
%token <num> NUM
%token <str> WORD
%type <num> expr
%%
input	: /* empty */
	| input line
	;
line	: expr '\n'		{ printf("= %d\n", $1); }
	| WORD '\n'		{ printf("word %s\n", $1); free($1); }
	;
expr	: NUM			{ $$ = $1; }
	| expr '+' NUM		{ $$ = $1 + $3; }
	;
%%
int yylex(void)
{
	int c;
	do { c = getchar(); } while (c == ' ');
	if (c == EOF) return 0;
	if (isdigit(c)) { yylval.num = c - '0'; return NUM; }
	if (isalpha(c)) {
		char buf[64]; int i = 0;
		while (isalpha(c)) { buf[i++] = c; c = getchar(); }
		ungetc(c, stdin); buf[i] = 0;
		yylval.str = strdup(buf);
		return WORD;
	}
	return c;
}
void yyerror(const char *s) { fprintf(stderr, "%s\n", s); }
int main(void) { return yyparse(); }
GEOF
	yaccrun "a union for the values" un.y '1+2+3
hello
' '= 6
word hello' -d
	if [ -f y.tab.h ] &&
	   "$(real_of grep)" -q '#define NUM' y.tab.h &&
	   "$(real_of grep)" -q 'YYSTYPE' y.tab.h; then
		pass=$((pass + 1))
	else note_fail "yacc -d header"; fi

	# an action written in the middle of a rule
	cat > mid.y <<'GEOF'
%{
#include <stdio.h>
#include <ctype.h>
int yylex(void);
void yyerror(const char *s);
%}
%token NUM
%%
s	: NUM { printf("[saw %d]", $1); } NUM '\n'	{ printf("both %d %d\n", $1, $3); }
	;
%%
int yylex(void) { int c; do { c = getchar(); } while (c == ' '); if (c == EOF) return 0;
	if (isdigit(c)) { yylval = c - '0'; return NUM; } return c; }
void yyerror(const char *s) { fprintf(stderr, "%s\n", s); }
int main(void) { return yyparse(); }
GEOF
	yaccrun "an action in the middle of a rule" mid.y '4 7
' '[saw 4]both 4 7'

	# a grammar with something to sort out, and the report that goes with it
	cat > ifel.y <<'GEOF'
%{
#include <stdio.h>
#include <ctype.h>
int yylex(void);
void yyerror(const char *s);
%}
%token IF THEN ELSE STMT
%%
prog	: stmt '\n'	{ printf("parsed\n"); }
	;
stmt	: STMT
	| IF stmt THEN stmt
	| IF stmt THEN stmt ELSE stmt
	;
%%
int yylex(void) { int c; do { c = getchar(); } while (c == ' ');
	if (c == EOF) return 0;
	switch (c) { case 'i': return IF; case 't': return THEN; case 'e': return ELSE; case 's': return STMT; }
	return c; }
void yyerror(const char *s) { fprintf(stderr, "%s\n", s); }
int main(void) { return yyparse(); }
GEOF
	out=$( . "$BT"; yacc ifel.y 2>&1 >/dev/null )
	case $out in
	*'1 shift/reduce conflict'*)	pass=$((pass + 1)) ;;
	*)				note_fail "yacc conflict report: [$out]" ;;
	esac
	yaccrun "the dangling else" ifel.y 'i s t i s t s e s
' 'parsed'

	# -b names the files, -p names the symbols
	rm -f pre.tab.c pre.tab.h pre.output
	( . "$BT"; yacc -b pre -d -v calc.y ) > /dev/null 2>&1
	if [ -f pre.tab.c ] && [ -f pre.tab.h ] && [ -f pre.output ]; then
		pass=$((pass + 1))
	else note_fail "yacc -b"; fi
	rm -f y.tab.c
	( . "$BT"; yacc -p zz calc.y ) > /dev/null 2>&1
	if "$(real_of grep)" -q 'define yyparse zzparse' y.tab.c &&
	   "$(real_of grep)" -q 'define yylval zzlval' y.tab.c; then
		pass=$((pass + 1))
	else note_fail "yacc -p"; fi

	# a grammar that is not there, and one with nothing in it
	a=$( . "$BT"; yacc nosuch.y 2>/dev/null; echo "rc=$?" )
	if [ "$a" = "rc=1" ]; then pass=$((pass + 1))
	else note_fail "yacc with a missing file: [$a]"; fi
	printf '%%%%\n' > empty.y
	a=$( . "$BT"; yacc empty.y 2>/dev/null; echo "rc=$?" )
	if [ "$a" = "rc=1" ]; then pass=$((pass + 1))
	else note_fail "yacc with an empty grammar: [$a]"; fi

	cd .. || exit 1
fi

# --- man --------------------------------------------------------------------
# The pages are roff with the man macros in them and are usually kept gzipped,
# so this exercises the gzip reader as well: the same page, plain and packed,
# has to come out the same.  What a formatted page looks like is not something
# the standard says anything about, so what is checked is that everything in
# the page reaches the output in the right shape.
echo "### man"
mkdir -p mnt/man1 mnt/man8
cd mnt || exit 1

cat > man1/frobnicate.1 <<'MEOF'
.TH FROBNICATE 1 "2026-08-25" "bashtrash" "User Commands"
.SH NAME
frobnicate \- twist a widget until it clicks
.SH SYNOPSIS
.B frobnicate
[\fB\-v\fR] \fIwidget\fR...
.SH DESCRIPTION
The
.B frobnicate
utility twists each
.I widget
until it clicks. If a widget will not click, it is left alone.
.TP
.B \-v
Say what is being twisted.
.SH EXIT STATUS
.TP
0
All widgets clicked.
.TP
>0
An error occurred.
.SH SEE ALSO
.BR widget (1)
MEOF
cat > man8/widget.8 <<'MEOF'
.TH WIDGET 8 "2026-08-25" "bashtrash" "System Manager's Manual"
.SH NAME
widget \- make a widget out of nothing
.SH DESCRIPTION
Makes a widget.
MEOF

got=$( MANPATH=$PWD; export MANPATH; . "$BT"; man frobnicate 2>&1 )
ok=1
case $got in
"FROBNICATE(1)"*)	;;
*)	ok=0 ;;
esac
for want in 'frobnicate - twist a widget until it clicks' \
            'frobnicate [-v] widget...' \
            'utility twists each widget until it clicks' \
            'All widgets clicked.' \
            'widget(1)'; do
	case $got in
	*"$want"*)	;;
	*)		ok=0; note_fail "man: [$want] missing from the page" ;;
	esac
done
for want in NAME SYNOPSIS DESCRIPTION 'EXIT STATUS' 'SEE ALSO'; do
	case $got in
	*$'\n'"$want"$'\n'*)	;;
	*)			ok=0; note_fail "man: the heading $want is not at the margin" ;;
	esac
done
[ "$ok" = 1 ] && pass=$((pass + 1))

# the tag of a .TP stands on its own line, and what follows is indented
case $got in
*$'\n       -v\n           Say what is being twisted.'*)	pass=$((pass + 1)) ;;
*)	note_fail "man: .TP did not lay out its tag" ;;
esac

# nothing runs past the width
if [ "$( printf '%s\n' "$got" | "$(real_of awk)" '{ if (length($0) > n) n = length($0) } END { print n }' )" -le 80 ]; then
	pass=$((pass + 1))
else note_fail "man wrote a line wider than the terminal"; fi

# the same page gzipped has to come out the same
"$(real_of gzip)" -kf man1/frobnicate.1
rm -f man1/frobnicate.1
got2=$( MANPATH=$PWD; export MANPATH; . "$BT"; man frobnicate 2>&1 )
if [ "$got2" = "$got" ]; then pass=$((pass + 1))
else note_fail "man on a gzipped page: [$got2]"; fi
"$(real_of gunzip)" -f man1/frobnicate.1.gz

# the gzip reader against the real thing, on files of several sorts
gzchk() {	# gzchk file
	local f=$1 a b
	"$(real_of gzip)" -kf "$f"
	a=$( . "$BT"; _bt_str=; _bt_gunzip "$f.gz" && printf '%s' "$_bt_str" | "$(real_of md5sum)" )
	b=$( "$(real_of zcat)" "$f.gz" | "$(real_of md5sum)" )
	if [ "$a" = "$b" ]; then pass=$((pass + 1))
	else note_fail "gunzip $f"; fi
	rm -f "$f.gz"
}
printf 'hello hello hello world\n' > gz1
"$(real_of seq)" 1 2000 > gz2
"$(real_of head)" -c 4000 /dev/urandom | "$(real_of tr)" -d '\000' > gz3
"$(real_of head)" -c 3000 /dev/urandom | "$(real_of base64)" > gz4
printf '' > gz5
gzchk gz1
gzchk gz2
gzchk gz3
gzchk gz4
gzchk gz5

# a page in another section, and one that is not there at all
got=$( MANPATH=$PWD; export MANPATH; . "$BT"; man widget 2>&1 )
case $got in
"WIDGET(8)"*)	pass=$((pass + 1)) ;;
*)		note_fail "man on a page in section 8: [$got]" ;;
esac
a=$( MANPATH=$PWD; export MANPATH; . "$BT"; man nosuchpage 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=1" ]; then pass=$((pass + 1))
else note_fail "man on a page that is not there: [$a]"; fi

# -k looks through the summaries
got=$( MANPATH=$PWD; export MANPATH; . "$BT"; man -k twist 2>&1 )
case $got in
*'FROBNICATE(1) - twist a widget until it clicks'*)	pass=$((pass + 1)) ;;
*)	note_fail "man -k: [$got]" ;;
esac
got=$( MANPATH=$PWD; export MANPATH; . "$BT"; man -k widget 2>&1 | "$(real_of wc)" -l )
if [ "$got" = 2 ]; then pass=$((pass + 1))
else note_fail "man -k widget found $got pages, not 2"; fi
a=$( MANPATH=$PWD; export MANPATH; . "$BT"; man -k nothinglikethis 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=1" ]; then pass=$((pass + 1))
else note_fail "man -k with nothing to find: [$a]"; fi

cd .. || exit 1

# --- mailx ------------------------------------------------------------------
# A mailbox is a file of messages, each beginning with a line that starts
# "From ", so sending and reading can both be checked by looking at the file.
echo "### mailx"
mkdir -p mxt
cd mxt || exit 1
MXHOME=$PWD

mxsend() {	# mxsend subject body address
	printf '%s\n' "$3" | ( MAIL=$MXHOME/box MBOX=$MXHOME/mbox HOME=$MXHOME
		. "$BT"; mailx -s "$1" "$2" ) 2>&1
}

rm -f box mbox
who=$( . "$BT"; id -un )
mxsend 'the first' "$who" 'body of the first' > /dev/null
mxsend 'the second' "$who" 'body of the second' > /dev/null

# the mailbox holds two messages in the shape a mailbox has
if [ "$( "$(real_of grep)" -c '^From ' box )" = 2 ]; then pass=$((pass + 1))
else note_fail "mailx sent $( "$(real_of grep)" -c '^From ' box ) messages, not 2"; fi
ok=1
for want in "^From $who " '^Date: ' "^From: $who$" "^To: $who$" '^Subject: the first$' '^body of the first$'; do
	"$(real_of grep)" -q "$want" box || { ok=0; note_fail "mailx: [$want] missing from the message"; }
done
[ "$ok" = 1 ] && pass=$((pass + 1))

# a header summary, and the messages counted
got=$( MAIL=$MXHOME/box MBOX=$MXHOME/mbox HOME=$MXHOME; . "$BT"; mailx -H 2>&1 )
if [ "$( printf '%s\n' "$got" | "$(real_of wc)" -l )" = 2 ] &&
   case $got in '>N  1 '*) true ;; *) false ;; esac; then
	pass=$((pass + 1))
else note_fail "mailx -H: [$got]"; fi

# -e says whether there is anything to read
a=$( MAIL=$MXHOME/box HOME=$MXHOME; . "$BT"; mailx -e; echo $? )
b=$( MAIL=$MXHOME/nothing HOME=$MXHOME; . "$BT"; mailx -e; echo $? )
if [ "$a" = 0 ] && [ "$b" = 1 ]; then pass=$((pass + 1))
else note_fail "mailx -e said $a and $b"; fi
got=$( MAIL=$MXHOME/nothing HOME=$MXHOME; . "$BT"; mailx 2>&1 < /dev/null )
case $got in
'No mail for '*)	pass=$((pass + 1)) ;;
*)			note_fail "mailx with an empty mailbox: [$got]" ;;
esac

# reading: print a message, save one, write one without its headers
rm -f saved written
got=$( MAIL=$MXHOME/box MBOX=$MXHOME/mbox HOME=$MXHOME; . "$BT"
	printf 'p 1\ns 1 saved\nw 2 written\nsize 2\n=\nx\n' | mailx -N 2>&1 )
ok=1
for want in '^Subject: the first$' '^body of the first$' '^"saved" 1 messages$' '^"written" 1 messages$' '^2: [0-9]*$'; do
	printf '%s\n' "$got" | "$(real_of grep)" -q "$want" || { ok=0; note_fail "mailx reading: [$want] not in [$got]"; }
done
[ "$ok" = 1 ] && pass=$((pass + 1))
if "$(real_of grep)" -q '^From ' saved && "$(real_of grep)" -q '^body of the first$' saved; then
	pass=$((pass + 1))
else note_fail "mailx save"; fi
if ! "$(real_of grep)" -q '^From ' written && "$(real_of grep)" -q '^body of the second$' written; then
	pass=$((pass + 1))
else note_fail "mailx write should leave the headers out"; fi

# exit leaves the mailbox alone; quit moves what was read to the mbox
( MAIL=$MXHOME/box MBOX=$MXHOME/mbox HOME=$MXHOME; . "$BT"
	printf 'p 1\nx\n' | mailx -N ) > /dev/null 2>&1
if [ "$( "$(real_of grep)" -c '^From ' box )" = 2 ]; then pass=$((pass + 1))
else note_fail "mailx exit should have left the mailbox alone"; fi
rm -f mbox
( MAIL=$MXHOME/box MBOX=$MXHOME/mbox HOME=$MXHOME; . "$BT"
	printf 'p 1\nq\n' | mailx -N ) > /dev/null 2>&1
if [ "$( "$(real_of grep)" -c '^From ' box )" = 1 ] &&
   [ "$( "$(real_of grep)" -c '^From ' mbox )" = 1 ]; then
	pass=$((pass + 1))
else note_fail "mailx quit should move what was read to the mbox"; fi

# delete and undelete
rm -f box mbox
mxsend 'one' "$who" 'first' > /dev/null
mxsend 'two' "$who" 'second' > /dev/null
mxsend 'three' "$who" 'third' > /dev/null
( MAIL=$MXHOME/box MBOX=$MXHOME/mbox HOME=$MXHOME; . "$BT"
	printf 'd 1 2\nu 2\nq\n' | mailx -N ) > /dev/null 2>&1
if [ "$( "$(real_of grep)" -c '^From ' box )" = 1 ] &&
   [ "$( "$(real_of grep)" -c '^From ' mbox )" = 1 ]; then
	pass=$((pass + 1))
else note_fail "mailx delete and undelete"; fi

# -f reads another mailbox, and leaves it alone
rm -f box mbox other
mxsend 'kept' "$who" 'body' > /dev/null
"$(real_of cp)" box other
got=$( MAIL=$MXHOME/box MBOX=$MXHOME/mbox HOME=$MXHOME; . "$BT"
	printf 'h\nq\n' | mailx -N -f other 2>&1 )
case $got in
*' 1 '*kept*)	pass=$((pass + 1)) ;;
*)		note_fail "mailx -f: [$got]" ;;
esac
if [ "$( "$(real_of grep)" -c '^From ' other )" = 1 ]; then pass=$((pass + 1))
else note_fail "mailx -f should have left the file alone"; fi

# a message list of several sorts
got=$( MAIL=$MXHOME/box MBOX=$MXHOME/mbox HOME=$MXHOME; . "$BT"
	printf 'f *\nf $\nf /kept\nx\n' | mailx -N 2>&1 | "$(real_of wc)" -l )
if [ "$got" = 3 ]; then pass=$((pass + 1))
else note_fail "mailx message lists gave $got lines, not 3"; fi

# an address with a host in it has nowhere to go
a=$( printf 'x\n' | ( MAIL=$MXHOME/box HOME=$MXHOME; . "$BT"
	mailx -s hi someone@example.com ) 2>&1; echo "rc=$?" )
case $a in
*'no mailer'*rc=1)	pass=$((pass + 1)) ;;
*)			note_fail "mailx to a remote address: [$a]" ;;
esac

cd .. || exit 1

# --- localedef --------------------------------------------------------------
# A locale definition is compiled into the form `locale' here reads back, so
# the test is a round trip: write a definition, compile it, and ask locale
# what it says.
echo "### localedef"
mkdir -p ldt
cd ldt || exit 1
LDHOME=$PWD

cat > src <<'LEOF'
comment_char %
escape_char /
% a small locale
LC_NUMERIC
decimal_point "<comma>"
thousands_sep "<period>"
grouping 3;3
END LC_NUMERIC
LC_TIME
abday "Su";"Mo";"Tu";"We";"Th";"Fr";"Sa"
day "Sunday";/
    "Monday";/
    "Tuesday";/
    "Wednesday";/
    "Thursday";/
    "Friday";/
    "Saturday"
d_fmt "%d.%m.%Y"
t_fmt "%H:%M:%S"
END LC_TIME
LC_MESSAGES
yesexpr "<circumflex>[jJyY]"
noexpr "<circumflex>[nN]"
END LC_MESSAGES
LEOF

a=$( LOCPATH=$LDHOME; export LOCPATH; . "$BT"; localedef -i src mine 2>&1; echo "rc=$?" )
if [ "$a" = "rc=0" ] && [ -f mine ]; then pass=$((pass + 1))
else note_fail "localedef: [$a]"; fi

# what came out says what went in
ok=1
for want in '^LC_NUMERIC$' '^decimal_point ,$' '^grouping 3;3$' '^END LC_NUMERIC$' \
            '^abday Su;Mo;Tu;We;Th;Fr;Sa$' '^d_fmt %d\.%m\.%Y$' '^yesexpr \^\[jJyY\]$'; do
	"$(real_of grep)" -q "$want" mine || { ok=0; note_fail "localedef: [$want] not in the locale"; }
done
[ "$ok" = 1 ] && pass=$((pass + 1))

# and locale reads it back
got=$( { LOCPATH=$LDHOME LC_ALL=mine; export LOCPATH LC_ALL; . "$BT"
	locale -k decimal_point d_fmt abday yesexpr; } 2>/dev/null )
want='decimal_point=","
d_fmt="%d.%m.%Y"
abday="Su;Mo;Tu;We;Th;Fr;Sa"
yesexpr="^[jJyY]"'
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "locale reading a compiled locale: [$got]"; fi
# without it, the POSIX values stand
got=$( { LC_ALL=C; export LC_ALL; . "$BT"; locale -k d_fmt; } 2>/dev/null )
if [ "$got" = 'd_fmt="%m/%d/%y"' ]; then pass=$((pass + 1))
else note_fail "locale outside a compiled locale: [$got]"; fi

# characters that would be taken for something else survive the trip
cat > tricky <<'LEOF'
LC_NUMERIC
decimal_point "<semicolon>"
thousands_sep "<backslash>"
grouping 3
END LC_NUMERIC
LC_TIME
abday "a;b";"c\\d";"e f"
END LC_TIME
LEOF
( . "$BT"; localedef -i tricky ./odd ) > /dev/null 2>&1
got=$( { LC_ALL=$LDHOME/odd; export LC_ALL; . "$BT"; locale -k decimal_point thousands_sep abday; } 2>/dev/null )
want='decimal_point=";"
thousands_sep="\"
abday="a;b;c\d;e f"'
if [ "$got" = "$want" ]; then pass=$((pass + 1))
else note_fail "localedef round trip with odd characters: [$got]"; fi

# a charmap of one's own
cat > cm <<'LEOF'
<code_set_name> TEST
<mb_cur_max> 1
<comment_char> %
<escape_char> /
CHARMAP
<one-sign>     /x31
<two-sign>     /x32
<star>         /x2a
END CHARMAP
LEOF
cat > src2 <<'LEOF'
LC_NUMERIC
decimal_point "<star>"
thousands_sep "<one-sign>"
grouping 3
END LC_NUMERIC
LEOF
a=$( . "$BT"; localedef -f cm -i src2 ./cmloc 2>&1; echo "rc=$?" )
got=$( { LC_ALL=$LDHOME/cmloc; export LC_ALL; . "$BT"; locale -k decimal_point thousands_sep; } 2>/dev/null )
if [ "$a" = "rc=0" ] && [ "$got" = 'decimal_point="*"
thousands_sep="1"' ]; then
	pass=$((pass + 1))
else note_fail "localedef with a charmap: [$a] [$got]"; fi

# a name the charmap does not hold is a warning in LC_CTYPE and an error
# elsewhere; a warning stops the locale being made unless -c says otherwise
cat > src3 <<'LEOF'
LC_CTYPE
upper "<not-a-real-name>"
END LC_CTYPE
LEOF
rm -f ./warned
a=$( . "$BT"; localedef -f cm -i src3 ./warned 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=4" ] && [ ! -f ./warned ]; then pass=$((pass + 1))
else note_fail "localedef with a warning and no -c: [$a]"; fi
a=$( . "$BT"; localedef -c -f cm -i src3 ./warned 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=1" ] && [ -f ./warned ]; then pass=$((pass + 1))
else note_fail "localedef -c with a warning: [$a]"; fi
cat > src4 <<'LEOF'
LC_NUMERIC
decimal_point "<not-a-real-name>"
END LC_NUMERIC
LEOF
rm -f ./errored
a=$( . "$BT"; localedef -c -f cm -i src4 ./errored 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=4" ] && [ ! -f ./errored ]; then pass=$((pass + 1))
else note_fail "localedef with an error even with -c: [$a]"; fi

# a source that is not there, and a line that means nothing
a=$( . "$BT"; localedef -i nosuch ./x 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=4" ]; then pass=$((pass + 1))
else note_fail "localedef with a missing source: [$a]"; fi
printf 'this is not a category\n' > src5
rm -f ./bad
a=$( . "$BT"; localedef -i src5 ./bad 2>/dev/null; echo "rc=$?" )
if [ "$a" = "rc=4" ] && [ ! -f ./bad ]; then pass=$((pass + 1))
else note_fail "localedef with a line it cannot read: [$a]"; fi

# copy takes a category from another definition
cat > base <<'LEOF'
LC_TIME
d_fmt "%Y-%m-%d"
END LC_TIME
LEOF
cat > src6 <<'LEOF'
LC_TIME
copy "base"
END LC_TIME
LEOF
( . "$BT"; localedef -i src6 ./copied ) > /dev/null 2>&1
got=$( { LC_ALL=$LDHOME/copied; export LC_ALL; . "$BT"; locale -k d_fmt; } 2>/dev/null )
if [ "$got" = 'd_fmt="%Y-%m-%d"' ]; then pass=$((pass + 1))
else note_fail "localedef copy: [$got]"; fi

# the definition this system keeps for the POSIX locale compiles
if [ -f /usr/share/i18n/locales/POSIX ]; then
	rm -f ./posix
	a=$( . "$BT"; localedef -i /usr/share/i18n/locales/POSIX ./posix 2>/dev/null; echo "rc=$?" )
	if [ "$a" = "rc=0" ] && "$(real_of grep)" -q '^upper A;B;C' ./posix; then
		pass=$((pass + 1))
	else note_fail "localedef on the system's POSIX definition: [$a]"; fi
fi

cd .. || exit 1

# --- the pure-bash claim itself -------------------------------------------
echo "### no external programs"
mkdir -p pure
cat > pure/prog.l <<'PEOF'
%{
#include <stdio.h>
%}
%%
[a-z]+	{ printf("W"); }
.|\n	;
%%
PEOF
cat > pure/gram.y <<'PEOF'
%token NUM
%%
s	: NUM '\n'	{ }
	;
%%
PEOF
cat > pure/prog.c <<'PEOF'
#define LIMIT 10
typedef int count_t;
int add(int a, int b)
{
	return a + b;
}
int main(void)
{
	return add(1, LIMIT);
}
PEOF
cat > pure/page.1 <<'PEOF'
.TH PURE 1 "2026" "bashtrash" "User Commands"
.SH NAME
pure \- a page to format
.SH DESCRIPTION
It is only a test.
PEOF
printf '$set 1\n1 hello\n' > pure/cat.msg
printf 'a b c\n1 2 3\n' > pure/data
printf 'all:\n\t@echo made\n' > pure/Makefile
printf '0\tstring\ta\tstarts with an a\n' > pure/magic
mkdir -p pure/manpath/man1
cp pure/page.1 pure/manpath/man1/pure.1
out=$(env -i PATH= "$BASH" --noprofile --norc -c '
	. "$1" || exit 1
	cd "$2" || exit 1
	cat lines12 > /dev/null			|| exit 1
	cat -u binary > /dev/null		|| exit 1
	tail -n 3 lines12 > /dev/null		|| exit 1
	tail -c 5 lines12 > /dev/null		|| exit 1
	id > /dev/null				|| exit 1
	cd pure					|| exit 1
	export HOME=$PWD MAIL=$PWD/box MANPATH=$PWD/manpath
	awk "{ s += \$2 } END { print s, NR }" data > /dev/null	|| exit 1
	awk "BEGIN { printf \"%.4f\n\", sin(1) }" > /dev/null	|| exit 1
	sed -n "1p" data > /dev/null		|| exit 1
	grep -c b data > /dev/null		|| exit 1
	sort -k2 data > /dev/null		|| exit 1
	bc <<< "2^64" > /dev/null		|| exit 1
	make -n > /dev/null			|| exit 1
	lex -t prog.l > /dev/null		|| exit 1
	yacc gram.y				|| exit 1
	ctags -f tags prog.c			|| exit 1
	cflow prog.c > /dev/null		|| exit 1
	cxref prog.c > /dev/null		|| exit 1
	file data prog.c > /dev/null		|| exit 1
	file -M magic data > /dev/null		|| exit 1
	gencat cat.cat cat.msg			|| exit 1
	compress -c data > data.Z		|| exit 1
	zcat data.Z > /dev/null			|| exit 1
	uuencode data d < data > data.uu	|| exit 1
	uudecode -o /dev/null data.uu		|| exit 1
	od -An -tx1 data > /dev/null		|| exit 1
	pr -h x data > /dev/null		|| exit 1
	diff data data > /dev/null		|| exit 1
	man pure > /dev/null			|| exit 1
	printf "a message\n" | mailx -s hi "$(id -un)" || exit 1
	mailx -H > /dev/null			|| exit 1
	printf "q\n" | mailx -N > /dev/null	|| exit 1
	echo ok' _ "$BT" "$work" 2>&1)
if [ "$out" = ok ]; then
	pass=$((pass + 1)); echo "everything above runs with an empty PATH"
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
