==================================
  A new concurrency system for Nim
==================================


A new concurrency system for Nim
================================

Part 1
------

*2013-06-22*

  Wie man sich bettet, so ruht man.

There are 2 competing paradigms when it comes to concurrency/parallelism:
Shared memory and message passing. Arguably shared memory is about parallelism
and message passing is about concurrency but these terms are not well defined
as far as I know.

In theory these 2 paradigms have been shown to be
isomorphic: You can simulate shared memory via message passing (which is what
modern hardware does, to some extent) and you can simulate message passing
via shared memory.

In practice the differences are vast: Syncronization
mechanisms for shared memory include locks, lock free low level solutions
like "compare and swap" or transactional memory.

For message passing the
question arises what to *do* with the message to ensure safety: If it
is immutable then you don't need to copy it since every access is safe by
design. Otherwise you need to perform a deep copy of the message or ensure
unique ownership by some other means. (Move semantics help to ensure
uniqueness.)

For real CPU efficiency on commodity hardware shared memory is unavoidable.
Message passing doesn't cut it and ultimately doesn't address the same problems.
(http://www.yosefk.com/blog/parallelism-and-concurrency-need-different-tools.html)
Also shared *mutable* memory is unavoidable in a systems programming context.

There are basically 2 ways to manage shared mutable memory: locks or software
transactional memory (STM). I treat "lock free datastructures" the same
as "locks" for reasons that will become obvious later. Most STM implementations
require locks under the hood so it's important to get locks right.

So which problems does lock based programming have? It's prone to deadlocks
and data races. STM helps to deal with deadlocks but doesn't help with data
races. Unfortunately races are the harder problem to solve.


Deadlocks
=========

We start with focussing on deadlocks: How can a deadlock occur?
2 threads fight for 2 locks where each already holds one lock. (Note: I use the
term "thread" for an abstract notion of CPU/thread/actor here.) There are
variations of this situation with more threads and locks but all the solutions
we will look at here deal with all of them.

There are also other ways deadlocks can be produced that involve reader/writer
locks or condition variables but I focus on traditional locking here.


Solutions
---------

1) Deadlock *detection* at runtime and aborting. This doesn't solve much. Who
   knows what to do if a deadlock is detected? The process can be terminated
   but this is unsatisfying: Bugs related to concurrency can be
   hard to reproduce and may survive testing. In a production environment
   a process failing due to a detected deadlock is barely an improvement over
   a process hanging due to a deadlock.
2) Deadlock *avoidance* at runtime. This is actually very easy to implement; in
   fact even version 0.9.0 of Nim had an implementation of it: Before
   acquiring a lock every acquired lock is released and re-acquired in a fixed
   order. This way no deadlock can happen. Unfortunately this implements the
   wrong semantics:

   .. code-block:: nim
     lock a:
       var x = readFrom(a)
       lock b:
         b = x

   If the lock 'a' is silently re-acquired in the "lock b" statement, 'x' needs
   to be re-read for consistency.

3) Deadlock avoidance at compiletime. This is what the new scheme implements.


Static deadlock freedom
-----------------------

Nim's deadlock avoidance is based on the classical idea of using explicit
lock hierarchies. We use Nim's effect system to ensure at compiletime that
the lock order is adhered to. Locks of the same lock level need to be acquired
*at the same time* with a *multi lock* statement.

This is easily implemented by acquiring the locks in the order that their
memory addresses suggest. For the very common case of acquiring 2 locks the
implementation looks like:

.. code-block:: nim
  template lock(a, b: ptr TLock; body: stmt) =
    if cast[TAddress](a) < cast[TAddress](b):
      pthread_mutex_lock(a)
      pthread_mutex_lock(b)
    else:
      pthread_mutex_lock(b)
      pthread_mutex_lock(a)
    try:
      body
    finally:
      pthread_mutex_unlock(a)
      pthread_mutex_unlock(b)

So that's the price to pay for deadlock freedom: A single additional check
at runtime that is likely to be predicted easily! (In fact, depending on the
CPU architecture, it can be implemented with a *conditional move* operation.)

There are 2 ways to define the hierarchy: By a partial order or by a total
order. We simply assign a numeric level to every lock and so gain a total
order. Using a numeric level makes things slightly easier to implement
and also slightly more flexible:

.. code-block:: nim
  type
    LevelA = TLock[10] # leave a gap in case a new abstraction layer is found
    LevelB = TLock[20] # some day

The rules the compiler enforces are:

1. When holding a lock at level L one can only acquire new locks of levels < N.
2. Multiple locks at the same level must be acquired at the same time via a
   multi lock.

The compiler tracks lock levels just like it tracks exceptions except that
exceptions can be *consumed* and locks cannot:

.. code-block:: nim
  var
    A: LevelA

  proc foo() {.locks: [10].} =
    aquire(A)
    ...
    # Note: the fact that we 'release' A here is irrelevant:
    release(A)

  proc bar() {.raises: [].} =
    try:
      raise newException(EIO, "IO")
    except EIO:
      echo "Note: effect has been consumed!"


Data races
==========

In practice race conditions are the much harder problem than deadlocks. The
reason for this is that often the programmer is not even aware of what is
shared and thus doesn't write the required synchronization operations.
*Too few* locks are the problem in the real world. Nim fights the problem
by marking everything that is shared explicitly "shared" in its type system:

.. code-block:: nim
  type
    SharedIntPtr = shared ptr int

A data race is basically when 2 threads access the same memory location where at
least one thread performs a write operation. This can only happen if the access
is not protected by a lock.

Thus ``shared`` pointers cannot be dereferenced if they are not in some ``lock``
environment. Preventing dereferencing prevents both read and write accesses
which is exactly what a traditional lock guards against and so it's a perfect
match:

.. code-block:: nim
  var sv: SharedIntPtr
  var X: TLock

  # thread A:
  lock X:
    sv[] = 12

  # thread B:
  lock X:
    echo sv[]

However, a ``lock`` environment does not suffice; in order to get consistent
results you need to acquire the *proper* lock and not simply *some* lock:

.. code-block:: nim
  var sv: SharedIntPtr
  var X, Y: TLock

  # thread A
  lock X:
    sv[] = 12

  # thread B
  # ouch! doesn't help, uses the wrong lock!
  lock Y:
    echo sv[]

(BTW Java's design encourages this scenario!
Java's ``syncronized`` keyword sometimes acts on the class's lock and
sometimes on the object instance's lock!)

Most of the complexity in type systems that statically prevent data races stems
from the fact that shared data needs a particular lock.
So ``shared`` alone doesn't cut it and ``shared[L]`` needs to be
introduced where ``L`` somehow describes the lock that protects the shared
memory region. As usual this form of type parametization is viral and needs to
be taken into account everywhere: For instance, functions over shared pointers
become parametrized too.

Lock parametrization leads to something like:

.. code-block:: nim
  type
    SharedIntPtr[L] = shared[L] ptr object
      value: int
      protection: L
  var
    sv: SharedIntPtr[TLock]

  # thread A
  lock sv:
    sv[] = 12

  # thread B
  # yay, safe:
  lock sv:
    echo sv[]

We need some more magic here to map the field ``protection`` to the lock ``L``
so that the ``lock sv`` statement is correctly expanded
to ``aquire(sv[].protection); ...`` Many languages make the lock implicit for
reasons like this, for example in Java every oject has its own associated
lock. This is potentially wasteful (most objects will never be locked) and is
an unacceptable solution for systems programming which is about exposing
low level implementation details.

Apart from the resulting type system complexity this solution has the serious
drawback that it cannot express various forms of *striped locks* (it can
express some forms though):

.. code-block:: nim
  # idea: use 1 lock for 8 enties in the 'data' array:
  type
    SharedStuff[L] = shared[L] ptr object
      data: array[64, int]
      locks: array[8, L]

  var
    sv: SharedStuff[TLock]

  # thread A:
  lock sv: # uh oh, which lock to acquire?
    sv[].data[9] = 19

For reasons like this Nim uses a novel approach to solve the problem: The
``lock`` statement still takes a concrete lock field but the *root* of the path
leading to that field is unlocked which means that the pointer can be
dereferenced (its type is transformed from ``shared ptr`` to ``ptr``).

This system requires the programmer to know which lock corresponds to which
variables. In the following case we will distribute evenly the array of ints
so that eight consecutive values are handled by the same lock.

.. code-block:: nim
  type
    SharedStuff = shared ptr object
      data: array[64, int]
      locks: array[8, TLock]

  var
    sv: SharedStuff

  # thread A:
  # we are allowed to dereference 'sv' here, but only to access a lock!
  lock sv[].locks[1]:
    # ok, since the root of the path 'sv[].locks[i]' is 'sv' we are
    # allowed to dereference 'sv' here:
    sv[].data[9] = 19

  # thread B
  # ok, safe:
  lock sv[].locks[0]:
    echo sv[].data[1]

  # thread C
  # ugh, bug here, since entry 9 is not protected by lock 0!
  lock sv[].locks[0]:
    echo sv[].data[9]


This solution trades expressivity for correctness: Not every possible data race
is prevented. However it surely looks like a sweet trade-off. If you can ensure
that each ``shared ptr`` only has 1 reachable lock (which is pretty easy to
check) then it's as correct as the parametrized version but much simpler.

To be completely honest I have to mention that this solution also allows for
some races when it comes to lock construction/mutation as an unprotected
dereference to 'sv' is allowed to access the lock itself. I consider this an
edge case which does not happen in practice. In pratice the shared memory is
allocated and the associated locks are created before concurrent access to the
memory happens.


Lockfree programming
--------------------

Lockfree programming requires not much further support in the language:
A ``lockfree`` statement suffices that transforms the type from ``shared ptr``
to ``ptr``.

In other words there can be further constructs that statically work like
``lock`` but translate into very different things like:

* memory barriers in all their various forms,
* no CPU instructions at all (when you can guarantee it's a unique pointer, for
  example).


So now that we've seen the basic ideas of Nim's new concurrency model, it's
high time for a more formal description. Stay tuned for part 2.
