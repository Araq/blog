
import re, strutils
export re, strutils

template perlish*(body: untyped) {.dirty.} =
  {.this: it.}
  block:
    proc main(it: var string) =
      body

    var buffer = newStringOfCap(80)
    main buffer

template readline*(it: var string): untyped = stdin.readLine(it)

proc print*(args: varargs[string, `$`]) =
  for x in args: stdout.write x

proc ensureLen*[T](s: var seq[T]; len: int) =
  ## helper to mimic Perl's array accesses.
  if len > s.len: setLen(s, len)

converter toInt*(x: string): int = parseInt(x)
