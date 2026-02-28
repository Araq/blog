=====================================================
   The unreasonable effectiveness of S-Expressions
=====================================================



The unreasonable effectiveness of S-Expressions
===============================================


*2026-02-28*


It is well known that unique pointers are sufficient to model trees. A unique pointer is also often called a "linear" pointer, in theory one can embed the data that it points to directly into your parent object:

.. raw:: html

  <diagram>

  Tree with unique pointers:          Embedded/flattened representation:

          ┌─────┐                      ┌───────────────────────┐
          │  A  │                      │  A                    │
          │  1  │                      │  1                    │
          └─┬─┬─┘                      │  left: [B]            │
            │ │                        │    ┌──────────────┐   │
        ┌───┘ └───┐                    │    │ B            │   │
        │         │                    │    │ 2            │   │
      ┌─┴─┐     ┌─┴─┐                  │    │ left: [D]    │   │
      │ B │     │ C │                  │    │   ┌──────┐   │   │
      │ 2 │     │ 3 │                  │    │   │ D    │   │   │
      └─┬─┘     └───┘                  │    │   │ 4    │   │   │
        │                              │    │   └──────┘   │   │
    ┌───┴───┐                          │    │ right: [E]   │   │
    │       │                          │    │   ┌──────┐   │   │
  ┌─┴─┐   ┌─┴─┐                        │    │   │ E    │   │   │
  │ D │   │ E │                        │    │   │ 5    │   │   │
  │ 4 │   │ 5 │                        │    │   └──────┘   │   │
  └───┘   └───┘                        │    └──────────────┘   │
                                       │  right: [C]           │
                                       │    ┌──────────────┐   │
                                       │    │ C            │   │
                                       │    │ 3            │   │
                                       │    │ left: null   │   │
                                       │    │ right: null  │   │
                                       │    └──────────────┘   │
                                       └───────────────────────┘

  Unique pointers ────────────────> Embedded in parent
  (one owner)                       (linear structure)

  </diagram>

The key insight: because each unique pointer has exactly one owner, we can "unroll" the tree
and store child nodes directly within their parent's memory layout, eliminating indirection.

Since the tree can be stored in a flat array, we can make the array's elements of flexible size.
This can be achieved in two ways: either by length information (storing how many bytes each
element occupies) or by sentinel values (using a special marker to indicate where each element ends).

If we restrict ourselves to text, the sentinel value can be ``)`` and the tree header can become
``(``. We arrived at S-expressions! The parentheses naturally encode the tree structure: ``(`` marks
the start of a node (which may contain child nodes), and ``)`` marks its end. This elegant
encoding allows trees to be represented as simple text strings while preserving the hierarchical
structure through the nesting of parentheses.


.. raw:: html

  <diagram>

  Tree structure:                    S-expression representation:

          ┌─────┐                    (A (B (D) (E)) (C))
          │  A  │
          └─┬─┬─┘
        ┌───┘ └───┐
        │         │
      ┌─┴─┐     ┌─┴─┐
      │ B │     │ C │
      └─┬─┘     └───┘
        │
    ┌───┴───┐
    │       │
  ┌─┴─┐   ┌─┴─┐
  │ D │   │ E │
  └───┘   └───┘

  Each `(` marks the start of a node
  Each `)` marks the end of a node
  The nesting encodes the tree hierarchy

  </diagram>


Tags and Two Namespaces
=======================

Traditional S-expressions, as used in Lisp, have a fundamental limitation: the first element
in a list is implicitly treated as a function call. For example, ``(f x y)`` means "call function
`f` with arguments `x` and `y`". This creates a tension between the syntax (which is just a tree)
and the semantics (which assigns special meaning to the first position).

The [NIF](https://github.com/nim-lang/nifspec) format (Nim Intermediate Format) extends S-expressions with an explicit **tag** (also
called "node kind") that specifies what kind of node we're dealing with. Instead of ``(f x y)``,
NIF uses ``(call f x y)`` where ``call`` is the tag that indicates this is a function call node.

More importantly, NIF uses **two separate namespaces**:

1. **Tag namespace**: Used for node kinds like ``call``, ``proc``, ``type``, ``if``, etc.
   These specify the *structure* of the AST.

2. **Identifier namespace**: Used for source-level identifiers like variable names, function names, etc.
   These represent the *content* of the program.

This separation is crucial for extensibility. In traditional languages with fixed keywords, adding
a new construct requires reserving a keyword, which can break existing code that uses that word as
an identifier (for example, introducing ``match`` can invalidate ``let match = 3``). In NIF, new tags
can be introduced without any risk of collision because tags and identifiers live in completely
separate namespaces.

This design also elegantly resolves the old **Lisp 1 vs Lisp 2** debate:

- **Lisp 1** (e.g., Scheme): Functions and variables share the same namespace. You cannot have
  both a function and a variable named ``foo``.

- **Lisp 2** (e.g., Common Lisp): Functions and variables have separate namespaces. You can have
  ``(defun foo ...)`` and ``(defvar foo ...)`` without conflict.

- **NIF's approach**: Tags and identifiers are in separate namespaces, which is even more general.
  You can have a tag named ``foo``, an identifier named ``foo``, and they never conflict because
  they're used in different contexts. The tag appears as the first element in a compound node to
  specify structure, while identifiers appear as children to represent program content.

For example, in NIF you could have:

```nif
(proc :foo.0 (params (param x i32)) (call foo x))
```

Here, ``proc`` is a tag (node kind), ``foo.0`` is an identifier (symbol), and ``call`` is another
tag. The identifier ``foo`` can be used freely without any concern that it might conflict with
the tag ``proc`` or ``call``, because they occupy different namespaces.

This two-namespace design makes NIF highly extensible: new language constructs can be added simply
by introducing new tags, without worrying about keyword conflicts or breaking existing code.

NIF includes a subtle syntactic innovation that makes parsing remarkably
simple: the ``(`` and ``)`` separators **cannot occur literally** in comments, string literals, or
names — they must be escaped using hex escapes like ``\28`` for ``(`` and ``\29`` for ``)``. Moreover,
the escape sequences themselves use ``\`` followed by two hex digits (e.g., ``\5C`` for backslash), so
they never contain ``(`` or ``)`` either. This means you can **detect the tree structure reliably
without a full lexer** — just scan for ``(`` and ``)`` to find matching parentheses, knowing that any
``(`` or ``)`` you encounter outside of an escape sequence is a structural delimiter, not part of the
content.

To see the value of this, consider the fact that the "count character '('" feature of your editor gives a
reliable number of nodes in the tree!


Tag Namespaces and Semantics
============================

While the separation of tags and identifiers solves the collision problem, there's still the question
of *semantics*: what does a tag like ``div`` or ``proc`` actually mean? Different systems might use
the same tag name for different purposes, or the same concept might be represented by different tags
in different systems.

NIF addresses this through the ``.lang`` tag, which specifies which tag system (and thus which
semantics) should be used to interpret the tags within its scope. The ``.lang`` tag effectively gives
a system of tags both a namespace and concrete semantics. Crucially, ``.lang`` is itself a tag (in parentheses),
which enables **nesting different languages within a single document**.

In the context of compilers this is very useful for inline assembler or Nim's `emit` pragma which allows you to embed C/C++
or JavaScript code directly in your Nim code.

With the same mechanism NIF elegantly subsumes HTML, CSS, JavaScript, and XML.

For example:

```nif
(.lang html
  (div (p "Hello World"))
)
```

Here, ``(.lang html ...)`` tells the parser that tags like ``div`` and ``p`` within this scope should be
interpreted according to HTML semantics. The exact semantics are defined by the tools that consume
the tags, so a language is a contract, not a magic keyword. The same file could switch to a different
language:

```nif
(.lang nim
  (proc :foo.0 (params (param x i32)) (ret x))
)
```

Now ``proc``, ``params``, and ``ret`` are interpreted according to Nim's AST semantics.

The real power emerges when you nest languages:

```nif
(.lang html
  (div
    (.lang css
      (rule ".style" (prop "color" "blue"))
    )
    (p "Text")
    (.lang js
      (call console.log "Hello")
    )
  )
)
```

All of these can coexist in the same document, with language contexts nested as needed. A single
NIF parser can handle multiple languages by switching tag semantics based on the enclosing ``.lang``
tag. This makes NIF a universal tree representation format that can encode any structured data or
program representation, with the ability to mix and nest different semantic systems within a single
file.


Symbols, Indexes and the Module System
======================================

While tags provide structure, **symbols** (names with dots like ``foo.2.mymodule``) provide identity
and enable cross-module references. NIF's symbol naming scheme introduces a natural module system
that transforms the format into something more powerful than a simple text file.

Symbols in NIF come in two forms: **local symbols** and **global symbols**.

**Local symbols** follow the format ``<name>.<disamb>`` where:
- ``name`` is the original identifier
- ``disamb`` is a disambiguation number (e.g., ``0`` for the first symbol named ``foo``)

For example, ``foo.0`` refers to the first symbol originally named ``foo`` in the current module.
Local symbols are scoped to their module and are not part of the optional index structure.

**Global symbols** follow the format ``<name>.<disamb>.<module>`` or ``<name>.<disamb>.<key>.<module>`` where:
- ``name`` is the original identifier
- ``disamb`` is a disambiguation number (e.g., ``2`` for the second symbol named ``foo``)
- ``key`` (optional) is a generic key, usually the result from a generic instantiation
- ``module`` is the module suffix (derived from the filename)

For example, the second procedure named ``foo`` in module ``mymodule`` becomes ``foo.2.mymodule``.
A generic instantiation might produce ``foo.0.i32.mymodule`` where ``i32`` is the generic key.
Global symbols can be shortened with a trailing dot: ``foo.2.`` expands to ``foo.2.mymodule``
when the current file is ``mymodule.nif``.

The **generic key** serves an important purpose beyond just identifying generic instantiations: it enables
**deduplication**. Symbols with the same name, disambiguation number, and generic key represent the same
entity, even if they appear in different modules. This is particularly valuable in a sharded database
context, where the generic key can indicate **replicated data** — the same generic instantiation might
be stored in multiple shards, and the key allows the system to recognize and deduplicate these instances
efficiently. This makes NIF's symbol system not just a naming scheme, but a deduplication mechanism
that scales across a distributed, sharded architecture.

This naming scheme enables NIF's **index structure**, which maps symbols to byte offsets within a file.
The index is stored at the end of the file and uses diff-based encoding to keep it compact. The index
uses semantic tags ``x`` (for "eXported") and ``h`` (for "Hidden") to indicate symbol visibility:

```nif
(.nif26)
(.indexat +1234)
(stmts
  (proc :foo.0.mymodule ...)
  (var :bar.0.mymodule ...)
)
(.index
  (x foo.0.mymodule +12)
  (x bar.0.mymodule +23)
)
```

The ``.indexat`` directive specifies the byte offset where the index begins. The index entries use
diff-based offsets: the first entry is relative to the start of the file, and subsequent entries
are relative to the previous entry's absolute position. For example, ``foo.0.mymodule`` is at offset
``12``, and ``bar.0.mymodule`` is at offset ``12 + 23 == 35``. This makes the index compact while
still enabling **random access**: a tool can jump directly to the definition of ``foo.0.mymodule``
without parsing the entire file.

Only symbols with at least two dots (global symbols) appear in the index, as these are the top-level
entries that are interesting to jump to from outside the current module.

The combination of:
1. **Module-based symbol naming** (each file is a module with its own namespace)
2. **Index structure** (enabling random access to symbol definitions)
3. **Text-based format** (human-readable and diff-friendly)
4. **Binary-like efficiency** (via the index for fast lookups)

transforms NIF from a simple text format into a **text-binary-hybrid sharded database**. Each ``.nif``
file is a shard (module) in this database. Tools can:

- Quickly locate symbols across modules using the index
- Parse only the modules they need (lazy loading)
- Update individual modules without affecting others
- Maintain human-readable source while enabling efficient tooling

The module system provides natural boundaries for
sharding, while the index structure enables efficient cross-module navigation and lookup.


Line Information
================

One of the most practical features of NIF is how it handles source location information. Every node
can be annotated with its original source position (file, line, column) by prefixing it with line
information. This is done inline, directly in the syntax, with three simple forms:

1. ``<column-diff>`` - Column offset relative to the parent node
2. ``<column-diff, line-diff>`` - Both column and line offset relative to the parent
3. ``<column, line, filename>`` - Absolute position (only for the root node)

For example:

```nif
42,10,file.nim(stmts
  8(proc :foo.0
    2,1(params
      4(param x i32)
    )
  )
)
```

Here, the root node is at line 42, column 10 in ``file.nim``. The ``proc`` node is 8 columns to the
right of its parent. The ``params`` node is 2 columns right and 1 line down. Negative offsets use ``~``
instead of ``-`` (useful for infix operators where the left operand precedes the operator).

This simplicity makes NIF ideal for tools like debuggers, profilers, and error reporting systems that
need to map back to original source locations. The information is always there, always accessible,
and always in a human-readable format.

The value of provenance (source location information) extends far beyond programming languages. **HTTP**
would be better with it: knowing which line in a configuration file generated a particular header
would make debugging web server issues much easier. **HTML** would benefit: being able to trace a
rendered element back to its template source location would simplify development and debugging.
**Configuration files**, **data formats**, **protocol messages** — any structured data format would
be more debuggable and traceable if it carried provenance information.

NIF's inline approach makes this practical. Unlike source maps which are a complex add-on system,
NIF's line information is just part of the format itself. Any tool that processes NIF automatically
gets provenance for free, making it trivial to add source location tracking to any system that uses
NIF as its representation format. This universal applicability is another example of how NIF's simple,
integrated design provides powerful capabilities that would be difficult or impossible to retrofit
into existing formats.


Nimony
======

This technology — the combination of S-expressions, two namespaces, tag systems with ``.lang``,
symbol indexing, and inline provenance — is the foundation upon which the new [Nimony](https://github.com/nim-lang/nimony) compiler
is built. Nimony leverages NIF's elegant design to provide a modern, extensible compiler infrastructure
that benefits from all these advantages: human-readable intermediate representations, efficient
cross-module navigation, universal source location tracking, and the ability to mix different semantic
systems within a single compilation pipeline.

If you want to support us, please contribute to https://opencollective.com/nim!

**Stay tuned for a follow-up blog post about how NIF is implemented in Nim.**
