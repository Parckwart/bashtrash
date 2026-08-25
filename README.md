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
exercise: wherever this machine has the utility already, every one of these is
checked against it, byte for byte on standard output and on exit status.

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

72 of the 160 utilities in POSIX.1-2017, as of now.

| utility | synopsis |
| --- | --- |
| `admin` | `admin -i[file] [-n] [-r SID] [-y comment] [-fflag] s.file` · `admin [-a user] [-e user] [-fflag] [-dflag] [-t[file]] s.file` |
| `ar` | `ar -d\|-m\|-p\|-q\|-r\|-t\|-x [-abcisuv] [posname] archive [file...]` |
| `asa` | `asa [file...]` |
| `basename` | `basename string [suffix]` |
| `cal` | `cal [[month] year]` |
| `cat` | `cat [-u] [file...]` |
| `cksum` | `cksum [file...]` |
| `cmp` | `cmp [-l\|-s] file1 file2` |
| `comm` | `comm [-123] file1 file2` |
| `compress` | `compress [-cfv] [-b bits] [file...]` |
| `csplit` | `csplit [-ks] [-f prefix] [-n number] file arg...` |
| `cut` | `cut -b list [-n] [file...]` · `cut -c list [file...]` · `cut -f list [-d delim] [-s] [file...]` |
| `date` | `date [-u] [+format]` |
| `dd` | `dd [operand...]` (`if` `of` `bs` `ibs` `obs` `count` `skip` `conv`) |
| `delta` | `delta [-nps] [-r SID] [-y comment] [-m mrlist] s.file...` |
| `diff` | `diff [-bi] [-e] file1 file2` |
| `dirname` | `dirname string` |
| `ed` | `ed [-p string] [-s] [file]` |
| `env` | `env [-i] [name=value]... [utility [argument...]]` |
| `expand` | `expand [-t tablist] [file...]` |
| `expr` | `expr operand...` |
| `fold` | `fold [-bs] [-w width] [file...]` |
| `fuser` | `fuser [-cfu] file...` |
| `get` | `get [-e] [-k] [-p] [-s] [-g] [-r SID] s.file...` |
| `grep` | `grep [-E\|-F] [-c\|-l\|-q] [-insvx] [-e pattern] [-f file] [file...]` |
| `head` | `head [-n number] [file...]` |
| `iconv` | `iconv [-cs] [-f frommap] [-t tomap] [file...]` · `iconv -l` |
| `id` | `id [user]` · `id -G [-n] [user]` · `id -g [-nr] [user]` · `id -u [-nr] [user]` |
| `ipcs` | `ipcs [-qms]` |
| `join` | `join [-a n] [-e s] [-o list] [-t c] [-v n] [-1 f] [-2 f] file1 file2` |
| `locale` | `locale [-a\|-m]` · `locale [-ck] name...` |
| `logname` | `logname` |
| `m4` | `m4 [-s] [-D name[=value]]... [-U name]... [file...]` |
| `nl` | `nl [-p] [-b type] [-d delim] [-f type] [-h type] [-i incr] [-l num] [-n format] [-s sep] [-v start] [-w width] [file]` |
| `nm` | `nm [-APv] [-efox] [-g\|-u] [-t format] file...` |
| `nohup` | `nohup utility [argument...]` |
| `od` | `od [-v] [-A base] [-j skip] [-N count] [-t type]... [file...]` |
| `paste` | `paste [-s] [-d list] file...` |
| `patch` | `patch [-blNR] [-c\|-e\|-n\|-u] [-D define] [-i patchfile] [-o outfile] [-p num] [-r rejectfile] [file]` |
| `pathchk` | `pathchk [-p] pathname...` |
| `pr` | `pr [+page] [-column] [-adFmrt] [-h header] [-l lines] [-o offset] [-w width] [file...]` |
| `prs` | `prs [-a] [-d dataspec] [-r SID] [-e\|-l] s.file...` |
| `ps` | `ps [-aA] [-defl] [-G grouplist] [-o format]... [-p proclist] [-t termlist] [-U userlist] [-g grouplist] [-n namelist] [-u userlist]` |
| `rmdel` | `rmdel -r SID s.file...` |
| `sact` | `sact s.file...` |
| `sccs` | `sccs [-r] [-d path] [-p path] command [options] [operands]` |
| `sed` | `sed [-n] script [file...]` · `sed [-n] [-e script]... [-f file]... [file...]` |
| `sleep` | `sleep time` |
| `sort` | `sort [-m] [-o out] [-bdfinru] [-t char] [-k keydef]... [file...]` · `sort -c ...` |
| `split` | `split [-l line_count] [-a suffix_length] [file [name]]` · `split -b n[k\|m] ...` |
| `strings` | `strings [-a] [-t format] [-n number] [file...]` |
| `tabs` | `tabs [-n] [+m[n]] [n1[,n2,...]]` |
| `tail` | `tail [-f] [-c number \| -n number] [file]` |
| `tee` | `tee [-ai] [file...]` |
| `tput` | `tput [-T type] operand [parm...]` |
| `tr` | `tr [-c\|-C] [-s] string1 string2` · `tr -d [-c\|-C] string1` · `tr -s ...` · `tr -ds ...` |
| `tsort` | `tsort [file]` |
| `tty` | `tty` |
| `uname` | `uname [-amnrsv]` |
| `uncompress` | `uncompress [-cfv] [file...]` |
| `unexpand` | `unexpand [-a] [-t tablist] [file...]` |
| `unget` | `unget [-ns] [-r SID] s.file...` |
| `uniq` | `uniq [-c\|-d\|-u] [-f fields] [-s chars] [input [output]]` |
| `uudecode` | `uudecode [-o outfile] [file]` |
| `uuencode` | `uuencode [-m] [file] decode_pathname` |
| `val` | `val [-s] [-m name] [-r SID] [-y type] s.file...` |
| `wc` | `wc [-c\|-m] [-lw] [file...]` |
| `what` | `what [-s] file...` |
| `who` | `who [-mTu] [file]` |
| `write` | `write user_name [terminal]` |
| `xargs` | `xargs [-t] [-E eof] [-I repl] [-L n] [-n n] [-s size] [utility [arg...]]` |
| `zcat` | `zcat [file...]` |

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

**terminfo really is a binary file.** `tput` parses it: six 16-bit counts, the
terminal's names, one byte per boolean, one word per number, one offset per
string into a string table, and then the user-defined capabilities after that,
whose *names* live in the file while the standard ones are known only by their
position — so the three lists of names, 44 booleans, 39 numbers and 414 strings,
are part of the source. Capability strings are a stack language of their own
(`%p1%d`, `%i`, `%?%t%e%;`, `%{2}%*`), so there is a small interpreter for it
too. All 23,663 capabilities of every terminal on this machine come out byte for
byte identical to `tput`'s.

**`patch` has to guess where a hunk goes.** A patch says what line to change,
but the file has usually moved on, so a hunk is looked for outwards from where
it claims to be, and each hunk that lands somewhere else shifts the search for
the next one. A hunk with less context at one end than the patch's own context
width is the one that belongs at that end of the file, and is not looked for
anywhere else — which is how an already-applied patch is recognised rather than
applied twice.

**`ps` lines its columns up the way `ps` does.** Each column sits at a fixed
place on the line; a number too wide for its column pushes what follows to the
right, and the next column with padding to spare takes the shift back. Nothing
else reproduces the two-space gap in `SLl  process_api` and the one-space gap in
`Sl claude` from the same listing.

**`m4` puts what a macro expanded to back in front of the cursor** and reads it
again, which is m4's whole model and the reason a macro can call itself. The
arguments of a call are collected with their quoting intact and expanded on
their own before the call is made, so `` `foo' `` arrives as text and `foo`
arrives as whatever `foo` is. `eval` hands its expression to the shell's
arithmetic, but only after checking that every character in it belongs to an
expression — otherwise `eval(PATH)` would quietly become something interesting.

**`ed` is checked by the thing it exists for.** `diff -e` writes an ed script,
so running that script has to turn one file into the other — which exercises
every address form, `a`, `c`, `d`, `s` and `w` at once, against a diff nobody
here wrote. Its regular expressions and its `s` command are `sed`'s: the same
BRE-to-ERE translation, the same substitution loop with `&`, `\1` and the rule
that an empty match where the last one ended is not a second match.

## Testing

```console
$ ./test.sh
### cat
### tail
### fuzz
### id
...
==== pass=6643 fail=0 ====
```

Every case runs twice — once through the bash function, once through the
program the machine already has — comparing standard output byte for byte and
comparing exit status. That covers embedded NULs, unterminated lines, empty
files, 300 KB of random binary, and every sign and magnitude of `-n`/`-c`. A
fuzz pass repeats at block sizes from 1 byte to 64 KiB to exercise the
block-boundary paths. `id` is checked in every option form against every user in
`/etc/passwd`, and where `setpriv` is available, against processes whose real and
effective IDs differ. `patch` is handed random pairs of files in both formats,
forwards, backwards, already applied and shifted down the file. `tput` is asked
for every capability of every terminal the machine has a terminfo entry for.
`ps` gets a process of its own to sit and be inspected. `iconv` converts every
character set it knows to every other. `ar` archives are compared byte for byte
with the ones `ar` builds. `nm` reads the object files the machine has and any
the compiler can be asked for.

Four have nothing here to be compared against, and are held to a property
instead. `ed` replays the script `diff -e` writes, which has to turn one file
into the other. `uuencode` is checked against known encodings and round-tripped
through `uudecode`. The SCCS utilities put a file under `admin`, edit and
`delta` it four times over with random changes, and then have to hand back every
version it ever had, byte for byte, and pass `val` at the end.

A final case runs everything with an empty `PATH`.

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
| `mesg` | reports and sets the group-write bit of a terminal: no `stat()` to read it, no `chmod()` to change it |
| `nice` `renice` `newgrp` `ipcrm` `logger` | `setpriority()`, `setgid()`, SysV IPC, `AF_UNIX` — bash only speaks TCP/UDP |
| `at` `batch` `crontab` `lp` `uucp` `uustat` `uux` | need a daemon or a mode-protected spool |
| `qalter` `qdel` `qhold` `qmove` `qmsg` `qrerun` `qrls` `qselect` `qsig` `qstat` `qsub` | the batch utilities need a batch server to talk to, for the same reason `at` needs a daemon |
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
| implemented here | 72 |
| already bash builtins (`cd`, `echo`, `printf`, `read`, `test`, `kill`, `wait`, …) | 22 |
| **unreachable from a builtin** | **52** |
| reachable, not yet written | 14 |

**The ceiling is 86 of 160**, or about 54% of the standard. Getting past that
would need bash's loadable builtins — which are C, and would rather defeat the
point.

The 14 that remain are wildly uneven. `awk`, `bc`, `make`, `lex` and `yacc`
are interpreters and compilers, each larger than everything here put together,
written in a language with no arrays of structs and no way to turn a character
into an integer except `printf '%d' "'$c"`.

### Smaller deviations, all deliberate

* `uname -a` is the standard's `-a`, exactly `-mnrsv`; GNU adds three fields of
  its own. `uname -m` reports the machine type bash was built for, since
  `uname(2)` is unreachable.
* `cmp -l` uses the `"%d %o %o"` the standard specifies; GNU pads the byte number.
* `tty` identifies the terminal by comparing device and inode against
  `/proc/self/fd/0`, rather than calling `ttyname()`.
* `diff` produces a minimal edit script, but when several are equally
  short the standard does not say which one to emit, and this one does not
  always choose the same as GNU. `-c` and `-u` are not offered at all:
  their headers carry the files' modification times.
* `cal` follows the calendar every cal does: dates before September 1752
  are Julian, and that month is eleven days short.
* `fuser` compares each `/proc` entry with `-ef`, having no `stat()` to read
  a device and inode from. `ipcs` reads `/proc/sysvipc`; `ipcrm`, its other
  half, is not here, because removing an object is a syscall.
* `patch` reads the normal and unified formats. A context diff (`-c`) is not
  one it understands, and `-D`, `-r` and `-N` are accepted and ignored.
* `uuencode` has to guess the mode it writes in the header: without `stat()`
  the only thing a shell can tell about a file's permissions is whether this
  user may execute it, so it writes 0755 for those and 0644 for the rest.
  `uudecode` cannot honour a mode it is given either, for want of `chmod()`.
* `tput init` and `tput reset` write the initialisation strings, which is the
  part that is a terminal's business; the tab stops and terminal modes that
  curses would also set need `ioctl()`.
* `write` decides whether the recipient is accepting messages by trying to open
  their terminal, since the group-write bit `mesg` toggles is exactly what makes
  that open succeed or fail.
* `ps` reads `/proc`, like `who`, `fuser` and `ipcs`, so it wants Linux. Being
  a shell function, it has no process of its own: where the real `ps` lists
  itself, this one lists the shell that called it.
* `ar` writes 0 for the date and the owner and 644 for the mode, which is what
  `ar` itself writes in the deterministic mode it defaults to now — and just as
  well, since `stat()` is unreachable. It does not build the symbol table that
  `ar s` and `ranlib` maintain for archives of object files.
* `compress` writes the LZW format the standard describes, and `gzip` -- which
  still reads it -- gets exactly what it expects out of every setting from 9 to
  16 bits. `uncompress` and `zcat` read it back. The original file would be
  removed by both, which no shell can do, so it is left empty instead. `zcat`
  here is `uncompress -c`, as the standard says, and knows nothing of gzip.
* The SCCS utilities keep the file format SCCS keeps: a checksum, a table of
  deltas newest first, and a body holding every line any version ever had,
  wrapped in the control lines that say which delta put it there and which took
  it away. Branches are not offered — the deltas run 1.1, 1.2, 1.3 up the
  trunk. Nothing in a shell can remove a file, so where SCCS would delete the
  working file or the p-file, these leave it empty instead, which means the
  same thing to every command that looks at it.
* `nm` reads ELF, which is what the object files on this machine are: a header,
  a table of section headers, and among the sections a symbol table and the
  strings its names live in. Without `-D` it looks only at `.symtab`, as `nm`
  does, so a stripped binary has no symbols to show.
* `locale` answers exactly what the environment asks for, and its keyword
  values are the ones the standard fixes for the POSIX locale. Any other
  locale's data lives in a compiled archive that nothing here can read, so
  those are the values that come out whatever `LANG` says. `locale -m` lists
  the character maps this machine has descriptions of, by their file names:
  three of the 236 glibc reports are named differently inside the file, which
  is gzipped and so out of reach.
* `iconv` knows the character sets a shell can carry a table for: the Unicode
  encodings, ASCII, Latin-1, Latin-9 and Windows-1252. Everything is converted
  through code points, so any of them converts to any other; `iconv -l` lists
  those eleven rather than the several hundred glibc has.
* `ed` writes its `?` to standard output, as the standard describes, and the
  message behind it only once `H` has asked for it. Its `!` command has nothing
  to run a command with and says so.
* `who` and `logname` parse the login records themselves, there being no
  `getutent()` to call: on Linux each record is 384 bytes at fixed offsets.
* `id` and `logname` can't see users served only by NSS (LDAP, SSSD) — reading
  `/etc/passwd` and `/etc/group` is the only lookup available without `getent`.
* `id` takes one operand, as POSIX specifies; GNU accepts several.
* `date` can display but not set: writing the clock is a syscall.
* `nohup` should create its output file mode 0600; without `chmod()` it
  lands on whatever the umask allows.
* `dd` reports records and bytes but not a transfer rate, having no clock
  fine enough to measure one.
* `csplit` is supposed to remove the files it created when an operand
  fails. `unlink()` is out of reach, so they are truncated to nothing and
  named on stderr instead.
* `env -i` leaks `SHLVL` and `_` when combined with assignments, because bash
  injects both into any child it starts.
* In `unexpand`, behaviour past the end of an explicit `-t` list is
  implementation-defined; a run of blanks holding a literal tab is left as it was
  rather than flattened.
* `sed` and `nl -bp` match with bash's `=~`, an ERE, where the standard
  asks for a BRE, so the two are translated. `sed` implements the POSIX
  command set; GNU's own extensions, such as the `first~step` address, are
  not there.
* Everything is byte oriented; multibyte locales are not interpreted.

## Speed

Measured on a 2.6 MB text file, in this container:

| | throughput |
| --- | ---: |
| `cat` | ~33 MB/s |
| `cal` | `cal [[month] year]` |
| `tail -n 5` | ~9 MB/s |
| `wc -l` | ~3 MB/s |
| `tr a-z A-Z` | ~12 KB/s |
| `sort` (500 lines) | ~1.3 s |

`cat` only moves whole blocks around, so it stays fast. `tr` has to touch
every single byte inside the interpreter, and it shows. Fast enough to be
useful, slow enough to remind you what it is.
