==================================
  Araq's Musings
==================================


A new runtime for Nim
=====================

*2019-03-26*

In this blog post I explore how the *full* Nim language can be used without
a tracing garbage collector. Since strings and sequences in Nim can also
be implemented with destructors the puzzle to solve is what to do with Nim's
``ref`` pointers and ``new`` keyword.

So let's talk about Pascal from the '70s. Back then some Pascal implementations
lacked its ``dispose`` statement, Pascal's name for what C calls ``free`` and
C++ calls ``delete``. It is not clear to me whether this lack of ``dispose``
was an oversight or a deliberate design decision.

However, in Ada ``new`` is a language
keyword and a safe operation, whereas a ``dispose`` operation needs to be
instantiated explicitly via ``Ada.Unchecked_Deallocation``. Allocation
is safe, deallocation is unsafe.

Obviously these languages longed for a garbage collector to bring them the
complete memory safety they were after. 50 years later and not only do
commonly used implementations of Ada and Pascal **still** lack a garbage
collector, there are new languages like Rust and Swift which have some
semi automatic memory management but lack any *tracing* GC technology. What
happened? Hardware advanced to a point where memory management and data type
layouts are very important for performance, memory access became much slower
compared to the CPU, and heap sizes are now measured in Giga- and Terabytes.

Another problem is that tracing GC algorithms are
selfish; they only work well when a lot of information about the potential
"root set" is available, this makes interoperability between different
garbage collectors (and thus between different programming language
implementations) quite challenging.


Reference counting
------------------

So tracing is "out", let's have a look at reference counting (RC). RC
is incomplete, it cannot deal with cyclic data structures. Every known
solution to the dynamic cycle detection/reclamation strategy is some form of
tracing:

1. "Trial deletion" is a trace of a local subgraph. Unfortunately the subgraph
   can be as large as the set of live objects.
2. A "backup" mark and sweep GC is a global tracing algorithm.

One way of looking at this problem
is that RC cannot deal with cycles because it too *eager*, it increments
the counters even for back references or any other reference that produces
a cycle. And after we break up the cycles manually with ``weak`` pointer
annotations or similar, we're still left with RC's inherent runtime costs
which are very hard to optimize away completely.

Nim's default GC is a deferred reference counting GC. That means that stack
slot updates do not cause RC operations. Only pointers on the heap are
counted. Since Nim uses thread local heaps the increments and decrements
are not atomic. As an experiment I replaced them with atomic operations. The goal
was to estimate the costs of atomic reference counting. The result was that
on my Haswell CPU bootstrapping time for the Nim compiler itself increased
from 4.2s to 4.4s, a slowdown of 5%. And there is no contention on these
operations as everything is still single threaded. This suggests to me that
reference counting should not be the default implementation strategy for
Nim's ``ref`` and we need to look at other solutions.


Manual dispose
--------------

A GC was added to Nim because back then this seemed like the best solution to ensure
memory safety. In the meantime programming language research advanced and
there are solutions that can give us memory safety without a GC.

Rust-like borrowing extensions are not the only mechanism to
accomplish this, there are many different solutions to explore.

So let's consider manual ``dispose`` calls.
Can we have them and memory safety at the same time? Yes! And a couple of
experimental programming languages
(`Cockoo <http://www.cs.bu.edu/techreports/pdf/2005-006-cuckoo.pdf>`_ and
some `dialect of C# <https://www.microsoft.com/en-us/research/wp-content/uploads/2017/03/kedia2017mem.pdf>`_)
implemented this solution. One key insight is that ``new``/``dispose`` need to
provide a type-safe interface, the memory is served by type-specific memory
allocators. That means that the memory used up for type ``T`` will only be
reused for other instances of type ``T``.

Here is an example that shows what this means in practice:

.. code-block:: nim

  type
    Node = ref object
      data: int

  var x = Node(data: 3)
  let dangling = x
  assert dangling.data == 3
  dispose(x)
  x = Node(data: 4)
  assert dangling.data in {3, 4}

Usually accessing ``dangling.data`` would be a "use after free" bug but
since ``dispose`` returns the memory to a type-safe memory pool we know
that ``x = Node(data: 4)`` will allocate memory from the same pool; either
by re-using the object that previously had the value 3 (then we know
that ``dangling.data == 4``) or by creating a fresh object (then
we know ``dangling.data == 3``).

Type-specific allocation turns every "use after free" bug into a logical
bug but no memory corruption can happen. So ... we have already
accomplished "memory safety without a GC". It didn't require a borrow
checker nor an advanced type system. It is interesting to compare this
to an example that uses array indexing instead of pointers:

.. code-block:: nim

  type
    Node = object
      data: int

  var nodes: array[4, Node]

  var x = 1
  nodes[x] = Node(data: 3)
  let dangling = x
  assert nodes[dangling].data == 3
  nodes[x] = Node(data: 4)
  assert nodes[dangling].data == 4

So if the allocator re-uses dispose'd memory as quickly as possible we
can reproduce the same results as the array version. However, this mechanism
produces different results than the GC version:


.. code-block:: nim

  type
    Node = ref object
      data: int

  var x = Node(data: 3)
  let dangling = x
  assert dangling.data == 3
  x = Node(data: 4)
  # note: the 'dangling' pointer keeps the object alive
  # and so the value is still 3:
  assert dangling.data == 3

The GC transforms the use-after-free bug into hopefully correct
behaviour -- or into logical memory leaks as *liveness* is
approximated by *reachability*. Programmers are encouraged to not
think about memory and resource management, but in my experience
thinking a *little* about these is required for writing robust software.

Philosophy aside, porting code that uses garbage collection over to
code that has to use manual ``dispose`` calls everywhere which can then
produce subtle changes in behaviour is not a good solution. However,
we will keep in mind that type-safe memory reuse is all that it takes for
memory safety.

This is not "cheating" either, for example
https://www.usenix.org/legacy/event/sec10/tech/full_papers/Akritidis.pdf
also tries to mitigate memory handling bugs with this idea.


Owned ref
---------

The pointer has been called the "goto of data structures" and much like
"goto" got replaced by "structured control flow" like ``if`` and ``while``
statements, maybe ``ref`` also needs to be split into different types?
The "Ownership You Can Count On"
`paper <https://researcher.watson.ibm.com/researcher/files/us-bacon/Dingle07Ownership.pdf>`_
proposes such a split.

We distinguish between ``ref`` and ``owned ref`` pointers. Owned pointers
cannot be duplicated, they can only be moved so they are very much like C++'s
``unique_ptr``. When an owned pointer disappears, the memory it refers to is
deallocated. Unowned refs are reference counted. When the owned ref disappears
it is checked that no dangling ``ref`` exists; the reference count must be zero.
The reference counting only has to be done for debug builds in order to detect
dangling pointers easily and in a deterministic way. In a release build the RC
operations can be left out and with a type based allocator we still have
memory safety!

Nim's ``new`` returns an owned ref, you can pass an owned ref to either an owned
ref or to an unowned ref. ``owned ref`` helps the compiler in figuring out a
graph traversal that is free of cycles. The creation of cycles is prevented at
compile-time.

Let's look at some examples:


.. code-block:: nim

  type
    Node = ref object
      data: int

  var x = Node(data: 3) # inferred to be an ``owned ref``
  let dangling: Node = x # unowned ref
  assert dangling.data == 3
  x = Node(data: 4) # destroys x! But x has dangling refs --> abort.


We need to fix this by setting ``dangling`` to ``nil``:

.. code-block:: nim

  type
    Node = ref object
      data: int

  var x = Node(data: 3) # inferred to be an ``owned ref``
  let dangling: Node = x # unowned ref
  assert dangling.data == 3
  dangling = nil
  # reassignment causes the memory of what ``x`` points to to be freed:
  x = Node(data: 4)
  # accessing 'dangling' here is invalid as it is nil.
  # at scope exit the memory of what ``x`` points to is freed

While at first sight it looks bad that this is only detected at runtime,
I consider this mostly an implementation detail -- static analysis with
abstract interpretation will catch on and find most of these problems at
compile time. The programmer needs to prove that no dangling
refs exist -- justifying the required and explicit assignment of
``dangling = nil``.


This is how a doubly linked list looks like under this new model:

.. code-block:: nim

  type
    Node*[T] = ref object
      prev*: Node[T]
      next*: owned Node[T]
      value*: T

    List*[T] = object
      tail*: Node[T]
      head*: owned Node[T]

  proc append[T](list: var List[T]; elem: owned Node[T]) =
    elem.next = nil
    elem.prev = list.tail
    if list.tail != nil:
      assert(list.tail.next == nil)
      list.tail.next = elem
    list.tail = elem
    if list.head == nil: list.head = elem

  proc delete[T](list: var List[T]; elem: Node[T]) =
    if elem == list.tail: list.tail = elem.prev
    if elem == list.head: list.head = elem.next
    if elem.next != nil: elem.next.prev = elem.prev
    if elem.prev != nil: elem.prev.next = elem.next


Nim has closures which are basically ``(functionPointer, environmentRef)``
pairs. So ``owned`` also applies for closure. This is how callbacks are done:

.. code-block:: nim

  type
    Label* = ref object of Widget
    Button* = ref object of Widget
      onclick*: seq[owned proc()] # when the button is deleted so are
                                  # its onclick handlers.

  proc clicked*(b: Button) =
    for x in b.onclick: x()

  proc onclick*(b: Button; handler: owned proc()) =
    onclick.add handler

  proc main =
    var label = newLabel() # inferred to be 'owned'
    var b = newButton() # inferred to be 'owned'
    var weakLabel: Label = label # we need to access it in the closure as unowned.

    b.onclick proc() =
      # error: cannot capture an owned 'label' as it is consumed in 'createUI'
      label.text = "button was clicked!"
      # this needs to be written as:
      weakLabel.text = "button was clicked!"

    createUI(label, b)


This is slightly messier than in today's Nim but we can add some syntactic
sugar later like ``unowned(label).text = "..."`` or add a language rule like
"owned refs accessed in a closure are not owned". Notice how the type system
prevents us from creating Swift's "retain cycles" at compile-time.


Pros and Cons
-------------

This model has significant advantages:

- We can effectively use a shared memory heap, safely. Multi threading your
  code is much easier.
- Deallocation is deterministic and works with custom destructors.
- We can reason about aliasing, two owned refs cannot point to the same
  location and that's enforced at compile-time. We can even map ``owned ref``
  to C's ``restrict``'ed pointers.
- The runtime costs are much lower than C++'s ``shared_ptr`` or Swift's
  reference counting.
- The required runtime mechanisms easily map to weird, limited targets like
  webassembly or GPUs.
- Porting Nim code to take advantage of this alternative runtime amounts to
  adding the ``owned`` keyword to strategic places. The compiler's error
  messages will guide you.
- Since it doesn't use tracing the runtime is independent of the involved
  heap sizes. Heaps of terabytes or kilobytes in size make no difference.
- Doubly linked lists, trees and most other graph structures are easily
  modeled and don't need a borrow checker or other parametrized
  type system extensions.

And of course, disadvantages:

- Dangling unowned refs cause a program abort and are not detected
  statically. However, in the longer run I expect static analysis to catch
  up and find most problems statically, much like array indexing
  can be proved correct these days for the important cases.
- You need to port your code and add ``owned`` annotations.
- ``nil`` as a possible value for ``ref`` stays with us as it is required
  to unarm dangling pointers.


Immutability
------------

With ownership becoming part of the type system we can easily envision a rule
like "only the owner should be allowed to mutate the object". Note that this
rule cannot be universal, for example
in ``proc delete[T](list: var List[T]; elem: Node[T])``
we need to be able to mutate ``elem``'s fields and yet we don't own ``elem``,
the list does.

So here is an idea: An ``immutable`` pragma that can be attached to
the ``object`` type ``T`` and then assigments like ``r.field = value`` are
forbidden for every ``r`` of type ``ref T``, but they are allowed for ``r``
of type ``owned ref T``:

.. code-block:: nim

  type
    Node {.immutable.} = ref object
      le, ri: Node
      data: string

  proc select(a, b: Node): Node =
    result = if oracle(): a else: b

  proc construct(a, b: Node): owned Node =
    result = Node(data: "new", le: a, ri: b)

  proc harmless(a, b: Node) =
    var x = construct(a, b)
    # valid: x is an owned ref:
    x.data = "mutated"

  proc harmful(a, b: Node) =
    var x = select(a, b)
    # invalid: x is not an owned ref:
    x.data = "mutated"


However, since this pragma will not break any code, it can be added later,
after we have added the notion of owned pointers to Nim.
