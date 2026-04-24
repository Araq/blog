=====================================================
  Relays for Nimony's standard library
=====================================================


Relays for Nimony's standard library
====================================


*2026-04-23*


Parts of [Nimony](https://github.com/nim-lang/nimony)'s standard library will be based on what I call
*relays*. A relay is a global callback variable that stands for an
operation provided by the surrounding platform or runtime driver.

The name matters. "Hook" is close, but it suggests something optional
that you patch into an existing mechanism. This is not the idea here.
The relay *is* the mechanism. Portable code calls a normal procedure
like ``pollEvent()`` or ``drawText()``; internally that procedure
forwards to a global proc variable that the driver assigns at startup.

The new [uirelays](https://github.com/nim-lang/uirelays) package uses this
design to provide a native UI library with WinAPI, Cocoa, X11, GTK4, SDL2
and SDL3 backends -- all selectable at compile time. Application code stays
the same across all of them.


The pattern
===========

The basic pattern is tiny:

.. code-block:: Nim
  # timing.nim

  var getTicksRelay*: proc (): int {.nimcall.} =
    proc (): int = 0

  var sleepRelay*: proc (ms: int) {.nimcall.} =
    proc (ms: int) = discard

  proc getTicks*(): int = getTicksRelay()
  proc sleep*(ms: int) = sleepRelay(ms)

The rest of the program calls ``getTicks`` and ``sleep``.
A platform-specific driver assigns the relays:

.. code-block:: Nim

  # sdl3_driver.nim

  proc initSdl3Driver*() =
    getTicksRelay = proc (): int = sdl3.getTicks().int
    sleepRelay = proc (ms: int) = sdl3.delay(ms.uint32)

And then the application's main module performs the binding:

.. code-block:: Nim

  import timing
  import sdl3_driver

  initSdl3Driver()
  mainLoop()

This is simple dependency injection, but with a very concrete rule:
the injected operations are exported global proc variables and they are
set explicitly by a driver near program startup.


Why use relays?
===============

The standard library has two very different parts.

One part is pure language infrastructure: strings, tables, algorithms,
parsers, formatting, containers, and so on. These
should not depend on any external runtime service other than what the
language guarantees.

The other part touches the outside world: clocks, event loops, window
creation, clipboard access, drawing, process management, perhaps parts
of file or network integration. These operations are inherently
backend-specific. On one target they go through SDL, on another through
Win32, Cocoa, JavaScript, a tiny embedded board support package, or a
hosted test shim.

Relays let the portable API stay small and direct:

- the portable module defines the types and the wrapper procs;
- the driver provides the implementation;
- the main module chooses the driver.

No object hierarchy is required. No hidden registration table is
required. No linker magic is required. No compiler special case is
required.

In ``uirelays`` this splits into five relay groups, each in its own
module:

=============  ===================  ====================================
Module         Relays               Purpose
=============  ===================  ====================================
``screen``     ``windowRelays``     Window lifecycle, cursor, clip rect
``screen``     ``fontRelays``       Font loading, measurement, rendering
``screen``     ``drawRelays``       Rectangles, lines, points, images
``input``      ``inputRelays``      Events, timing, shutdown
``input``      ``clipboardRelays``  Copy/paste
=============  ===================  ====================================

Six drivers populate these relays:

==================  ================  ====================================
Driver              Platform          Dependencies
==================  ================  ====================================
``winapi_driver``   Windows           None (GDI)
``cocoa_driver``    macOS             None (AppKit)
``x11_driver``      Linux/BSD         libX11, libXft
``gtk4_driver``     Linux/BSD         GTK4, Cairo, Pango
``sdl3_driver``     Cross-platform    SDL3, SDL3_ttf
``sdl2_driver``     Cross-platform    SDL2, SDL2_ttf
==================  ================  ====================================

The native platform drivers (WinAPI, Cocoa, X11) need zero external
dependencies. The SDL and GTK4 drivers exist for portability or when
those toolkits are already in use.


Drivers and adapters
====================

Apart from drivers, I also expect *adapter* modules to be useful.

A driver is the component that provides the real implementation for a
relay. An adapter is a component that sits on top of an existing relay
and transforms or augments its behavior. It does not own the boundary;
it wraps it.

Logging is the simplest example. Suppose the main module already called
``initSdl3Driver()``, so ``pollEventRelay`` now points to the SDL-backed
implementation. An adapter can capture that current relay, install a new
one, and forward to the original:

.. code-block:: Nim

  var previousPollEvent: proc (e: var Event): bool {.nimcall.}

  proc loggingPollEvent(e: var Event): bool =
    result = previousPollEvent(e)
    if result:
      echo "event kind: ", e.kind

  proc installEventLoggingAdapter*() =
    previousPollEvent = pollEventRelay
    pollEventRelay = loggingPollEvent

Then the main module can say:

.. code-block:: Nim

  initSdl3Driver()
  installEventLoggingAdapter()
  mainLoop()

The installation order matters: the driver goes first, the adapter goes
afterwards. Otherwise the adapter would only wrap the default no-op
implementation.

This can be generalized. An adapter could log arguments and return
values, measure execution time, translate data formats, filter calls, or
enforce invariants before forwarding to the previous relay. In that
sense, drivers *provide* relays while adapters *decorate* relays.


Why not objects, methods, or interfaces?
========================================

For some problems they are the right tool. For this one they are often
worse.

An OO interface would force the program to manufacture a driver object,
store it somewhere, and pass it around or hide it in a singleton. But
the operations we want are already procedures: ``pollEvent``,
``drawText``, ``getClipboardText``, ``sleep``. Turning them into methods
adds indirection in the source model, not clarity.

Relays preserve the natural shape of the API. Call sites still look
like ordinary standard library calls:

.. code-block:: Nim

  if pollEvent(ev):
    handle(ev)
  refresh()

That is the real win. The users of the API do not care which backend is
active; they care that the operation exists.


Relays and replays
==================

Relays also make testing easier. A test can install a tiny fake driver:

.. code-block:: Nim

  proc fakePollEvent(e: var Event): bool =
    e.kind = evQuit
    result = true

  pollEventRelay = fakePollEvent

Then the test exercises the portable code without SDL, without a real
window, without platform setup. For standard library code this is a
significant advantage: the boundary stays narrow and mockable.

For richer tests, the same idea scales to *queue logging and replay*.
This maps naturally to ``uirelays/input.nim`` where event input goes
through ``inputRelays.pollEvent``.

The adapter pattern is:

- capture the current ``inputRelays.pollEvent`` as ``previousPollEvent``;
- install a logging wrapper that forwards to the previous relay and stores
  returned events into a queue;
- later, replace ``inputRelays.pollEvent`` with a replay proc that drains
  the recorded queue instead of asking the backend.

In practice:

.. code-block:: Nim

  import uirelays/input

  var previousPollEvent: proc (e: var Event; flags: set[InputFlag]): bool {.nimcall.}
  var recordedEvents: seq[Event]
  var replayPos = 0

  proc loggingPollEvent(e: var Event; flags: set[InputFlag]): bool =
    result = previousPollEvent(e, flags)
    if result:
      recordedEvents.add e

  proc installEventLogger*() =
    previousPollEvent = inputRelays.pollEvent
    inputRelays.pollEvent = loggingPollEvent

  proc replayPollEvent(e: var Event; flags: set[InputFlag]): bool =
    if replayPos < recordedEvents.len:
      e = recordedEvents[replayPos]
      inc replayPos
      result = true
    else:
      result = false

  proc startReplay*() =
    replayPos = 0
    inputRelays.pollEvent = replayPollEvent

This gives deterministic UI tests:

1. run once against a real backend and record events;
2. run many times in replay mode and assert behavior;
3. compare rendered state, widget trees, or command output.

The useful part is that nothing above ``pollEvent`` needs to know whether
events are live or replayed. All that changes is one relay assignment.

For this to work well long-term, ``Event`` should be a *closed* and
serialization-friendly type: no backend-owned pointers, no hidden
resources, no open class hierarchy with unknown payload shapes. Otherwise
recorded traces become fragile or non-portable.

``uirelays/input.nim`` already follows this rule. ``Event`` is a plain
object built from enums, sets, integers, and a fixed-size UTF-8 char
array. That is exactly what replay needs: the value can be copied, queued,
written to disk, read back, and compared deterministically.

The same principle applies to output. Screen operations should also be
captured as a closed stream of serializable actions (``fillRect``,
``drawText``, ``drawLine``, ``setCursor``, ... plus value-type arguments
like ``Rect``, ``Color``, ``TextExtent``). In ``uirelays/screen.nim`` the
API is already close to this shape: calls use mostly plain values and
opaque integer handles (``Font``/``Image``) instead of backend pointers.

That means CI can validate both sides:

1. record input events and replay them;
2. record emitted screen actions and compare them to a golden trace.

So tests become full log-and-replay checks of the UI contract: same input
trace in, same output action trace out.

With this style, you can also insert normalizations while logging
(coalesce mouse-move bursts, strip timing jitter, remap platform-specific
keys) so replay traces remain small and stable across machines.


Relays for memory and file I/O
==============================

The same relay idea applies below the UI stack, in memory management.
If the allocator boundary is expressed as relays like ``allocPages`` and
``deallocPages``, the memory manager can be tested against instrumented
backends without changing its core logic.

That gives two immediate benefits:

1. leak detection becomes straightforward: a tracking backend records every
   page allocation and free, then reports unmatched allocations at shutdown;
2. OOM resilience testing becomes deterministic: a fixed-size heap backend
   refuses allocations after a configured page budget, so code paths for
   allocation failure are exercised in CI on every run.

In other words, page allocation relays turn "hard to reproduce in
production" memory failures into normal, scriptable test scenarios.

File I/O is another useful relay boundary. Even a basic ``open`` call can
be routed through a relay so plugin execution uses a restricted file policy
instead of raw host access.

For Nimony plugins, a sandbox override for ``open`` can enforce a simple
allow-list:

- paths under the current project directory;
- paths under ``nimcache/``.

Everything else is rejected. This is only a mild protection model, but it
still prevents plugins from casually reading arbitrary disk contents
outside the intended workspace.

The design benefit is the same as everywhere else in this article: policy
changes are done by swapping a relay implementation, while the portable
API surface stays stable.


uirelays today
==============

[uirelays](https://github.com/nim-lang/uirelays) is available now and
works with Nim 2. Nimony is not yet ready to compile it, but nothing in
the design requires new or complex language features -- proc variables,
objects, and modules are all it takes. When Nimony is ready, the code
will carry over unchanged.

As a user of the library you do not need to think about relays at all.
You ``import uirelays``, call ``createWindow``, ``drawText``,
``fillRect``, ``pollEvent`` and friends, and the right backend is
selected automatically for your platform. The relay machinery is an
implementation detail that stays out of your way.

Nimony's standard library will use the same idea for the parts
that sit at the boundary between portable code and the outside world.
Here in particular the ``allocPages/deallocPages`` relays will be
useful for embedded devices and hardening against memory constraints.
