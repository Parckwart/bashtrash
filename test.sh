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

real_of() { case $1 in cat) printf '%s' "$R_CAT" ;; tail) printf '%s' "$R_TAIL" ;; esac; }

report() { # NAME
	fail=$((fail + 1)); failed+=("$1")
	echo "FAIL: $1"
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

# --- the pure-bash claim itself -------------------------------------------
echo "### no external programs"
out=$(env -i PATH= "$BASH" --noprofile --norc -c '
	. "$1" || exit 1
	cd "$2" || exit 1
	cat lines12 > /dev/null    || exit 1
	cat -u binary > /dev/null  || exit 1
	tail -n 3 lines12 > /dev/null || exit 1
	tail -c 5 lines12 > /dev/null || exit 1
	whoami > /dev/null         || exit 1
	echo ok' _ "$BT" "$work" 2>&1)
if [ "$out" = ok ]; then
	pass=$((pass + 1)); echo "all three run with an empty PATH"
else
	report "empty PATH: $out"
fi

echo
echo "==== pass=$pass fail=$fail ===="
if [ "$fail" -gt 0 ]; then printf 'failed: %s\n' "${failed[@]}"; exit 1; fi
exit 0
