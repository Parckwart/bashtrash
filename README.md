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

84 of the 160 utilities in POSIX.1-2017, as of now.

| utility | synopsis |
| --- | --- |
| `admin` | `admin -i[file] [-n] [-r SID] [-y comment] [-fflag] s.file` · `admin [-a user] [-e user] [-fflag] [-dflag] [-t[file]] s.file` |
| `ar` | `ar -d\|-m\|-p\|-q\|-r\|-t\|-x [-abcisuv] [posname] archive [file...]` |
| `asa` | `asa [file...]` |
| `awk` | `awk [-F sepstring] [-v assignment]... program [argument...]`<br>`awk [-F sepstring] -f progfile... [-v assignment]... [argument...]` |
| `basename` | `basename string [suffix]` |
| `bc` | `bc [-l] [file...]` |
| `cal` | `cal [[month] year]` |
| `cat` | `cat [-u] [file...]` |
| `cflow` | `cflow [-r] [-d num] [-i incl] [-D name[=def]]... [-I dir]... [-U name]... file...` |
| `cksum` | `cksum [file...]` |
| `cmp` | `cmp [-l\|-s] file1 file2` |
| `comm` | `comm [-123] file1 file2` |
| `compress` | `compress [-cfv] [-b bits] [file...]` |
| `csplit` | `csplit [-ks] [-f prefix] [-n number] file arg...` |
| `ctags` | `ctags [-a] [-f tagsfile] pathname...`<br>`ctags -x pathname...` |
| `cut` | `cut -b list [-n] [file...]` · `cut -c list [file...]` · `cut -f list [-d delim] [-s] [file...]` |
| `cxref` | `cxref [-cs] [-o file] [-w num] [-D name[=def]]... [-I dir]... [-U name]... file...` |
| `date` | `date [-u] [+format]` |
| `dd` | `dd [operand...]` (`if` `of` `bs` `ibs` `obs` `count` `skip` `conv`) |
| `delta` | `delta [-nps] [-r SID] [-y comment] [-m mrlist] s.file...` |
| `diff` | `diff [-bi] [-e] file1 file2` |
| `dirname` | `dirname string` |
| `ed` | `ed [-p string] [-s] [file]` |
| `env` | `env [-i] [name=value]... [utility [argument...]]` |
| `expand` | `expand [-t tablist] [file...]` |
| `expr` | `expr operand...` |
| `file` | `file [-dh] [-M file] [-m file] file...`<br>`file -i [-h] file...` |
| `fold` | `fold [-bs] [-w width] [file...]` |
| `fuser` | `fuser [-cfu] file...` |
| `gencat` | `gencat catfile msgfile...` |
| `get` | `get [-e] [-k] [-p] [-s] [-g] [-r SID] s.file...` |
| `grep` | `grep [-E\|-F] [-c\|-l\|-q] [-insvx] [-e pattern] [-f file] [file...]` |
| `head` | `head [-n number] [file...]` |
| `iconv` | `iconv [-cs] [-f frommap] [-t tomap] [file...]` · `iconv -l` |
| `id` | `id [user]` · `id -G [-n] [user]` · `id -g [-nr] [user]` · `id -u [-nr] [user]` |
| `ipcs` | `ipcs [-qms]` |
| `join` | `join [-a n] [-e s] [-o list] [-t c] [-v n] [-1 f] [-2 f] file1 file2` |
| `lex` | `lex [-t] [-n\|-v] file...` |
| `locale` | `locale [-a\|-m]` · `locale [-ck] name...` |
| `logname` | `logname` |
| `m4` | `m4 [-s] [-D name[=value]]... [-U name]... [file...]` |
| `mailx` | `mailx [-s subject] address...`<br>`mailx -e`<br>`mailx [-HiNn] [-F] [-u user]`<br>`mailx -f [-HiNn] [-F] [file]` |
| `make` | `make [-eiknpqrSst] [-f makefile]... [macro=value]... [target_name...]` |
| `man` | `man [-k] name...` |
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
| `yacc` | `yacc [-dltv] [-b file_prefix] [-p sym_prefix] grammar` |
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

**`bc` counts on its fingers.** The numbers are decimal strings and the
arithmetic is done on them a digit at a time, which is what arbitrary precision
comes to when the only integers available are the shell's: 2^200 comes out to
all sixty-one digits. The `%` operator follows the standard's rule to the
letter — `a - (a/b)*b`, with the division taken to the current scale and nothing
rounded off the multiplication — which is why `1 % 6.28318` has ten digits after
the point rather than five. The library behind `-l` is written in bc itself and
read by the same parser as anything else; `a(1)`, `e(1)`, `l(2)`, `s(1)` and
`c(1)` all agree with the real bc to every one of the twenty digits it prints.

**`awk` is a language, so it gets a lexer, a parser and a tree.** The tree
lives in half a dozen parallel arrays — a kind, three or four children and a
name to a node — because that is what a language with no structs leaves you.
Its regular expressions are handed to the shell's own `=~`, which is the ERE
matcher the standard asks for; and since `=~` reports the leftmost match, the
text it matched cannot occur any earlier in the string than the match itself,
which is how `match()` works out RSTART without hunting for it. Numbers are
decimal strings on bc's arithmetic, with a fast path through the shell's own
`$(( ))` for the whole ones, which is most of them; `sin`, `log`, `exp` and
`atan2` are the same series bc's library uses, agreeing with the real awk to
more digits than a double has. Whether a comparison is done on numbers or on
text follows the standard's rule about where the value came from, so `$1 == 0`
is true for a field holding `0.0` and false for one holding `x`.

**`ctags` reads C without a C compiler**, which the standard admits is the
only way: it says ctags "attempts to" find what a file defines, because
anything short of the real preprocessor can be fooled. This one walks the
file a character at a time keeping track of comments, strings, brackets and
braces, and takes a name to be a function when a bracketed list follows it at
file scope and a brace follows that -- with the old style parameter
declarations in between allowed, which is what tells a definition from a
declaration. Braces inside strings and comments are counted by nobody, and
the tag `main` is written out as `M` and the file's name, as the standard
asks.

**`man` had to learn to read gzip**, since that is how every page on a
modern system is kept. Deflate is a stream of blocks, each either stored or
coded with a Huffman code, and each symbol either a byte or a length and a
distance saying to copy what came before. The codes are canonical, so a
symbol can be read a bit at a time without building a table: count how many
codes there are of each length, and at each length ask whether the code read
so far falls in that range. Every manual page on this machine comes back
byte for byte the same as `zcat` gives, and a page of ordinary size takes
about half a second. Then the roff macros are read and the text filled and
indented under its headings, which is what a manual page has always looked
like.

**`yacc` works out the lookaheads the hard way.** The LR(0) machine of item
sets comes first; what makes it LALR(1) is knowing which token can follow each
item, and that is settled in the two steps the textbooks give: a closure with
a marker lookahead says which lookaheads a state generates on its own and
which it hands on to another state, and then the handing-on is run to a
standstill over a worklist. Conflicts are settled the way yacc settles them --
precedence and associativity where a rule and a token both have them, the
shift otherwise, and the rule written first when two reductions collide -- and
the counts are reported. A state whose only move is one reduction takes it
without reading a token, which is why the actions of a rule can run before an
error further along is noticed, exactly as they do with the real yacc. The
grammar of C itself, all 215 rules of it, comes out in about ten seconds with
the one shift/reduce conflict everybody's yacc reports for it.

**`lex` builds a machine and writes it out as C.** Each rule's regular
expression becomes a machine by Thompson's construction -- a state for every
character, an empty step for every choice -- the machines are joined at a
common start, and the subset construction turns the lot into one deterministic
machine whose states are sets of the old ones. Before that happens the 256
bytes are sorted into classes that behave alike, which is what keeps the table
to a dozen columns instead of 256. What comes out is a table of transitions, a
list of the rules each state accepts, and a scanner that takes the longest
match and, among matches of the same length, the rule written first. `REJECT`
works because the scanner remembers every place it could have stopped and
every rule that would have accepted there, so it can walk back down the list;
that list is the only reason the tables carry more than one rule per state.
The whole thing is checked by compiling what it writes and running it.

**`gencat` writes a hash table, and picks its shape the way gencat does.**
A message catalogue is a table taking a set and a message number to a place in
a pool of strings; the hash is `(set + 1) * message` modulo the table's width,
collisions go into further planes of the same table, and the whole table is
written twice, once in each byte order, so either end can read it. The width
and the number of planes are chosen by trying widths from `1 + messages / 5`
upwards and keeping the one whose width times depth is smallest, which is
exactly the search the C library's own gencat makes — get it wrong and the
file is still readable but no longer byte for byte the same.

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
| implemented here | 84 |
| already bash builtins (`cd`, `echo`, `printf`, `read`, `test`, `kill`, `wait`, …) | 22 |
| **unreachable from a builtin** | **52** |
| reachable, not yet written | 2 |

**The ceiling is 86 of 160**, or about 54% of the standard. Getting past that
would need bash's loadable builtins — which are C, and would rather defeat the
point.

The 2 that remain are `localedef`, which compiles locale definitions into a
binary whose format nobody has written down -- it is glibc's own, and the
only thing that reads it is glibc -- and `sh`, whose whole purpose, running a
program, is the one thing this library will not do.

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
* `awk` cannot start a program, so `system()` returns -1, `"cmd" | getline`
  returns -1 and `print | "cmd"` is an error — the three places awk asks for a
  shell of its own. Its arithmetic is exact decimal rather than binary floating
  point, which shows up in the corners: `0.1 + 0.2 == 0.3` is true here and
  false everywhere else, and a whole number keeps all its digits where a double
  would have rounded it. `substr` with a starting place below one follows the
  standard, counting the characters that are really there, which is what gawk
  does and not what mawk does; a `printf` given fewer arguments than
  conversions treats the missing ones as empty, as the standard says, rather
  than stopping.
* `mailx` has no mailer to hand a message to, so it delivers: a message for a
  user on this machine is appended to their mailbox in the format every
  mailbox has, and an address with a host in it is refused rather than
  silently dropped. The reading side is all there -- the message states the
  standard describes, the message lists, and the commands that move messages
  about -- except for `!`, `shell`, `pipe`, `edit`, `visual` and `folders`,
  each of which exists to run a program.
* `man` reads the roff macros a manual page is written with -- headings,
  paragraphs, tagged lists, indents, fonts and the escapes -- and fills the
  text under them; it is not a roff, and a page that leans on the rest of
  roff's language will come out plainer than it was meant to. `-k` has no
  index to consult, so it reads every page it can find, which is slow but
  right. The gzip reader behind it holds the page in a shell variable, so a
  file with a NUL byte in it is beyond it -- which no manual page is.
* `yacc` writes the tables out in full -- a row for every state and a column
  for every token -- where the real yacc packs them into overlapping arrays.
  The parser it writes is the same parser; the file is just bigger. There is
  no yacc library to link against, so a grammar has to bring its own `main`
  and `yyerror`, as it would with `-l y` on a system that has one, and `-l`
  is accepted with nothing to do since no `#line` is ever written.
* `lex` writes a scanner that reads all of its input into memory rather than
  through a sliding window, which is what makes `unput` and `yyless` simple
  and what would make it a poor choice for a stream that never ends. There is
  no lex library here to link against, so a program has to bring its own
  `main` and `yywrap`, exactly as it would with `-l l` on a system that has
  one. Trailing context has to be of a fixed length -- `$` is, and so is
  nearly every use of `/` in practice -- and a variable one is refused rather
  than quietly mismatched.
* `file` answers with the strings the standard's table asks for -- `empty`,
  `directory`, `character special`, `cpio archive`, `commands text`,
  `c program text` and the rest -- rather than the sentences GNU's file
  writes, which are longer and say more. It reads the four column magic files
  the standard describes for `-m` and `-M`, including the `>` lines that
  carry a test on. Two things are out of reach: there is no `readlink`, so a
  symbolic link is reported by where it leads rather than by what it says;
  and an ELF shared object that has an interpreter is called a pie
  executable, since telling one from a library for certain means reading the
  dynamic section, which lies further into the file than a shell can afford
  to read a byte at a time.
* `cxref` has no format to match: the standard leaves the layout of the
  listing open and asks only that the name, the file, the function the name
  was written in and the line numbers all be there, with a star on the
  declaring reference, so the layout here is this one's own. A name is taken
  to be declared where a type stands in front of it, which is a guess, but the
  same guess a reader makes. `-D`, `-I` and `-U` are accepted and ignored.
* `cflow` reads C source, which is what there is to read: object files and
  assembler, which the standard also allows as input, would need a symbol
  table walk and an assembler's idea of a call. `-D`, `-I` and `-U` are
  accepted and ignored, there being no preprocessor to pass them to, and a
  `.l` or `.y` file is read as the C around its rules. The graph it draws for
  the program in the standard's own example is the graph the standard prints,
  line for line.
* `ctags` writes out function definitions, type definitions and macros, which
  is what the standard requires, and nothing else; structures, unions, enums
  and global variables are among the things it is allowed to leave out, and
  does. `-x` uses the format the standard gives, one space between the
  fields, where the historical ctags lines the columns up. `-a` reads what is
  already in the tags file and sorts the lot, since the standard asks for the
  file to be sorted; the historical one simply appends.
* `gencat` writes the catalogue with the low byte first, as every machine
  this is likely to run on does; the table it writes second is the big endian
  one, which is what the C library reads on a big endian machine. `$delset`
  takes the set away, and a message line with no text takes the message away,
  both as the standard says; the C library's gencat quietly ignores the first
  and leaves an empty message behind for the second.
* `make` hands each command line to a subshell of the shell it is running in,
  rather than to `/bin/sh`, so a recipe can use anything this library defines
  and nothing it does not. Whether a target is out of date is decided with the
  shell's own `-nt`, which is the one question about a file's timestamp a shell
  can answer. `-t` has no `utime()` to call, so it reads the file and writes it
  straight back; the write is what moves the timestamp. `-p` prints every macro
  and every rule, in a layout of its own — no two makes agree on that one.
  `-S` and `-j` are accepted and ignored: there is nothing here to run in
  parallel anyway.
* `bc` is slow, in the way everything here is slow: `a(1)` to twenty digits
  takes about four seconds, and `c(1)` about fifteen. Every operation goes
  through the same parser and the same digit-at-a-time arithmetic.
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
