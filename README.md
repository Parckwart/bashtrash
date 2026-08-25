![bashtrash](https://i.imgur.com/8U6BWHS.jpg)

# bashtrash — POSIX utilities written in bash

*Once a teenage dream, barely implemented — now real, vibecoded in a day from the sauna.*

*While some Linux distributions are busy swapping out GNU coreutils for replacements
written in Rust, here's one written in bash!* 🥴

---

## What this is

`bashtrash` reimplements POSIX command line utilities as bash functions, using
**nothing but shell builtins**. No forks, no `exec`, no coreutils, no `/usr/bin`
at all. Every one of them keeps working in a shell with an empty `$PATH`:

```console
$ env -i PATH= bash --noprofile --norc
$ . bashtrash.sh
$ ls
bash: ls: No such file or directory        # nothing external is reachable
$ cat README.md | head -n 3 | wc -l
3                                          # ...and yet
```

`strace` records exactly **one** `execve` for a session like that: bash itself.

This is a toy, and it is meant to be one. It is also a real conformance
exercise: every utility is checked against GNU coreutils, byte for byte on
stdout and on exit status, over 5677 comparisons.

## Use it

```sh
. bashtrash.sh
```

Sourcing defines each utility as a shell function, which shadows the real
binary for the rest of the session. Nothing is installed, nothing is
overwritten, and `unset -f cat` gives you the real one back.

Run the test suite with:

```sh
./test.sh
```

## What is implemented

32 of the 160 utilities in POSIX.1-2017, as of now.

| utility | synopsis |
| --- | --- |
| `asa` | `asa [file...]` |
| `basename` | `basename string [suffix]` |
| `cat` | `cat [-u] [file...]` |
| `cksum` | `cksum [file...]` |
| `cmp` | `cmp [-l\|-s] file1 file2` |
| `comm` | `comm [-123] file1 file2` |
| `cut` | `cut -b list [-n] [file...]` · `cut -c list [file...]` · `cut -f list [-d delim] [-s] [file...]` |
| `date` | `date [-u] [+format]` |
| `dirname` | `dirname string` |
| `env` | `env [-i] [name=value]... [utility [argument...]]` |
| `expand` | `expand [-t tablist] [file...]` |
| `expr` | `expr operand...` |
| `fold` | `fold [-bs] [-w width] [file...]` |
| `head` | `head [-n number] [file...]` |
| `id` | `id [user]` · `id -G [-n] [user]` · `id -g [-nr] [user]` · `id -u [-nr] [user]` |
| `nl` | `nl [-p] [-b type] [-d delim] [-f type] [-h type] [-i incr] [-l num] [-n format] [-s sep] [-v start] [-w width] [file]` |
| `od` | `od [-v] [-A base] [-j skip] [-N count] [-t type]... [file...]` |
| `paste` | `paste [-s] [-d list] file...` |
| `pathchk` | `pathchk [-p] pathname...` |
| `sleep` | `sleep time` |
| `split` | `split [-l line_count] [-a suffix_length] [file [name]]` · `split -b n[k\|m] ...` |
| `strings` | `strings [-a] [-t format] [-n number] [file...]` |
| `tabs` | `tabs [-n] [+m[n]] [n1[,n2,...]]` |
| `tail` | `tail [-f] [-c number \| -n number] [file]` |
| `tee` | `tee [-ai] [file...]` |
| `tr` | `tr [-c\|-C] [-s] string1 string2` · `tr -d [-c\|-C] string1` · `tr -s ...` · `tr -ds ...` |
| `tsort` | `tsort [file]` |
| `tty` | `tty` |
| `uname` | `uname [-amnrsv]` |
| `unexpand` | `unexpand [-a] [-t tablist] [file...]` |
| `uniq` | `uniq [-c\|-d\|-u] [-f fields] [-s chars] [input [output]]` |
| `wc` | `wc [-c\|-m] [-lw] [file...]` |

Including the parts that are easy to forget: `--` ends the options and a lone
`-` names standard input; `tail -n +5` counts from the start of the file while
`-n 5` counts from the end; an unterminated last line is still a line; `-n 0`
selects nothing; diagnostics go to standard error; `cat` carries on past a file
it cannot open and *then* exits non-zero; `tail` takes at most one file operand
and ignores `-f` when standard input is a pipe.

## How some of it works

A few of these were more interesting than expected.

**NUL bytes.** A bash variable cannot hold one, which would normally mean
mangling any binary input. So everything is read as NUL-delimited *blocks*
(`read -r -d '' -n 65536`): each block is NUL-free and therefore storable, and
the NULs that separated them are written back out explicitly. Arbitrary binary
survives byte for byte. Reading one byte at a time with `read -N 1` is not an
alternative — it discards NUL bytes silently.

**Byte semantics.** In a multibyte locale `${#s}`, `${s:i:n}` and `read -n` all
count *characters*, so `tail -c 6` cheerfully returned seven bytes. Every
function forces `LC_ALL=C` internally, which bash restores on return. `wc -m` is
the one place the caller's locale is deliberately put back.

**`tail` doesn't slurp.** It keeps a rolling window of just the answer, so peak
memory tracks the size of the *output*, not the input: `tail -n 5` over a 2.6 MB
file adds about 4 KB to peak RSS. It peels lines off the end with suffix removal
rather than counting newlines over the whole buffer — which is what took it from
6.4 s to 0.17 s.

**`tail -f` sleeps without `sleep(1).`** A pipe opened for both reading *and*
writing never reports end of file, so `read -t` on it simply burns its timeout
and returns. That is also how `sleep` itself works here.

**`wc` aligns its columns**, which the format string in the standard doesn't
describe. One count for one input is printed bare; otherwise every field is
padded to the width of the combined size of the regular-file inputs. Since
`stat()` is unreachable, the counts for every input are gathered *before*
anything is written — the bytes have to be counted to be known.

## Testing

```console
$ ./test.sh
### cat
### tail
### fuzz
### id
...
==== pass=5677 fail=0 ====
```

Every case runs twice — once through the bash function, once through the system
coreutils — comparing stdout byte for byte and comparing exit status. That
covers embedded NULs, unterminated lines, empty files, 300 KB of random binary,
and every sign and magnitude of `-n`/`-c`. A fuzz pass repeats at block sizes
from 1 byte to 64 KiB to exercise the block-boundary paths. `id` is checked in
every option form against every user in `/etc/passwd`, and where `setpriv` is
available, against processes whose real and effective IDs differ. A final case
runs everything with an empty `PATH`.

## Limitations, and why they exist

The interesting limitation isn't that the remaining utilities are unwritten.
It's that **a large part of POSIX cannot be written this way at all.**

Bash has no builtin that mutates the filesystem. Not one:

```console
$ type -t mkdir rmdir rm unlink ln mv chmod chown touch
file
file
file
...
```

There is no syscall escape hatch — no `stat`, no `ioctl`, no `AF_UNIX` socket.
So these are permanently out of reach, not merely unfinished:

| what's missing | why |
| --- | --- |
| `mkdir` `rmdir` `rm` `unlink` `link` `ln` `mv` `chmod` `chgrp` `chown` `mkfifo` `touch` | no builtin mutates the filesystem |
| `df` `du` `ls -l` `find -size/-perm/-mtime` `pax` | no numeric `stat()` of any kind — nothing in `/proc` carries free space either |
| `stty` `vi` `ex` `more` `talk` | no termios: no raw mode |
| `nice` `renice` `newgrp` `ipcrm` `logger` | `setpriority()`, `setgid()`, SysV IPC, `AF_UNIX` — bash only speaks TCP/UDP |
| `at` `batch` `crontab` `lp` `uucp` `uustat` `uux` | need a daemon or a mode-protected spool |
| `c99` `fort77` `strip` | must produce an executable, which needs the exec bit |
| `time` | `time` is a bash reserved word: `time() { ... }` will not even parse |
| `getconf` | `sysconf()` values are compile-time constants, readable nowhere |

Some of those are only *partly* dead: `cp` copies contents fine and fails POSIX
only on setting the destination's mode; bare `ls` works via globbing, it's `ls -l`
that can't; most of `find` works, just not the metadata predicates.

So the arithmetic looks like this:

| | count |
| --- | ---: |
| POSIX.1-2017 utilities | 160 |
| implemented here | 32 |
| already bash builtins (`cd`, `echo`, `printf`, `read`, `test`, `kill`, `wait`, …) | 22 |
| **unreachable from a builtin** | **40** |
| reachable, not yet written | 66 |

**The ceiling is 98 of 160**, or about 61% of the standard. Getting past that
would need bash's loadable builtins — which are C, and would rather defeat the
point.

The 66 that remain are wildly uneven, too. `true`, `false`, `logname` and
`printf` are afternoons. `awk`, `sed`, `m4`, `bc`, `make`, `lex` and `yacc` are
interpreters and compilers, each larger than everything here put together,
written in a language with no arrays of structs and no way to turn a character
into an integer except `printf '%d' "'$c"`.

### Smaller deviations, all deliberate

* `uname -a` is the standard's `-a`, exactly `-mnrsv`; GNU adds three fields of
  its own. `uname -m` reports the machine type bash was built for, since
  `uname(2)` is unreachable.
* `cmp -l` uses the `"%d %o %o"` the standard specifies; GNU pads the byte number.
* `tty` identifies the terminal by comparing device and inode against
  `/proc/self/fd/0`, rather than calling `ttyname()`.
* `id` and `logname` can't see users served only by NSS (LDAP, SSSD) — reading
  `/etc/passwd` and `/etc/group` is the only lookup available without `getent`.
* `id` takes one operand, as POSIX specifies; GNU accepts several.
* `date` can display but not set: writing the clock is a syscall.
* `env -i` leaks `SHLVL` and `_` when combined with assignments, because bash
  injects both into any child it starts.
* In `unexpand`, behaviour past the end of an explicit `-t` list is
  implementation-defined; a run of blanks holding a literal tab is left as it was
  rather than flattened.
* `nl -bp` matches with bash's `=~`, an ERE, where the standard asks for a BRE.
* Everything is byte oriented; multibyte locales are not interpreted.

## Speed

Measured on a 2.6 MB text file, in this container:

| | throughput |
| --- | ---: |
| `cat` | ~33 MB/s |
| `tail -n 5` | ~9 MB/s |
| `wc -l` | ~3 MB/s |
| `tr a-z A-Z` | ~12 KB/s |

`cat` only moves whole blocks around, so it stays fast. `tr` has to touch
every single byte inside the interpreter, and it shows. Fast enough to be
useful, slow enough to remind you what it is.
