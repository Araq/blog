================================================
          Pointer free programming
================================================

What do ParaSail, "modern" C++ and Rust have in common? They focus
on "pointer free programming" (ok, maybe Rust doesn't, but it uses
similar mechanisms).
In this blog post I am exploring how we can move Nim into this
direction. My goals are:

- Memory safety without GC.
- Make passing data between threads more efficient.
- Make it more natural to write code with excellent performance.
- A simpler programming model: Pointers introduce aliasing, this means
  programs are hard to reason about, this affects optimizers as well as
  programmers.

The title gave it away: We are going to get into this state
of programming Valhalla by eliminating pointers. Of course for low
level programming Nim's ``ptr`` type is here to stay but I hope to
avoid ``ref`` as far as reasonable in the standard library. (``ref``
might become an atomic RC'ed pointer.)
As a nice side-effect, ``nil`` ceases to be a problem too. Instead
of ``ref object`` we will use ``object`` more, this implies the
``var`` vs "no var" distinction will be used more often, another
benefit in my opinion.


What's wrong with Nim's GC?
===========================

Not much per se (hey, it's likely faster than the alternatives that I'm
exploring here) but it makes interoperability with most of what's outside
of Nim's ecosystem harder:

- Python has its own GC and while building a Nim DLL that Python can load
  works, it would be even easier if the DLL wouldn't need special code that
  ensures the GC's conservative stack scanning works.
- C++ game engines are based on RAII and wrapping a C++ object in a
  Nim ``ref object`` that calls a C++ destructor in a GC finalizer adds
  overhead. This applies to almost every big C or C++ project.
- The conservative stack scanning can fail for more unusual targets like
  Emscripten. (Workarounds exist though.)
- I have spent far more time now in fixing GC related bugs or optimizing
  the GC than I ever spent in hunting down memory leaks or corruptions.
  Memory safety is not negotiable but we should attempt to get it without
  a runtime that grows ever more complex.


Containers
==========

Nim's containers should be value types. Explicit move semantics as well as
a special optimizer will eliminate most copies.

Almost all containers keep the number of elements they hold and so instead
of ``nil`` we get a much nicer state ``len == 0`` that is not as prone
to crashes as ``nil``. When a container is moved, its length becomes 0.


Slicing
=======

Strings and seqs will support O(1) slicing, other containers might
also produce a "view" into their interiors. Slices break up the
clear ownership semantics that we're after and so will probably
be restricted to parameters much like ``openArray``.


Opt
=====

Trees do not require pointers to be constructed, a ``seq`` can
do the same:

.. code-block:: Nim

  type
    Node = object  ## note the absence of ``ref`` here
      children: seq[Node]
      payload: string

However often only 1 or 0 entries are possible and so a ``seq`` would be
overkill. ``opt`` is a container that can be full or empty, just like
the well known Option type from other languages.

.. code-block:: Nim

  type
    Node = object  ## note the absence of ``ref`` here
      left, right: opt[Node]
      payload: string

Under the hood ``opt[Note]`` uses a pointer, it has to, otherwise a construct
like the above would take up an infinite amount of memory ("a node contains
nodes which contain nodes which ..."). But since this pointer is not exposed,
it doesn't destroy the value semantics. It can be argued that ``opt[T]`` is
very much a unique pointer that adheres to the copy vs move distinction.


Destructors, assignment and moves
=================================

The existing Nim supports moving via ``shallowCopy``, this is a bit ugly so
from now on a move shall be written as ``<-``. Note that ``<-`` is not a
real new operator here, I used it only to emphasize in the examples where
a move occurs.

Value semantics make it easy to determine the lifetime of an object, when it
goes out of scope, its attached resources can be freed, that means its
destructor is called. If it was moved (if it *escapes*) instead,
some internal state in the object or container reflects this and the destruction
can be prevented. An optimization pass is allowed to remove destructor calls,
likewise a copy propagation pass is allowed to remove assignments.

There are in fact two places where destruction can occur: At scope exit and
at assignment, ``x = y`` means "destroy x; copy y into x". This is often
inefficient:

.. code-block:: Nim

  proc put(t: var Table; key, val: string) =
    # outline of a hash table implementation:
    let h = hash(key)
    # these are destructive assignments:
    t.a[h].key = key
    t.a[h].val = val

  proc main =
    let key <- stdin.readLine()
    let val <- stdin.readLine()
    var t = createTable()
    t.put key, val

This constructs 2 strings via the ``readLine`` calls that are then
copied into the table ``t``. At the scope exit of ``main`` the
original strings ``key`` and ``val`` are freed.

This naive code does 2 copies and 4 destructions. We can do much better
with ``swap``:

.. code-block:: Nim

  proc put(t: var Table; key, val: var string) =
    # outline of a hash table implementation:
    let h = hash(key)
    swap t.a[h].key, key
    swap t.a[h].val, val

  proc main =
    var key <- stdin.readLine()
    var val <- stdin.readLine()
    var t = createTable()
    t.put key, val

This code now only does the required minimum of 2 destructions.
It also quite ugly, ``key`` and ``val`` are forced to be ``var``'s
and after the move into the table ``t`` they can be accessed and
contain the old table entries. This can occasionally be useful but
more often we would like to keep the ``let`` and instead accessing
the value after it was moved should produce a compile-time error.

This is made possible by ``sink`` parameters. A ``sink`` parameter
is like a ``var`` parameter but ``let`` variables can be passed to
it and afterwards a simple control flow analysis prohibits accesses
to the location. With ``sink`` the example looks as follows:

.. code-block:: Nim

  proc put(t: var Table; key, val: sink string) =
    # outline of a hash table implementation:
    let h = hash(key)
    swap t.a[h].key, key
    swap t.a[h].val, val

  proc main =
    let key <- stdin.readLine()
    let val <- stdin.readLine()
    var t = createTable()
    t.put key, val

Alternatively we can simply allow to pass a ``let`` to a ``var``
parameter and then it means it's moved.

Btw ``let key = stdin.readLine()`` will always be transformed into
``let key <- stdin.readLine()``.


Optimizing copies into moves
============================

Consider this example:

.. code-block:: Nim

  let key = stdin.readLine()
  var a: array[10, string]
  a[0] = key
  echo key

Since ``key`` is accessed after the assignment ``a[0] = key`` it has to
be copied into the array slot. But without the ``echo key`` statement the
value can be moved. And so that's what the compiler does for us. Blurring
the distinction between moves and copies means that code can evolve without
"friction".



Destructors
===========

Every construction needs to be paired with a destruction in order to prevent
memory leaks. It also must be destroyed exactly once in order to prevent
corruptions. The secret to get memory safety from this model lies in the
fact that calls to destructors are always inserted by the compiler.

But what is a construction? Nim has no traditional constructors. The answer
is that the ``result`` of every proc counts as construction. This is no big
loss as return values tend to be bad for high performance code. More on this
later.



Code generation for destructors
===============================

Naive destructors for trees are recursive. This means they can lead to stack
overflows and can lead to missed deadlines in a realtime setting. The default
code generation for them thus uses an explicit stack that interacts with the
memory allocator to implement lazy freeing. Or maybe we can introduce
a ``lazyDestroy`` proc that should be used in strategic places. The
implementation could look like this:

.. code-block:: Nim

  type Destructor = proc (data: pointer) {.nimcall.}

  var toDestroy {.threadvar.}: seq[(Destructor, pointer)]

  proc lazyDestroy(arg: pointer; destructor: Destructor) =
    if toDestroy.len >= 100:
      # too many pending destructor calls, run immediately:
      destructor(arg)
    else:
      toDestroy.add((destructor, arg))

  proc `=destroy`(x: var T) =
    lazyDestroy cast[pointer](x), proc (p: pointer) =
      let x = cast[var T](p)
      `=destroy`(x.le)
      `=destroy`(x.ri)
      dealloc(p)

  proc constructT(): T =
    if toDestroy.len > 0:
      let (d, p) = toDestroy.pop()
      d(p)


This is really just a variant of "object pooling".


Move rules
==========

Now that we have gained these insights, we can finally write down the
precise rules when copies, moves and destroys happen:


====    ================================         ===========================================
Rule    Pattern                                  Meaning
====    ================================         ===========================================
1       ``var x; stmts``                         ``var x; try stmts finally: destroy(x)``
2       ``x = f()``                              ``move(x, f())``
3       ``x = lastReadOf z``                     ``move(x, z)``
4       ``x = y``                                ``copy(x, y)``
5       ``f(g())``                               ``f((move(tmp, g()); tmp)); destroy(tmp)``
====    ================================         ===========================================


``var x = y`` is handled as ``var x; x = y``. ``x``, ``y`` here are arbitrary locations,
``f`` and ``g`` are routines that take an arbitrary number of arguments, ``z`` a
local variable.

In the current implementation ``lastReadOf z`` is approximated by "z is read
and written only once and that is done in the same basic block".
Later versions of the Nim compiler will detect this case more precisely.

The key insight here is that assignments are resolved into
several distinct semantics that do "the right thing". Containers should thus
be written to leverage the builtin assignment!

To see what this means, let's look at C++: In C++ there is a distinction between
moves and copies and this distinction bubbles up in the APIs, for
example ``std::vector`` has

::

    void push_back(const value_type& x); // copies the element
    void push_back(value_type&& x); // moves the element


In Nim we can do better thanks to its ``template`` feature (which has nothing
to do with C++'s templates):

.. code-block:: Nim

  proc reserveSlot(x: var seq[T]): ptr T =
    if x.len >= x.cap: resize(x)
    result = addr(x.data[x.len])
    inc x.len

  template add*[T](x: var seq[T]; y: T) =
    reserveSlot(x)[] = y


Thanks to ``add`` being a template the final assignment is not hidden from
the compiler and so it is allowed to use the most effective form. The
implementation uses the unsafe ``ptr`` and ``addr`` constructs, but it is
generally accepted now that a language's core containers are allowed to
do that.

This way of writing containers works for more complex cases too:

.. code-block:: Nim

  template put(t: var Table; key, val: string) =
    # ensure 'key' is evaluated only once:
    let k = key

    let h = hash(k)
    t.a[h].key = k    # move (rule 3)
    t.a[h].val = val  # move (rule 3)

  proc main =
    var key = stdin.readLine() # move (rule 2)
    var val = stdin.readLine() # move (rule 2)
    var t = createTable()
    t.put key, val


Note how rule 3 ensures that ``t.a[h].key = k`` is transformed into a move
since ``k`` is never used again afterwards. (Optimizing away the
temporary ``k`` completely is a story for another time.)

Given these new insights, I assume that ``sink`` parameters are not required
at all. Keeps the language simpler.



Getters
=======

Templates also help in avoiding copies introduced by getters:

.. code-block:: Nim

  template get(x: Container): T = x.field

  echo get() # no copy, no move

If we replace ``template get`` with ``proc get`` here rule 5 would
apply and produce:

.. code-block:: Nim

  proc get(x: Container): T =
    copy result, x.field

  echo((var tmp; move(tmp, get()); tmp))
  destroy(tmp)


Strings
=======

Here is an outline of how Nim's standard strings can be implemented with this
new scheme. The code is reasonable straight-forward, but you always need to keep
two things in mind:

- Assignments and copies need to destroy the old destination.
- Self assignments need to work.

.. code-block:: Nim

  type
    string = object
      len, cap: int
      data: ptr UncheckedArray[char]

  proc add*(s: var string; c: char) =
    if s.len >= s.cap: resize(s)
    s.data[s.len] = c

  proc `=destroy`*(s: var string) =
    if s.data != nil:
      dealloc(s.data)
      s.data = nil
      s.len = 0
      s.cap = 0

  proc `=move`*(a, b: var string) =
    # we hope this is optimized away for not yet alive objects:
    if a.data != nil and a.data != b.data: dealloc(a.data)
    a.len = b.len
    a.cap = b.cap
    a.data = b.data
    # we hope these are optimized away for dead objects:
    b.len = 0
    b.cap = 0
    b.data = nil

  proc `=`*(a: var string; b: string) =
    if a.data != nil and a.data != b.data:
      dealloc(a.data)
      a.data = nil
    a.len = b.len
    a.cap = b.cap
    if b.data != nil:
      a.data = alloc(a.cap)
      copyMem(a.data, b.data, a.cap)


Unfortunately the signatures do not match, ``=move`` takes 2 ``var`` parameters
but according to the transformation rules ``move(a, f())`` or
``move(a, lastRead b)`` are produced and these are not addressable
locations! So we need different type-bound operator called ``=sink`` that is
used instead.

.. code-block:: Nim

  proc `=sink`*(a: var string, b: string) =
    if a.data != nil and a.data != b.data: dealloc(a.data)
    a.len = b.len
    a.cap = b.cap
    a.data = b.data

The compiler only invokes ``sink``. ``move`` is an explicit programmer
optimization. Which can usually also be written as ``swap`` operation.


Return values are harmful
=========================

Nim's stdlib contains the following coding pattern for the ``toString``
``$`` operator:

.. code-block:: Nim

  proc helper(x: Node; result: var string) =
    case x.kind
    of strLit: result.add x.strVal
    of intLit: result.add $x.intVal
    of arrayLit:
      result.add "["
      for i in 0 ..< x.len:
        if i > 0: result.add ", "
        helper(x[i], result)
      result.add "]"

  proc `$`(x: Node): string =
    result = ""
    helper(x, result)


(The declaration of the ``Node`` type is left as an excercise for the reader.)
The reason for this workaround with the ``helper`` proc is that it lets us
use ``result: var string``, a single string buffer we keep appending to. The
naive implementation would instead produce much more allocations and
concatenations. We gain a lot by constructing (or in this case: appending)
the result directly where it will end up.

Now imagine we want to embed this string in a larger context like an HTML page,
``helper`` is actually the much more useful interface for speed. This answers
the old question "should procs operate inplace or return a new value?".

Excessive inplace operations do lead to a code style that is completely
statement-based, the dataflow is much harder to see than in the more FP'ish
expression-based style. What Nim needs is a transformation from expression
based style to statement style. This transformation is really simple, given
a proc like:

.. code-block:: Nim

  proc p(args; result: var T): void

A call to it missing the final parameter ``p(args)`` is rewritten to
``(var tmp: T; p(args, tmp); tmp)``. Ideally the compiler would introduce
the minimum of required temporaries in nested calls but such an optimization
is far away and one can always choose to write the more efficient version
directly.


Reification
===========

Second class types or parameter passing modes like ``var`` or the
imagined ``sink`` have the problem that they cannot be put into an object.
This is more severe than it first seems as any kind of threading or tasking
system requires a "reification" of the argument list into a task *object*
that is then sent to a queue or thread. In fact in the current Nim neither
``await`` nor ``spawn`` supports invoking a proc with ``var`` parameters
and even capturing such a parameter in a closure does not work! The current
workaround is to use ``ptr`` for these. Maybe somebody will come up with
a better solution.

