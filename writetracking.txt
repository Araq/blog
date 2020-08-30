==================================
  Write tracking for Nim
==================================


Write tracking for Nim
======================

*2013-08-25*

While the exact details of Nim's new improved concurrency model are still
somewhat unclear, the next steps are perfectly clear at least.
Nim will get *write tracking* as part of Nim's general effect system.

Write tracking is an alternative to adding "immutable" or "const" to the type
system. I don't like to add "const" to Nim's type system as that complicates
the language tremendously and both C++'s and D's approaches to "const" leave
a lot to be desired: For instance in C++ you cannot pass a ``vector<string>``
to a ``vector<const string>``. In my opinion this is a major wart in the
type system and I'd rather not have "const" then at all. Fortunately there
is a more expressive and flexible alternative: Use the effect system instead
of the type system:

.. code-block:: nim
  type
    PNode = ref object
      next: PNode
      data: string

  proc len(n: PNode): natural {.writes: [].} =
    var it = n
    while it != nil:
      inc result
      it = it.next

The compiler can infer that ``len`` does not modify any memory (the modifications
to the local ``it`` do not count); there is no need to clutter up the type
system with a notion of immutability. As usual for Nim's effect system, you
can also annotate the write effects yourself and then the compiler checks
that you didn't screw up.

Lets look at one more example to see the beauty of an effects system. Here is
some code written in a hypothetical version of Nim that added
an ``immutable`` mode to its type system:

.. code-block:: nim
  proc identity[M: immutable|mutable](x: M PNode): M PNode = x

As ``identity`` simply returns its passed argument, it should return the value
in the same *mode* as ``x``. This requires ``identity`` to become a generic
even though exactly same code for immutable PNode and mutable PNode will be
produced when instantiating ``identity``. This means immutability leads to
more generic functions and thus instantiations and the linker needs to merge
all these definitions later. This is unfortunate. Furthermore for a systems
programming language generics that do not expand to different machine code but
only exist to make the type system happy are even more unfortunate.

Here is the trivial version with write tracking:

.. code-block:: nim
  proc identity(x: PNode): PNode {.writes: [].} = x

Since we don't introduce (im)mutability modes there is no need for generics for
this piece of code. Instead the fact that ``identity`` is harmless is encoded
in the ``writes: []`` effect.


Paths
=====

The ``writes`` pragma takes a list of *paths*. A path is an lvalue expression
like ``obj.x[i].y``. The *root* of a path is the symbol that can be determined
as the owner; ``obj`` in the example. The list of paths is also
called the *write set*.

The paths that are interesting for the ``writes`` effect are these paths where
the owner is either a parameter, a global variable or a thread local variable:

.. code-block:: nim
  var gId = 0

  proc genId(): natural {.writes: [gId].} =
    gId += 1
    return gId

Here the effect systems shows its strength: Imagine there was a ``genId2`` that
writes to some other global variable; then ``genId`` and ``genId2`` can be
executed in parallel even though they are not free of side effects!




Adding
immutability to the type system looks more and more inferior.


Write set analysis
==================

For the analysis to work we need to consider every path, including paths whose
root is a local variable:

.. code-block:: nim
  proc select(cond: bool, a, b: PNode): PNode {.writes: [].} =
    if cond: a else: b

  proc p(a, b: PNode) =
    var x = select(randomNumber==0, a, b)
    x.data = "abc"

The write set of ``p`` is ``[a.data, b.data]`` as it cannot be known which
node ``select`` returns. Note that ``select`` itself doesn't modify anything
and that the modifications ``p`` performs happen through the local
variable ``x`` which aliases either the parameter ``a`` or ``b``.

Another thing to consider is that the write set can be infinite:

.. code-block:: nim
  proc p(list: PNode) =
    var it = list
    while it != nil:
      it.data = "abc"
      it = it.next

Here ``p``'s write set is ``[list.data, list.next.data, list.next.next.data, ...]``,
in other words the whole list (of unknown length) is modified. We can introduce
a new operator ``@`` to deal with this problem: ``list@data`` then means "some
or every 'data' field reachable from 'list' is modified". However a simpler
solution is to just approximate the write set with ``[list[]]`` which means
"anything reachable from 'list' may be modified" (``x[]`` means pointer
dereference in Nim). The first version of the write tracking implementation
will do just that.


Tracking algorithm
==================

The algorithm to determine write sets works in two passes over the AST. No
fix point iterations are necessary. The complexity is O(n) where ``n`` is the
size of the AST.


Pass 1: write set computation for locals
----------------------------------------

The first pass computes the set of possible roots for every local
variable ``v``. ``v`` is either used in an assignment or passed to a function.
The following rules are used to determine ``writeset(v)``:

.. code-block:: nim
  v = w # where 'w' is another local variable
  -->
  writeset(v).incl(w)


It's important to model the dependency of ``v`` from ``w`` explicitly. Note
that we cannot simply merge ``w``'s write set with ``v``'s as ``w``'s write set
has not yet been computed completely.
This means that we later need to *expand* the write sets and ensure that cycles
are handled properly; for instance ``writeset(v) == {w} and writeset(w) == {v, g}``
implies ``writeset(v) == writeset(w) == {g}`` (where ``v``, ``w`` are locals
and ``g`` is a global).

A cycle in the write set dependencies can also imply an infinite write set:

.. code-block:: nim
  proc p(list: PNode) =
    var it = list
    while it != nil:
      let next = it.next
      it.data = "abc"
      it = next

  -->
  writeset(it) = {list, next}
  writeset(next) = {it}

(A self cycle suffices for that.)

In general an infinite write set can only be produced by cycles or by
recursion:

.. code-block:: nim
  proc r(list: PNode) =
    if list == nil: return
    r(list.next)
    list.data = "abc"

We detect this case by treating parameters like local variables in the proc
body and pretend the assignment ``list = list.next`` occurs in the body, this
leads to ``writeset(list) = {list}``. An alternative is to weaken the meaning
of ``writes: [list.data]`` so that it means "any 'data' field reachable
from 'list' might be modified".

The following rule deals with the fact that aliasing can be introduced via
function application:

.. code-block:: nim
  v = f(path(a), ..., path(b), ...)  # unless 'f' is 'new' (see below)
  -->
  writeset(v).incl(a) iff 'v' may alias 'path(a)'
  writeset(v).incl(b) iff 'v' may alias 'path(b)'

Here ``path(x)`` denotes a path expression whose root is ``x``. The rule really
needs to deal with arbitrary nesting (including no function application at all):

.. code-block:: nim
  v = f(...g(path(a)), ...)
  -->
  writeset(v).incl(a) iff 'v' may alias 'path(a)'

Interestingly ``addr`` is not special at all and might even be considered part
of a path:

.. code-block:: nim
  v = addr(path(x))
  -->
  writeset(v).incl(x)




Pass 2: write set computation for the routine
---------------------------------------------

In the following a *relevant symbol* is either a global variable, a parameter
or a thread local variable.

The AST is searched for assignments of the form ``path(x) = ...``.
Every ``path`` that affects a relevant symbol is added to the write set.
This ``add`` operation needs to take a subsumption relation into
account: ``[x[], x.abc]`` is the same as ``[x[]]`` (anything reachable
from ``x`` may be modified; this already includes ``x.abc``).

If ``x`` is a local, look up its write set ``w`` and do for every
relevant symbol ``s`` in ``w``: writesEffect.add(path(s)).
If ``x`` is a relevant symbol, do: writesEffect.add(path(x)).


Optimization: new pragma
========================

The algorithm as described above has a major weakness as the following example
highlights:

.. code-block:: nim
  proc newNode(next: PNode): PNode {.writes: [].} =
    return PNode(next: next, data: "")

  proc p(a: PNode) =
    var x = newNode(a)
    x.data = "abc"

``p``'s write set would be computed to be ``[a.data]``. Strictly
speaking this is not *wrong* as the write set is a static approximation of
what might be modified. However, it is unsatisfying. ``newNode`` always returns
a *new* node, there is no way ``p`` can modify ``a.data``!

The solution is to infer that ``newNode`` always allocates a new node:

.. code-block:: nim
  proc newNode(next: PNode): PNode {.writes: [], new.} =
    return PNode(next: next, data: "")

  proc p(a: PNode) {.writes: [].} =
    # since 'newNode' returns a fresh object, we know 'x' doesn't alias 'a'
    # here:
    var x = newNode(a)
    x.data = "abc"

As usual, the annotation ``new`` can be explicitly added for the cases where
it cannot be inferred (when the proc's body is not avaliable).

Since it is now obvious ``p`` has no side effects and doesn't modify the object
pointed to by ``a`` the compiler could emit a warning or even an error;
``p`` only consists of dead code.
