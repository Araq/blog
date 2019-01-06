==================================
       Araq's Musings
==================================


Quirky exceptions
=================

*2019-01-06*

In this blog post I explore an alternative way to implement exception/error
handling that I coined "quirky exception handling".

**Disclaimer: This is a language experiment! It is not a new Nim feature.
There is no RFC covering this material and it's not part of Nim's devel branch or
anything like that.**


Code transformations for exceptions
-----------------------------------

While reading the most recent papers about garbage collectors and language
implementations that compile to C I stumbled upon the following paper
http://www.filpizlo.com/papers/baker-ccpe09-accurate.pdf that happens to also
cover how they compile Java's exceptions to C. Interestingly they don't use C's
infamous `setjmp <https://en.cppreference.com/w/cpp/utility/program/setjmp>`_
construct (which Nim uses) but instead they inject code after
very function call that tests a threadlocal variable. ``f(...)`` is
translated to ``f(...); if (currentException != nullptr) return;``.

Code like:

.. code-block:: Java

  void f() {
    throw new Exception();
  }

  void m() {
    try {
      f();
    } catch (Exception e) {
      g();
    }
    return;
  }


Becomes:

.. code-block:: C

  void f() {
    currentException = new Exception();
    return;
  }

  void m() {
    f();
    if (unlikely(currentException != nullptr)) goto catchBlock;
    return;
    catchBlock: {
      if isSubType(currentException, Exception) {
        // we handled the exception so we need to mark it as 'consumed'
        currentException = null;
        g();
        return;
      }
    }
  }

This way of implementing exceptions is quite cheap on modern compilers and CPUs
because the injected branches are very easy to predict. Furthermore ``setjmp``
is an expensive call because it has to store a stack snapshot and this cost is
always paid, whether an exception was raised or not.

J. Baker, et al argue that in Java exceptions are raised more frequently than in
C++ code and so this approach even wins over the typical C++ exception
implementation which is based on tables and heavily optimized for
the "will not throw" case.

http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0709r1.pdf argues that
instead of threal local storage the error indicator itself can be kept in a CPU
flag speeding up these conditional branches and producing shorter machine code.
That's true but it remains unclear why an alternative exception
handling *implementation* for C++ requires to add even more *features* to
the *C++ language*... But I digress.

Already, this leads to an insightful result:

**"Exception handling cannot be used in kernel development" is a myth**.

(Though it might be true for today's C++ compilers).
All it takes is a compiler that can inject conditional branches after
function calls.**



Problems of exceptions
----------------------

Performance considerations aside, this way of implementing exceptions is quite
truthful to their semantic nature:

1. It introduces hidden global / threadlocal state. However, alternatively every
   function could return an ``Either[ResultType, Exception]`` type instead.
2. Every function call introduces hidden control flow.

The opponents of exception handling argue that point (2) leads to more unreliable
code and so it's better to not automate this step at all and deal with ``Either``
and optionals explicitly everywhere instead. This never convinced me, code runs on
physical machines where integer overflows, stack overflows and out of memory
situations are inherent. Rust for example decided to kill the
process when anything like that happens.
Option and Either types only work when the possible errors are not prevalent.

Nevertheless (2) is a real problem for resource cleanup, the automatic stack
unwinding that a raised exception causes must be interceptable so that file
handles can be ``close``'d and memory can be freed. In C++, Rust and the upcoming
Nim version this is done in a destructor. A C++ destructor
should not raise an exception as it can be called in an exception handler and
then it's not clear what to do,
see https://isocpp.org/wiki/faq/exceptions#dtors-shouldnt-throw
for more details.

Unfortunately C's ``fclose`` can fail and that is not an unusual situation:
When you ``fwrite`` to a file, it may not actually write anything, it can
stay in a buffer until a call to ``fflush`` or ``fclose`` happens which
actually writes the data to disk. That operation can fail, for example if
you just ran out of disk space.

Bad news for ``File`` objects that use destructors to call ``fclose``
automatically. This problem is not restricted to C++ either, Rust is also
affected, see https://github.com/rust-lang/rust/issues/32255. I think Rust
silently ignores the error and does not kill the process. In Rust "out of memory"
kills the process and "hard disk full" is ignored, as I said,
"exceptions produce unreliable software" is unconvincing.


Quirky exceptions
-----------------

"Quirky exceptions" attack all of these problems and are almost as convenient
to use as traditional exceptions. Like before, we map a ``throw`` operation
to setting an error indicator. And like before, we map a ``catch`` to a test
of this error indicator. Unlike before, we map a function call ``f()`` to a
a function call ``f()``. Wait, what?!

This means after an error the program *continues* like nothing happened if you
do not query the error indicator. In order to make debugging easier new
errors do not overwrite the existing error variable.

.. code-block:: C

  void f() {
    if (currentException == nullptr)
      currentException = new Exception();
    return;
  }

(Alternatively the exceptions could be stacked, for the rest of this article
it makes no difference.)

There is also an ``atexit`` handler that ensures at program shutdown the
``currentException`` variable is not set. It is still not easy to completely
ignore errors.


In the following sections I will argue why
this setup is acceptable and can sometimes be preferable over traditional exceptions.

1. The programmer remains in control over the control flow of the program (pun intended).
2. The OS protects every system call against consecutive faults. It has to because
   the OS/application boundary usually lacks an exception handling mechanism. In other words
   code like ``let f = open("file"); f.write(a); f.close(); returnOnError()``
   works very much like the more conventional
   ``let f = open("file"); returnOnError(); f.write(a); returnOnError(); f.close(); returnOnError()``,
   except that the code is not littered with error handling.
3. Destructors can "raise" exceptions naturally since it merely sets an error flag. There are no
   special rules like "must not throw in a destructor", everything composes in a nice fashion.
4. Quirky Exceptions "propagate" naturally up the call stack. ``currentException`` contains the
   error for as long as the error wasn't handled.
5. Function composition is not obfuscated with Either and Optionals.
6. Conscious tradeoffs between the application's "error polling frequency" and the produced code
   sizes are made possible. Seems quite a fit for a "systems programming language".
7. Quirky Exceptions require no complex runtime mechanisms like C++'s table based exception handling.
   You can get easy interoperability with C and thus with all the other languages that rely
   on the C ABI for interoperability.


Questions
---------

Isn't that good old ``errno`` styled error handling?
####################################################

Not quite, exceptions still can contain
niceties such as stack traces and custom data since it's based on inheritance. Also usually in
Posix a function's return value is occupied with the error indicator and then ``errno`` contains
further information. Hence you cannot compose Posix functions. Quirky Exceptions do not
have this problem.


What happens in ``a[i] = p()`` when ``p`` raises?
#################################################

``p`` sets ``currentException`` and returns a value. This value is then
assigned to ``a[i]``. Instead of a sum type like ``Either`` Quirky Exceptions
are much more like using a tuple ``(T, Error)`` return type instead. (That is
also what Go uses.)

It allows ``p`` to return a partial result of the computation even in spite
of an error. This can often be useful
and is really easy to implement. Usually it's a natural outcome of ``p``'s
implementation.

Quirky exceptions lead to a programming style where every function is *total*,
there is no disruptive control flow ("crash"), the code bubbles along.


OMG?! That is terrible!
#######################

Well judging from the limited amount of experiments that I have been able to
pursuit, this seems to be a problem that rarely comes up in practice and
here is an easy workaround:

.. code-block:: Nim
  let tmp = p()
  returnOnError()
  a[i] = tmp

Other solutions are conceivable too, including a novel static analyis that
detects a rule like
"the result of procs that can raise must not be written to a heap location".
With a cleaner heap vs stack distinction there may be new guarantees emerging
from such a system.

We are dealing with a duality here:

Traditional exception handling deals
with the question "what code must still be run when an exception bubbles up
the calling stack?". (This code needs then to be in a ``finally`` section
or in a destructor).

Quirky Exceptions deal with the question "what code
must **not** be run after an error occured?" - Calling a proc with sideEffects
is an obvious candidate. And some (but not all) writes to the heap.



Isn't this approach inherently error prone?
###########################################

Try the ``araq-quirky-exceptions`` branch of Nim, compile your code with
``--define:nimQuirky`` and try it for yourself.

From our ``async`` test cases 18% do fail (8 out of 44). The Nim compiler
itself uses exceptions too and was ported in about one hour to work with
Quirky Exceptions.

The effort in porting code amounts to finding ``raise`` statements in loops
and to convert them to a ``raise; break`` combination.

**Erroneous writes to the
heap didn't cause any problems, probably because these are not "undone" by
traditional exception handling either.**

These results are an indication that the approach has merit,
especially when interoperability with C or webassembly is most important
and the code is written with Quirky Exceptions in mind from the beginning.
Large parts of the standard library can be used and we could test it regularly
in this mode if there is enough interest.

It also means that mapping ``raise`` to a ``setError`` call in a destructor
seems to be an easy, viable solution that should be preferred over ignoring
errors in destructors.
