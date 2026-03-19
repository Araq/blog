====================================
   Implementing NIF in Nim
====================================


Implementing NIF in Nim
=======================

*2026-03-19*

This is a follow-up to the NIF introduction. Here I focus on how NIF is
implemented in Nim and what makes it special.


Data model: tokens, not trees
-----------------------------

Nim is based on ASTs ("abstract syntax trees"). Nim is somewhat special in that it
exposes its AST to programmers directly in its macro system. For [Nimony](https://github.com/nim-lang/nimony), I revisited
this design decision, as ASTs are not as flexible as token streams: transformations
often become simpler when the structure can be broken up for a short amount of time.
We'll see examples of this later.

Hence the entire implementation is based on token streams! A token is represented as:

```nim

type
  PackedToken* = object
    x: uint32
    info*: PackedLineInfo

```

A `PackedToken` takes 8 bytes in memory. The `x` payload field is conceptually:

```nim
type
  NifKind* = enum
    UnknownToken, EofToken,
    DotToken, Ident, Symbol, SymbolDef,
    StringLit, CharLit, IntLit, UIntLit, FloatLit,
    ParLe, ParRi

type
  Payload = object
    case kind: NifKind  # 4 bits
    of UnknownToken, EofToken, DotToken:
      discard
    of Ident:
      name: StrId   # 28 bits
    of Symbol, SymbolDef:
      id: SymId     # 28 bits
    of StringLit:
      str: StrId    # 28 bits
    of CharLit:
      c: char       # 8 bits
    of IntLit:
      i: IntId      # 28 bits
    of UIntLit:
      u: UIntId     # 28 bits
    of FloatLit:
      f: FloatId    # 28 bits
    of ParLe:
      tag: TagId    # 28 bits
    of ParRi:
      discard
```

As you can see, we couldn't use this structure directly, as Nim doesn't offer 4- and 28-bit numbers.
So in the implementation we use getters and setters to extract the bits from the `x` field. The code
for that is negligible in the greater scheme of things. Nimony is about 56_000 lines of code.

The type `TokenBuf` is a custom seq-like type that
stores a list of tokens. `TokenBuf` is an append-only buffer that supports a runtime "frozen"
mode turning it immutable for an arbitrary number of readers. The readers are called "cursors"
and they are lightweight objects that can be used to traverse the token stream. More on this later.




Line information in 4 bytes
---------------------------

Line information is aggressively packed in `nimony/src/lib/lineinfos.nim`. The
format uses a **32-bit** value with a split layout:

- 10 bits for file id (up to 1024 files),
- 14 bits for line,
- 7 bits for column,
- 1 bit for "aside" storage or payload.

If any field overflows, the line info is stored in a side table. This keeps
the common case small and makes line info cheap enough to store on every token.


Open-ended tags, but enums everywhere
-------------------------------------

NIF's tag set is extensible, yet the implementation uses **enums instead of
strings** almost everywhere. This is achieved by code generation:

- `nimony/tools/gen_tags.nim` reads `doc/tags.md`.
- It emits `TagEnum` and a number of tag-specific enums.
- All enums use the same numeric tag ids, so they are **byte-compatible**.

This gives you compile-time safety and compact storage for tags while keeping
the format open-ended. Unknown tags still flow through as plain tag ids; known
tags get a typed enum in the layer that cares about them.


Token streams, `TokenBuf`, and `Cursor`
---------------------------------------

The "tree" is represented as a stream of `PackedToken` values. There are two
core roles:

- **Producers** build token buffers (`TokenBuf`) by appending tokens.
- **Traversals** use lightweight `Cursor` objects to walk the stream.

`TokenBuf` is an append-only buffer with a small growable array. It supports
bulk operations like "add subtree", insertion, and replacement without building
node objects. `Cursor` is a thin pointer + remaining-length pair that can skip
subtrees by counting parentheses. This gives you tree-like operations without
allocating a tree.

The crucial detail is that `ParRi` is **explicit** in the stream. We never
reconstruct a tree only to throw it away again; the closing parentheses are
already there, so a traversal can skip subtrees and splice new ones in place.
The tree exists only *implicitly* in the call stack as we traverse the token stream.


Memory safety of cursors
------------------------

A `Cursor` is a read-only view into a `TokenBuf`. When you create a cursor via
``beginRead``, the buffer is **sealed** — it cannot be modified while any cursor
is active. This prevents the classic iterator invalidation bugs where a
container is mutated during traversal.

Cursors also carry a ``rem`` field: the number of tokens remaining in the view.
Every ``inc`` operation decrements ``rem``, and every ``skip`` decrements it by
the size of the skipped subtree. This gives us **spatial memory safety** — a
cursor cannot walk past the end of its buffer because ``rem`` bounds every
operation.

What we lack is **temporal memory safety**. A cursor does not keep its buffer
alive. If the ``TokenBuf`` is deallocated while a cursor still points into it,
you get a dangling pointer. In Nim terms, a ``Cursor`` should probably use
custom lifetime tracking hooks for keeping the buffer itself alive, but currently it
does not.

In practice, the resulting bugs have been found quickly — the access patterns
are predictable enough that dangling cursors manifest as immediate crashes
rather than silent corruption. But this is an immature solution. A more robust
design would have cursors prevent their buffers from being deallocated.
For now, discipline and short cursor lifetimes are the workaround.


Nim 2's lifetime hooks in action
--------------------------------

This safety model is only possible because of **Nim 2's lifetime tracking
hooks**. A ``TokenBuf`` has copying disabled:

.. code-block:: nim

   type
     TokenBuf* = object
       data: seq[PackedToken]
       readers: int  # number of active cursors

   proc `=copy`*(dest: var TokenBuf; src: TokenBuf) {.error.}

The ``{.error.}`` annotation makes any attempt to copy a ``TokenBuf`` a
compile-time error. This is essential: if buffers could be silently copied, the
sealing mechanism would be meaningless — you could seal a copy while mutating
the original.

Instead, buffers must be explicitly moved (``ensureMove``). The ``readers``
field tracks how many cursors are active; ``beginRead``
increments it and ``endRead`` decrements it. Any mutation while there are readers left
is a runtime error.

The hooks — ``=copy``, ``=sink``, ``=destroy`` — give us fine-grained control over
when and how data moves through the system. Most Nim programmers use these hooks
indirectly through the standard library. Here we use them directly to give us
exactly the data structures we need.

This is what Nim 2's ownership model enables; Nim 1 could not express custom containers well.
**The language's own advances are enabling its successor.**


Tree transformations without trees
----------------------------------

This design makes transformations surprisingly direct. Some real examples:

- `nimony/src/nimony/derefs.nim` inserts hidden `haddr` / `hderef` nodes by
  walking a `Cursor` and emitting a new `TokenBuf`. The logic is entirely about
  token sequences and parentheses balancing.
- `nimony/src/hexer/duplifier.nim` performs ownership-aware rewrites (dup,
  move, destroy) with the same model: scan with a cursor, emit into a buffer,
  skip subtrees when needed.
- `nimony/src/njvl/nj.nim` turns Nimony IR into a jump-free NJVL form and uses
  `closeBasicBlock` to close pending `else` branches by emitting `ParRi` tokens.
  The correctness of the transformation is tied directly to balancing those
  explicit sentinels.

There is no temporary AST. The "tree" exists only as a traversal of tokens
with explicit `ParLe` and `ParRi` markers. This is unusual in compiler
construction, but it keeps transforms fast, local, and extremely memory
efficient.


Why explicit `ParRi` matters
----------------------------

Keeping closing parentheses explicit is not busy-work; it is a mild form of
proof that a traversal covered the whole structure. When you walk a token
stream, you must consume every `ParRi` you encounter. If you forget to process
or skip a subtree, your `ParRi` accounting breaks and the error surfaces
immediately.

In a node-based design, it is easy to accidentally skip a child like `n.left`
or `n.right` and still produce a "valid" tree. The token stream model makes
completeness visible: you either reach the expected `ParRi` or you do not. That
property provides a small but practical correctness check for transformations.

To the best of my knowledge, this style of compiler construction — treating
the token stream (with explicit closing sentinels) as the primary representation
and never materializing an AST — is uncommon, and I have not seen it described
elsewhere.


Text editing: Flat vs nested structures
---------------------------------------

Every programmer knows that text is easier to edit than structured data. Want to
insert a statement between two others? Move the cursor between the statements
and start typing. Want to wrap an expression
in a function call? Add characters to both sides. Text editing is *local* — you
modify bytes at a position without worrying about global invariants.

It keeps text-like locality (emit tokens where you are) while preserving
structure through explicit ``ParLe``/``ParRi`` sentinels. You can defer closure
briefly during a transformation, but you still have to balance delimiters, so
mistakes surface as soon as the stream no longer matches.

This also avoids a common redundancy in tree-based pipelines: the traversal
already encodes structure in its recursion, so materializing that same structure
as mutable nodes is often unnecessary.


Example: call checking needs tandem traversal
---------------------------------------------

A more representative example is call checking in semantic analysis. You do not
traverse one structure; you traverse at least two in tandem:

- the call's argument list from the source expression, and
- the routine's parameter/type-signature structure.

Then you often traverse additional structures at the same time: explicit generic
arguments, inferred type arguments, defaults, named-argument reordering, and
possible converter insertions.

In a tree-only design, this tends to become nested recursion over multiple node
hierarchies. In Nimony's stream model, much of this can stay as coordinated
linear cursor movement plus local rewrites. That is the practical win: fewer
deep recursive walkers for the common "match two evolving sequences" problem.


Helper structures on demand
---------------------------

A common objection is: "But what about symbol tables? Type environments? Don't
you need data structures for those?"

Yes — and the token stream model handles this elegantly. **Helper structures are
built on demand for each pass and then discarded.** They do not become part of
the persistent representation.

Consider the duplifier pass:

.. code-block:: nim

   var c = Context(lifter: lifter, typeCache: createTypeCache(),
     dest: createTokenBuf(400))
   c.typeCache.openScope()
   var n = n
   tr(c, n, WantNonOwner)
   # ... pass completes, context is discarded ...

The ``TypeCache`` exists only for this pass. It is built, used, and discarded.
The next pass starts from the stream and creates its own view.

This is a much healthier architecture than the typical compiler where the AST
accumulates cruft over time — type annotations bolted onto nodes, symbol
resolution baked in, various "decorated" intermediate forms. Each pass adds its
own concerns to the tree, and eventually you have a bloated, multi-purpose data
structure that serves everyone and no one well.

In the token stream model, the data (token streams) and the algorithms (passes
with their local state) are cleanly separated. **The streams stay lean and
uniform. The complexity lives in transient scaffolding that vanishes when the
pass ends.**

This also explains why random access patterns rarely matter. If you need indexed
lookup into the program, you build an index for that pass. The cost is amortized
over the work the pass does anyway, and you are not paying for structure you do
not need.


Key takeaways
-------------

The token stream model is not just a space optimization; it is an architectural
choice:

1. **The stream is the source of truth.** Modules persist as token streams.
   Everything else is derived.

2. **Transformations are local.** Emit at the current position and balance
   delimiters as you go, without tree surgery.

3. **Helper structures are ephemeral.** Build what you need for a pass, then
   discard it. The architecture stays simple because complexity does not
   accumulate.

4. **Explicit sentinels provide safety.** ``ParRi`` accounting shows quickly
   when a traversal went wrong.

This combination — the freedom of text editing, the safety of structured
representations, and the simplicity of transient auxiliary data — is, to the
best of my knowledge, unexplored territory in compiler design. Nimony is a
proof that it works.
