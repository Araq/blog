==================================
       Araq's Musings
==================================


Goto based exceptions
=====================

*2020-01-08*

The development version of Nim now offers a new exception handling
implementation called "goto based exceptions". It can be enabled via
the new command line switch ``--exceptions:goto``. This mode is also
activated by ``--gc:arc`` for the C target.

This mode implements exceptions in a deterministic way:
Raising an exception is implemented by setting an internal threadlocal error flag that
is queried after every function call that can raise. Neither C's ``setjmp``
mechanism is used nor are C++'s exception handling tables.
The error path is intertwined with the success path
with the resulting instruction cache benefits and drawbacks. Exception
handling is fast and deterministic, there are few reasons to avoid it.

To improve the precision of the compiler's abilities to reason about which
call "can raise", make wise usage of the ``.raises: []`` annotation.

In http://www.filpizlo.com/papers/baker-ccpe09-accurate.pdf J. Baker, et al argue
that in Java exceptions are raised more frequently than in
C++ code and so this approach even wins over the typical C++ exception
implementation which is based on tables and heavily optimized for
the "will not throw" case.

In http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0709r1.pdf Herb Sutter
argues that instead of thread local storage the error indicator itself can be kept
in a CPU flag speeding up these conditional branches and producing shorter machine
code. Nim could do this if only the C compilers exposed the right set of
intrinsics. It is my hope that we'll see patches for the common C compilers so that
they expose the x86's carry flag; inline assembler does not work well as it
effectively destroys the optimizer's ability to reason about the code.

In other words, even faster ways to implement "goto based" exceptions are known
and likely to materialize.


Produced machine code
---------------------

With ``--opt:size`` my GCC version 8.1 produces 2 instructions after
a call that can raise::

  cmp DWORD PTR [rbx], 0
  je  .L1

This is a memory fetch followed by jump. An ideal implementation would
use the carry flag and a single instruction like ``jc .L1``.


Benchmark
---------

However, to see that the current implementation is quite fast already,
let us take a look at this benchmark. This is the good old recursive fibonacci
stressing the function call overhead but I also added some string
handling so that allocation and destructors are involved producing an
implicit ``try..finally`` statement (the memory of the produced strings must be
deallocated):

.. code-block:: nim

  import strutils

  proc fib(m: string): int =
    let n = parseInt(m)
    if n < 0:
      raise newException(ValueError, "out of range")
    elif n <= 1:
      1
    else:
      fib($(n-1)) + fib($(n-2))

  import std / [times, monotimes, stats]

  when defined(cpp):
    echo "C++"
  elif compileOption("exceptions", "setjmp"):
    echo "setjmp"
  elif compileOption("exceptions", "goto"):
    echo "goto"

  var r: RunningStat
  for iterations in 1..5:
    let start = getMonoTime()

    for i in 0 ..< 1000:
      discard fib("24") # 1 1 2 3 5 8 13

    r.push float((getMonoTime() - start).inMilliseconds)

  echo r


I compiled the program in 3 variants:

1. ``nim cpp --gc:arc -d:danger fib.nim``
2. ``nim c --gc:arc --exceptions:goto -d:danger fib.nim``
3. ``nim c --gc:arc --exceptions:setjmp -d:danger fib.nim``

On my machine I got these results::

  C++
  RunningStat(
    number of probes: 5
    max: 6696.0
    min: **6416.0**
    sum: 32605.0
    mean: 6521.0
    std deviation: 102.7151400719486
  )

  goto
  RunningStat(
    number of probes: 5
    max: 6550.0
    min: **6448.0**
    sum: 32463.0
    mean: 6492.6
    std deviation: 36.34611396009203
  )

  setjmp
  RunningStat(
    number of probes: 5
    max: 8484.0
    min: **8331.0**
    sum: 41911.0
    mean: 8382.200000000001
    std deviation: 52.82575129612451
  )

Looking only at the minimum we see **6416ms for C++'s exception tables,
6448ms for the goto based exception handling and 8331ms for the old setjmp
based exception handling.**

So in other words, at least for this particular benchmark the new exception
implementation is on par with C++'s table based exception handling while offering
the already mentioned advantages.


Caveats
-------

In the "goto based exceptions" mode checked runtime errors like "Index out of bounds"
or integer overflows are not catchable and terminate the process. This is in compliance
with the Nim spec, quoting the `manual <https://nim-lang.org/docs/manual.html#definitions>`_:

  Whether a checked runtime error results in an exception or in a fatal
  error is implementation specific.


But I also consider it a strength: It means there is a cleaner separation between *bugs*
and *runtime errors* and code like ``let x = try: f() except: defaultValue`` does not
accidentally catch programming bugs anymore.


Conclusion
----------

The new implementation is efficient and portable and already the default when
compiling via ``--gc:arc``. What I like most about it is that the error
handling path is not slow either, this helps library developers: There is
no reason to split the API into ``tryParseInt`` and ``parseInt`` operations
because "exceptions should be rare events", whether they are rare or not
can depend on your input data.

