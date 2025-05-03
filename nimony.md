# Nimony: Design principles

*2025-05-03*

[Nimony](https://github.com/nim-lang/nimony) is a new compiler for a variant of Nim which will become Nim 3.0, eventually.
However, Nim is a big language so replicating what it does will take its time.

While we wait for this to happen, it turns out Nimony implements a streamlined,
beautiful language useful in its own right! This article aims to describe this
language here.

Following Nim's evolution, we aim to support hard real-time and embedded systems
with a (mostly) memory safe language. The primary reason for the choice of this domain
is generality: If you can run well on embedded systems you run well on everything else.

WCET ("worst case execution time") is an important consideration: Operations should
take a fixed amount of time and the produced machine code should be predictable. This
rules out just-in-time compilers and tracing garbage collectors. The primitive types
like `int` and `char` directly map to machine words and bytes. Complex types are formed
without indirections: An object with fields `a, b: float` takes up `2 * sizeof(float)`
bytes and is inlined directly into a stack frame or an embedding structure.


## Automatic memory management

Automatic memory management (MM) is crucial for safety: If memory is not freed explicitly
then it cannot be used after it has been freed! There are other solutions that offer both
explicit MM and safety but Nim focuses on concise code. Implicit is good.

Like Nim 2.0, Rust and C++, Nimony offers scope-based MM based on destructors and move semantics.
Unlike Nim 2.0 the plethora of `mm` switches is gone, only `mm:atomicArc` is offered. There is
a novel cycle collection algorithm in development but it's unclear if or when it will be ready
for production. In any case, objects involved in potential cycles need to be annotated with the new `.cyclic` pragma, as `.acyclic` is the new default.

MM based on destructors has the tremendous advantage that it actually **composes**: A `seq` of
channels which require OS resource deallocation simply works. No other MM system offers this:
Neither GCs with their unpredictable finalizers nor region-based MM which tends to keep objects around for much longer than necessary.


## Error handling

"Modern" languages try to avoid exceptions by using sum types and pattern matching plus lots of sugar to make this bearable. I personally dislike both exceptions and its emulation via sum types. The "early returns" can get in the way no matter how you write them: `for x in collection: ?destroy(x)` admittedly makes the problem easier to spot ("if an error occurs, not everything is destroyed") but even a single `?` can get in the way: An expression like `fib(n-1) + fib(n-2)` could hypothetically become something like `?fib(n -? 1) +? ?fib(n -? 2)`, or a more complex language rule like "`?` is applied to all nested call expressions" needs to be introduced.

I personally prefer to make the error state part of the objects: Streams can be in an error state, floats can be NaN and integers should be `low(int)` if they are invalid (`low(int)` is a pointless value anyway as it has no positive equivalent).

If such an object is not available, a thread-local error variable can be used as a side channel to signal errors. One can easily attach a stack trace to such an error and it can be checked whenever convenient. This changes the default from "on error return" to "on error continue".

Nevertheless Nimony offers Nim's traditional exception handling, but with a twist: A routine
that can raise an exception must always be annotated with `{.raises.}`. It is not possible to
say which exceptions are possible as the important aspect here is that the call of the routine
introduces hidden control flow.



### Error codes

There is one programming construct that I have never regretted using: Nim's type-safe `enum`. It is simple, offers optimal performance and forces me to enumerate and handle all possible cases. Consequently Nimony allows to raise the new `ErrorCode` enum in addition to the ordinary exceptions (which are based on inheritance):

```nim
import std/errorcodes

proc p(x: int) {.raises.} =
  if x < 0:
    raise ErrorCode.RangeError
  use x
```

I hope that the `ErrorCode` enum will give us a unified way to propagate errors between different libraries. How `ErrorCode` is mapped from and to POSIX errno values, Windows API errors and HTTP status codes was a core
consideration of its design. My vision is that Nim based services correctly report e.g. HTTP status code 507
(the disk is full), without any effort as it was encouraged by the language and its standard library.

As another nice benefit we get error handling based on `raise` that does not need to use heap allocations.
OOM can be propagated without having to preallocate the OOM exception object.


### Out of memory (OOM)

OOM is a misnomer that obfuscates the real problem: The system is not able to fulfill *one* particular
request of a specific size. This size can be large and other smaller sizes might still be available.
The prevalent wisdom of "die on OOM instead of limping along" is the result of laziness or rather
a tradeoff between development effort and robustness. With effort one can treat OOM as yet another
possible error state and continue execution, even if only to map it to a 507 HTTP error code properly.

In any case, it is very telling that the supposedly "superior" solutions to exception handling
usually fall short in this regard and leave little options to handle OOM gracefully.

Nimony's solution to OOM is quite unique: Containers that fail to allocate memory call an
overridable `oomHandler`. The default handler remembers the size of the failing request and
then execution continues. One can then query for this case via `threadOutOfMem()`.
Of course, one can set the `oomHandler` to a custom proc that simply tears down the application.

Nim's `ref` object construction (either by `new` or by `ObjectRef(...)`) can also fail. Thus it can return `nil`. Nimony will make a `nil` bug a thing of the past, enforcing that it is dealt with in the code like an `Option` type. This can become tedious for object construction which can be very frequent. An elegant solution here is to map the `nil` value to `ErrorCode.OutOfMemError` automatically if the proc was annotated with `.raises`:

```nim

proc constructTree(payload: sink string): Node {.raises.} =
  result = Node()
  # can assume result != nil here as we are in the .raises context:
  result.field = payload
```

This design to handle OOM does not depend on exceptions but can be used in combination with them. Experience
with it will tell us whether it holds up well for realistic systems or not.



## Generic code

Static type checking is the biggest productivity boost that I know of. It is also an incredible
tool to get reliable performance out of primitive language implementations. A static type
system is incomplete without generics. Generics are a hard requirement for custom containers
like sequences, tables and trees. And once custom containers work sufficiently well, the
need for built-in containers diminishes! So Nimony's `seq` is a pure library implementation
and `string` only has very little compiler magic so that string literals are of type `string`.

Nimony improves on Nim's generics by performing complete type checking on generic code, not merely on generic instantiations. This allows to catch errors early and to provide better error messages, but most importantly it allows an IDE to provide precise completion suggestions. Nim's `concepts` are essential for type checking generic code:

```nim
type
  Fibable = concept
    proc `<=`(a, b: Self): bool
    proc `+`(x, y: Self): Self
    proc `-`(x, y: Self): Self

proc fib[T: Fibable](a: T): T =
  if a <= 2:
    result = 1
  else:
    result = fib(a-1) + fib(a-2)
```

Without declaring that `T` must be `Fibable` the compiler rejects `proc fib`. A generic parameter can always be used in assignments though, otherwise code like `let x = y` would need to be rejected only to discover later that `y` should have been moved anyway. Move analysis happens later after type checking so some compromises are necessary.



## Concurrency & Parallelism

Nimony unifies async and multi-threaded programming. There is only one construct for both written as `spawn`.
Whether this runs on the same thread or a different one is decided at runtime by a scheduler. This means that
in `spawn f(args)` the restrictions for `args` must always enforce thread safety. This is a good thing as
the concurrency that is provided by asynchronous programming introduces many of the same pitfalls as
multi-threaded programming.

Nimony's concurrency model will be based on continuations. The compiler will transform the program
into continuation passing style (CPS). The programmer does not notice much, however. The exposed interface
is via a `scheduler` module and its `spawn` operation. `scheduler.spawn f(args)` is the
core of the design.

Parallelism is fundamentally simpler to implement than concurrency: The reason is that `spawn f(args)`
can be translated to `threadpool.send toTask(f, args)` which is a *local* transformation. The rest of
the function does not have to be transformed. No CPS is needed.
However, a high performance thread pool implementation can also benefit from CPS so again the unification
of `await` and `spawn` does not hurt.


## Pure parallelism

When writing [Malebolgia](https://github.com/araq/malebolgia) there was something that bugged me about the typical parallel Fibonacci example:

```nim
proc fib(n: int): int =
  if n < 2: return n
  parallel:
    let a = spawn fib(n-1)
    let b = spawn fib(n-2) # `spawn` is optional here for the second call?
  return a + b
```

can also be written as

```nim
proc fib(n: int): int =
  if n < 2: return n
  parallel:
    let a = spawn fib(n-1)
    let b = fib(n-2) # left out the `spawn`. Potentially more efficient.
  return a + b
```

The asymmetry of the recursive `fib` invocations is ugly.

Usually there are also non-obvious rules about when `a` and `b` can be read from. These issues, as minor as they might seem, do not exist with a `parallel for` loop:

```nim
proc fib(n: int): int =
  if n < 2: return n
  var a: array[2, int]
  for i in 0 || 1: # `||` is the parallel for loop iterator
    a[i] = fib(n-i-1)
  return a[0] + a[1]
```

The last iteration of a parallel loop can always be run on the calling thread but it's neither necessary nor possible to write this out.

In a parallel for loop we know by design that the induction variable `i` creates a disjoint set of locations for `a[i]`. We also know that after the loop all the parallelism is over, it produces exactly the kind of "structured" parallelism that Malebolgia provides.

So Nimony should offer `parallel for` loops. With these we can write parallel array processing programs without flow vars! This is important as much of scientific computing and GPU programming is done with `Matrix[float]` and not `Matrix[FlowVar[float]]`.



## Meta programming

The `spawn` construct is in reality not built into the language but implemented as a compiler plugin.
Plugins are the final evolved form of Nim's macros:

1. They are compiled to machine code so that every language feature can be used, including low-level unsafe constructs.
2. They usually run after type-checking, in Nim's terms they use `typed` parameters. This means complete type information is available for introspection.
3. There will be more convenient APIs available for plugin development. Thanks to NIF many transformations become simpler and can be done without recursions.
4. They run incrementally and in parallel just like the rest of the compilation pipeline.

For a simple example we will write a plugin that does the same as this simple template:

```nim
template generateEcho(s: string) = echo s
```

A plugin is a template that lacks a body. Instead it has a `{.plugin.}` pragma listing the Nim program that implements the plugin:

```nim
import std / syncio

template generateEcho(s: string) {.plugin: "deps/mplugin1".}

generateEcho("Hello, world!")
```

In "deps/mplugin1.nim" we write the implementation:

```nim
import std / os

include lib / nifprelude
import nimony / nimony_model

proc tr(n: Cursor): TokenBuf =
  result = createTokenBuf()
  let info = n.info
  var n = n
  if n.stmtKind == StmtsS: inc n
  result.addParLe StmtsS, info
  result.addParLe CallS, info
  result.addIdent "echo"
  result.takeTree n
  result.addParRi()
  result.addParRi()

let input = os.paramStr(1)
let output = os.paramStr(2)
var inp = nifstreams.open(input)
var buf = fromStream(inp)

let outp = tr(beginRead buf)

writeFile output, toString(outp)
```

As there is currently no API for plugins, we have to import parts of the Nimony compiler and the code is a bit ugly. But it works!

Plugins that are attached to a template receive only the code that is related to the template invocation. But `.plugin` can also be a statement of its own, then it is a so called "module plugin".


### Module plugins

A module plugin receives the full code of a module. It needs to output back the complete module with some of its transformations locally applied.

To implement `spawn` as a plugin more than the `.plugin` annotation is required. To see why consider that the continuation of `let x = spawn f(args); cont` is the `; cont` part and that is what an async scheduler is interested in running later. So `; cont` must be turned into a function of its own. But like a macro `spawn` as a plugin **cannot see** the rest of a proc! Some top-level annotation like `.async` would be required. The module plugin is a new feature that allows us to leave out an `.async` annotation:

```nim
type
  Scheduler* = object
    tasks: seq[Task]

template spawn*[T](s: var Scheduler; call: T) =
  {.plugin: "stdplugins/cps".}
  s.enqueue toTask(call)
```

When `spawn` is called/expanded the compiler remembers that the full module should be passed to a `cps` plugin.

Since iterators are expanded much like templates a `.plugin` statement is lazily applied here too. The outlined parallel for loop iterator `||` can be written as:

```nim
iterator `||`*[T: Ordinal]*(a, b: T): T =
  {.plugin: "stdplugins/parfor".}
  var i = a
  while i <= b:
    yield i
    inc i
```

Module plugins can also be attached to a nominal type (or a generic type that becomes a nominal type after instantiation). These plugins are invoked for every module that uses the type. This mechanism can replace Nim's "term rewriting macros":

```nim
type
  Matrix {.plugin: "avoidtemps".} = object
    a: array[4, array[4, float]]

proc `*=`(x: var Matrix; y: Matrix) = ...
proc `+=`(x: var Matrix; y: Matrix) = ...
proc `-=`(x: var Matrix; y: Matrix) = ...

proc `*`(x, y: Matrix): Matrix =
  result = x; result *= y
proc `+`(x, y: Matrix): Matrix =
  result = x; result += y
proc `-`(x, y: Matrix): Matrix =
  result = x; result -= y
```

Code like `let e = a*b + c - d` is then rewritten to:

```nim
var e = a
e *= b
e += c
e -= d
```

Avoiding the creation of temporary matrices entirely.

While the code for the avoidtemps plugin is beyond the scope of this article, this is a classical compiler transformation; especially the x86 architecture with its 2 operand instructions requires it too.


## Conclusion

Nimony represents an ambitious evolution of the Nim programming language, incorporating lessons learned from years of practical experience with Nim, while introducing novel approaches to error handling and meta-programming. As a work in progress, Nimony is being actively developed with a target release date in autumn 2025.

If you want to help us with development, [deepwiki](https://deepwiki.com/nim-lang/nimony) produced an excellent overview of our compiler architecture. Yes, it is AI generated but it's correct, I reviewed it.

If you want to support us, please contribute to https://opencollective.com/nim! Stay tuned for updates and early preview releases as we progress toward this milestone.
