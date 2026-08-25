# bashtrash
Bullshit. Please ignore.

---

POSIX `cat`, `tail` and `whoami`, implemented with nothing but bash builtins.
No forks, no execs, no coreutils — the functions keep working in a shell with
an empty `$PATH`.

## Use

    . bashtrash.sh

Sourcing defines `cat`, `tail` and `whoami` as shell functions, shadowing the
real utilities for the rest of the session.

## What is implemented

| tool     | synopsis                                    |
| -------- | ------------------------------------------- |
| `cat`    | `cat [-u] [file...]`                        |
| `tail`   | `tail [-f] [-c number \| -n number] [file]` |
| `whoami` | `whoami`                                    |

The conformance target is POSIX.1-2017, including the parts that are easy to
forget: `--` ends the options and a lone `-` is an operand naming standard
input; `-n +5` counts from the start of the file while `-n 5` counts from the
end; an unterminated last line is still a line; `-n 0` selects nothing at all;
diagnostics go to standard error; `cat` carries on past a file it cannot open
and then exits non-zero; `tail` takes at most one file operand, and ignores
`-f` when standard input is a pipe.

`tail -number`, as in `tail -20`, is accepted as the obsolescent historical
spelling of `-n number`.

`whoami` is not a POSIX utility — the standard spells it `id -un` — so it
follows historical BSD/GNU behaviour: it prints the name of the *effective*
user, looked up by `$EUID`. Not the value of `$USER`, which is inherited,
writable, and says nothing about who the process actually runs as.

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

## Testing

    ./test.sh

Every case runs twice, once through the bash functions and once through the
system coreutils, comparing stdout byte for byte and comparing exit status:
4680 comparisons covering embedded NULs, unterminated lines, empty files,
300 KB of random binary, and every sign and magnitude of `-n`/`-c`. The fuzz
pass repeats at block sizes from 1 byte to 64 KiB to exercise the
block-boundary and segment-splitting paths. A final case runs all three tools
with an empty `PATH`; `strace` shows a single `execve`, bash itself.

## Limits

* Users served only by NSS (LDAP, SSSD) are invisible to `whoami`: reading
  `/etc/passwd` is the only lookup available without `getent`.
* Everything is byte oriented; multibyte locales are not interpreted.
