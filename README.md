# bashtrash
Bullshit. Please ignore.

---

POSIX utilities implemented with nothing but bash builtins.
No forks, no execs, no coreutils — the functions keep working in a shell with
an empty `$PATH`.

## Use

    . bashtrash.sh

Sourcing defines each of them as a shell function, shadowing the
real utility for the rest of the session.

## What is implemented

| utility     | synopsis                                                  |
| ----------- | --------------------------------------------------------- |
| `basename`  | `basename string [suffix]`                                |
| `cat`       | `cat [-u] [file...]`                                      |
| `cmp`       | `cmp [-l|-s] file1 file2`                                 |
| `comm`      | `comm [-123] file1 file2`                                 |
| `cut`       | `cut -b list [-n] [file...]`                              |
|             | `cut -c list [file...]`                                   |
|             | `cut -f list [-d delim] [-s] [file...]`                   |
| `dirname`   | `dirname string`                                          |
| `expand`    | `expand [-t tablist] [file...]`                           |
| `fold`      | `fold [-bs] [-w width] [file...]`                         |
| `head`      | `head [-n number] [file...]`                              |
| `id`        | `id [user]`                                               |
|             | `id -G [-n] [user]`                                       |
|             | `id -g [-nr] [user]`                                      |
|             | `id -u [-nr] [user]`                                      |
| `paste`     | `paste [-s] [-d list] file...`                            |
| `sleep`     | `sleep time`                                              |
| `tail`      | `tail [-f] [-c number \| -n number] [file]`               |
| `tee`       | `tee [-ai] [file...]`                                     |
| `tr`        | `tr [-c|-C] [-s] string1 string2`                         |
|             | `tr -s [-c|-C] string1`                                   |
|             | `tr -d [-c|-C] string1`                                   |
|             | `tr -ds [-c|-C] string1 string2`                          |
| `tty`       | `tty`                                                     |
| `uname`     | `uname [-amnrsv]`                                         |
| `unexpand`  | `unexpand [-a] [-t tablist] [file...]`                    |
| `uniq`      | `uniq [-c|-d|-u] [-f fields] [-s chars] [input [output]]` |
| `wc`        | `wc [-c|-m] [-lw] [file...]`                              |

That is 20 of the 160 utilities in the standard.  Another 22 (`cd`,
`echo`, `printf`, `read`, `test`, `kill`, `wait` and friends) bash already
provides as builtins, and 39 are unreachable from a builtin at all -- see
**Limits** below.
The conformance target is POSIX.1-2017, including the parts that are easy to
forget: `--` ends the options and a lone `-` is an operand naming standard
input; `-n +5` counts from the start of the file while `-n 5` counts from the
end; an unterminated last line is still a line; `-n 0` selects nothing;
diagnostics go to standard error; `cat` carries on past a file it cannot open
and then exits non-zero; `tail` takes at most one file operand, and ignores
`-f` when standard input is a pipe.

`tail -number`, as in `tail -20`, is accepted as the obsolescent historical
spelling of `-n number`. `id -a` is accepted and ignored, as elsewhere.

`head` accepts `-c` (the Issue 8 spelling of a long-standing extension)
`cmp -l` uses the `"%d %o %o"` the standard gives; GNU pads the byte
number to the width of the file size.  Where an explicit `-t` list runs out
in `unexpand`, behaviour past the last stop is implementation-defined: a run
of blanks holding a literal tab is left as it was rather than flattened.
and the obsolescent `head -number`.  `wc` aligns its columns the way every
wc does, rather than the single spaces the format string in the standard
implies.  `uname -a` is the standard's `-a`, exactly `-mnrsv`; GNU adds
processor, hardware platform and operating system to its own.

`id` reports the *real* IDs in its default format and the *effective* ones
for `-u` and `-g`, with `euid=`/`egid=` appearing only when they differ. Its
two group lists are deliberately different, matching every other `id`: `-G`
gives the effective, real and supplementary IDs alike, while the `groups=`
field of the default format lists the supplementary affiliations with the
effective group prepended when it is not already among them — the real group
does not appear there. When `-n` is asked for an ID that maps to no name, the
number is printed instead and the exit status still reports the failure.

## How it stays byte exact

A bash variable cannot hold a NUL byte, so input is read as NUL delimited
blocks with `read -r -d '' -n $_BT_BLOCK`: every block is NUL free and can
therefore live in a variable, and the NULs that separated them are written
back out explicitly. Arbitrary binary input survives byte for byte. Reading
one byte at a time with `read -N 1` is not an alternative — it discards NUL
bytes silently.

`tail` keeps a rolling window of just the answer, so peak memory tracks the
size of the output rather than of the input: `tail -n 5` over a 2.6 MB file
holds a few kilobytes and adds about 4 KB to peak RSS.

`tail -f` has to wait without `sleep(1)`. A pipe opened for both reading and
writing never reports end of file, so `read -t` on it simply burns its
timeout and returns.

`id` needs identifiers bash does not expose. `$UID` and `$EUID` exist, but
there is no `$EGID`, and `$GROUPS` is not the supplementary list. Linux
publishes all of them in `/proc/self/status`, which is a file the `read`
builtin can parse; `$UID`, `$EUID` and `$GROUPS` are the fallback where that
is missing. Names come from reading `/etc/passwd` and `/etc/group` directly.

## Testing

    ./test.sh

Every case runs twice, once through the bash functions and once through the
system coreutils, comparing stdout byte for byte and comparing exit status:
5344 comparisons, taking a few minutes.

`cat` and `tail` are checked over embedded NULs, unterminated lines, empty
files, 300 KB of random binary, and every sign and magnitude of `-n`/`-c`,
with the fuzz pass repeating at block sizes from 1 byte to 64 KiB to exercise
the block-boundary and segment-splitting paths. `id` is checked in every
option form against every user in `/etc/passwd`, so whichever mix of primary,
supplementary and unmapped groups the machine has gets covered; where
`setpriv` is available it also runs against processes whose real and
effective IDs differ, which is otherwise unreachable from a test.

A final case runs all three tools with an empty `PATH`; `strace` shows a
single `execve`, bash itself.

## Limits

* Users served only by NSS (LDAP, SSSD) are invisible to `id`: reading
  `/etc/passwd` and `/etc/group` is the only lookup available without
  `getent`.
* `id` takes one operand, as POSIX specifies; GNU accepts several.
* `uname -m` reports the machine type bash was built for, since uname(2)
  is not reachable; `tty` identifies the terminal by comparing device and
  inode against `/proc/self/fd/0` rather than calling ttyname().
* Byte semantics are forced inside every function (`LC_ALL=C`), because
  `${#s}`, `${s:i:n}` and `read -n` otherwise count characters, not bytes.
  `wc -m` is the one place the caller's locale is put back.
