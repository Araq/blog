==================================
  A new concurrency system for Nim
==================================


A new concurrency system for Nim
===================================

**Warning: The information presented here is severely outdated.**
Nim's concurrency is now based on different mechanisms
(scope based memory management and destructors).


Part 2
------

*2013-06*


Part 1 introduced the basic ideas behind Nim's concurrency model.
Here in part 2 things get more formal. However you will be rewarded by
a nice real world example.


About shared
============

"Shared" really means two different but related things:

1. The memory is allocated on the shared memory heap and as such can live longer
   than the thread that allocated it. If it's GC'ed memory the GC must be able
   to deal with the situation that any thread could keep it alive. This is very
   hard to implement efficiently and is unlikely to be supported soon. The
   examples we have seen all used ``ptr`` and not ``ref`` for this reason.
2. The memory is protected/guarded by some lock and this lock needs to be
   acquired for safe access.


It is essential to clearly differentiate between (1) and (2) in the
terminology: "shared" then means "allocated on a shared heap"
and "guarded" means "cannot be dereferenced without holding a lock".

In contrast to D and Rust, Nim doesn't try to ban global variables as these
have one inherent property that is essential for automatic verification of
embedded systems:

**There is a one to one correspondence between names and storage locations.**

For this reason globals are an essential ingredient whenever you have to
guarantee/prove bounded memory usage. Furthermore aliasing is rather easy to
deal with: Two globals A and B simply cannot overlap. (If the language allows
taking the address of a global the required analyses become harder but are
still tractable especially if you can use whole program compilation.)

For Nim globals have additional advantages:

1. The ownership of global variables can be bound to the main thread. This way
   no explicit ownership annotations are required.
2. Tracking the accesses of global variables will be part of Nim's effect
   system.
2. Globals don't have to be allocated nor freed. Thus "use after free" bugs
   are impossible and yet globals do not require any GC mechanism.
3. Due to the thread local heaps channels are naturally global variables
   in Nim.

Since all globals are shared implicitly it makes even more sense to name the
"safe locking feature" "guarded" instead of "shared". So every global variable
that a thread accesses needs to be marked as "guarded" or have a "guard".


New type constructors
=====================

As usual macros do not help to prevent language growth and we need to add
quite some things to Nim's type system and new builtins.

shared
------

``shared`` is a type qualifier that is used to annotate pointers pointing
to shared memory.

guarded
-------

``guarded`` is a type qualifier that can be used to annotate pointers so
that pointer dereference is restricted to a ``lock`` environment. In addition
to pointers global variables can also be annotated with ``guarded``.
``Guarded`` implies ``shared``.

The first version of the language will not provide ``shared ref`` and so we're
only concerned with ``ptr`` as the base pointer type here. A new
restriction when it comes to type composition is that ``shared`` objects must
not contain any GC'ed type. However this restriction is not as bad as it seems
as you can ``GC_ref`` a GC'ed type and then cast it to ``ptr``.


New pragmas
===========

guard
-----

In addition to ``guarded`` there is also a ``guard`` pragma that can be
attached to object/tuple fields to mark them as guarded by some particular
lock. This is mostly useful for globals which need to be guarded but are
no ``ptr``.

thread
------

Procs that are run as a new thread have to be annotated with ``thread``.
Thread procs have some restrictions. In particular they must not access
globals that contain GC'ed memory. In my opinion it also helps readability
to mark what runs concurrently.

nothread
--------

Procs that only run in "serial mode" are marked ``nothread``. These can
access guarded fields without acquiring any locks. We will see these are
necessary for the "init" and "join" parts of most fork&join parallelism.
The compiler can check that ``nothread`` procs are not invoked in
a ``thread`` proc but unfortunately this doesn't suffice and prevents some
valid forms of concurrency from compiling, so it's an open problem whether
it's a good idea to do this.


New statements
==============

lock
----

``lock`` is a statement that takes a variable list of expressions of
type ``Lock``. It then acquires all the given locks *at once* and transforms
the type of the root from ``guarded ptr`` to ``shared ptr``.
``lock`` is a simplification here, in the implementation the underlying
primitives are ``acquire`` and ``release``. This way the
common and important ``while x: release; longRunningOperation; acquire``
pattern is supported.


spawn
-----

``spawn`` is a statement that passes a thread proc to some underlying
thread pool implementation and causes it to be run concurrently. The
syntax is:

.. code-block:: nim
  spawn f(arg1, ..., argN)

``spawn`` can also be used to invoke a function that has a non-void return
type ``T``:

.. code-block:: nim
  var someFuture = spawn(f(arg1, ..., argN))

``spawn`` then returns a ``Future[T]``. The parameters of ``f`` can have any
type except ``var`` for memory safety reasons. However, everything that is
GC'ed memory (``ref``, ``string``, ``seq``, and closures) is *copied* over to
the thread local heap of the thread that ``f`` will run on.

``ptr`` has to be supported because it's unsafe anyway but ``shared ptr`` is
not! Instead ``guarded ptr`` *has* to be used. This is essential for preventing
data races.

The passed function ``f`` must not perform any accesses to globals
that contain GC'ed data as this does not work with thread local GCs. As usual
we use the effect system to track accesses to globals.

``spawn`` is really the high level interface, the standard library will
also provide the low level ``createThread``.


sync
----

``sync`` waits until every ``spawn``'ed proc has returned. For more control
a ``spawn group`` can be given to both ``spawn`` and ``sync``. Then ``sync``
waits for every spawned proc in this group.



New types
=========

Future[T]
---------

A future of type ``T`` is a placeholder for a result of type ``T`` that will
arrive when you perform a read operation on it. The read operation is written
as ``^fut``.

A future is implemented as a shared pointer that only supports *destructive*
reads so that we can free the memory immediately in the read operation. The
read blocks until the data is available. When you need more control, you
should use a channel instead.


Lock[Level]
-----------

The lock statement only acts upon values of type ``Lock``. ``Lock`` is
parametrized by the lock level. Apart from that
``Lock`` is a simple opaque type that is rather uninteresting.


Queue
-----

A ``Queue`` can be used for further safe data exchange between threads. As the
parameter passing done by ``spawn`` is implemented internally via queues the
same type constraints hold: ``ref``, ``string`` and ``seq`` are copied, ``ptr``
is not, ``shared ptr`` needs to be ``guarded ptr``.



Example: Shared hash table
==========================

The following example implements a simple hash table that uses striped locks
and primitive linear probing to implement a count table. All words in all files
in some given directory are counted and then later listed. Note how the type
system encourages freedom of both deadlocks and data races.

.. code-block:: nim
  type
    Bucket = shared ptr BucketObj
    BucketObj = object
      next: Bucket
      counter: int
      word: array[0..30, char]

    Table = object
      buckets {.guard: locks.}: array[0x1000, Bucket]
      locks: array[0x100, Lock[0]]

  proc inc(b: var Bucket, word: string) =
    var it = b
    while it != nil:
      if strcmp(it.word, word) == 0:
        inc it.counter
        return
      it = it.next
    var x = allocShared0(BucketObj)
    copyMem(addr x.word[0], addr word[0], word.len+1)
    x.counter = 1
    x.next = b
    b = x

  proc worker(f: string, t: guarded ptr Table) {.thread.} =
    for line in f.lines:
      for w in line.split:
        let h = w.hash
        lock t.locks[h and (0x100-1)]:
          t.buckets[h and (0x1000-1)].inc(w)

  var
    t: Table # results are stored here

  proc listing {.nothread.} =
    # no need to lock 't.buckets' here:
    for b in t.buckets:
      var it = b
      while it != nil:
        echo "word: ", it.word, " occurances: ", it.counter
        it = it.next

  proc setup() {.nothread.} =
    for i in 0 .. <0x100: t.locks[i] = initLock()

  setup()
  for s in walkFiles(paramStr(0)):
    spawn worker(s, addr t)
  sync()
  listing()
