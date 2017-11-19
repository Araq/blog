==================================
       Karax and Ormin
==================================


Karax
=====

*2017-11-15*

Karax is a relatively simple library which leverages Nim's JS backend to allow
the development of so called "single page applications" that run in the
browser. In this post I will explain how its DSL works under the hood.

Then we will have a look at "Ormin", a library for the construction of SQL
queries. And finally I will combine these two to create a simple chat
application.

To start, run these nimble commands::

  nimble install karax
  nimble install ormin


Hello World
===========

The simplest Karax program looks like this:

.. code-block:: nim
  include karax / prelude

  proc createDom(): VNode =
    result = buildHtml(tdiv):
      text "Hello World!"

  setRenderer createDom

(Save this as ``hello.nim``.)

Since ``div`` is a keyword in Nim, karax choose to use ``tdiv`` instead
here. ``tdiv`` produces a ``<div>`` virtual DOM node.

As you can see, karax comes with its own ``buildHtml`` DSL for convenient
construction of (virtual) DOM trees (of type ``VNode``). Karax provides
a tiny build tool that generates the HTML boilerplate code that
embeds and invokes the generated JavaScript code::

  nim c tools/karun
  tools/karun -r hello.nim

Via ``-d:debugKaraxDsl`` we can have a look at the produced Nim code by
``buildHtml``:

.. code-block:: nim

  let tmp1 = tree(VNodeKind.tdiv)
  add(tmp1, text "Hello World!")
  tmp1

(I shortened the IDs for better readability.)

Ok, so ``buildHtml`` introduces temporaries and calls ``add`` for the tree
construction so that it composes with all of Nim's control flow constructs:

.. code-block:: nim

  include karax / prelude
  import random

  proc createDom(): VNode =
    result = buildHtml(tdiv):
      if random(100) <= 50:
        text "Hello World!"
      else:
        text "Hello Universe"

  randomize()
  setRenderer createDom

Produces:

.. code-block:: nim

  let tmp1 = tree(VNodeKind.tdiv)
  if random(100) <= 50:
    add(tmp1, text "Hello World!")
  else:
    add(tmp1, text "Hello Universe")
  tmp1


DOM diffing
===========

Karax does not change the DOM's event model much, here is a program
that writes "Hello simulated universe" on a button click:


.. code-block:: nim

  include karax / prelude

  var lines: seq[cstring] = @[]

  proc createDom(): VNode =
    result = buildHtml(tdiv):
      button:
        text "Say hello!"
        proc onclick(ev: Event; n: VNode) =
          lines.add "Hello simulated universe"
      for x in lines:
        tdiv:
          text x

  setRenderer createDom

For efficiency Karax prefers Nim's ``cstring`` (which stands for "compatible
string"; for the JS target that is an immutable JavaScript string)
over ``string``.

Karax's DSL is quite flexible when it comes to event handlers, so the
following syntax is also supported:

.. code-block:: nim

  include karax / prelude
  from future import `=>`

  var lines: seq[cstring] = @[]

  proc createDom(): VNode =
    result = buildHtml(tdiv):
      button(onclick = () => lines.add "Hello simulated universe"):
        text "Say hello!"
      for x in lines:
        tdiv:
          text x

  setRenderer createDom

The ``buildHtml`` macro produces this code for us:

.. code-block:: nim

  let tmp2 = tree(VNodeKind.tdiv)
  let tmp3 = tree(VNodeKind.button)
  addEventHandler(tmp108023, EventKind.onclick,
                  () => lines.add "Hello simulated universe", kxi)
  add(tmp3, text "Say hello!")
  add(tmp2, tmp108023)
  for x in lines:
    let tmp4 = tree(VNodeKind.tdiv)
    add(tmp4, text x)
    add(tmp2, tmp4)
  tmp2

As the examples grow larger it becomes more and more visible of what
a DSL that composes with the builtin Nim control flow constructs buys us.
Once you have tasted this power there is no going back and languages
without AST based macro system simply don't cut it anymore.

Ok, so now we have seen DOM creation and event handlers. But how does
Karax actually keep the DOM up to date? The trick is that every event
handler is wrapped in a helper proc that triggers a *redraw* operation
that calls the *renderer* that you initially passed to ``setRenderer``.
So a new virtual DOM is created and compared against the previous
virtual DOM. This comparison produces a patch set that is then applied
to the real DOM the browser uses internally. This process is called
"virtual DOM diffing" and other frameworks, most notably Facebook's
*React*, do quite similar things. The virtual DOM is faster to create
and manipulate than the real DOM so this approach is quite efficient.


Ormin
=====

Ormin is a library for the construction of SQL queries. In fact, it
can generate a fullblown websocket based server for us via the
``protocol`` macro.

We'll design the database model first. Ormin will generate the full
backend for us as well as some parts of the frontend and so it makes
little sense to start with the frontend.

We'll use SQLite as the database. Our schema is:

.. code-block:: sql
   :file: ../ormin/examples/chat/chat_model.sql

Save this code as ``chat_model.sql``.

Interestingly, Ormin's DSL for generating SQL does not cover schema creations.
It is assumed that you need to interface to some existing database. Well, that
is not true for our example, so here is a short program that runs this script:

.. code-block:: nim
   :file: ../ormin/examples/chat/createdb.nim


Ormin type checks the SQL queries and so needs to know about the SQL model too.
To import the model we need the ``ormin_importer`` tool::

  nim c tools/ormin_importer

  tools/ormin_importer examples/chat/chat_model.sql

Ok, now let's write our backend code. Ormin supports generation of a WebSockets
based protocol. Part of the generated protocol is the client-side code so it's
impossible to get the messaging infrastructure wrong.

.. code-block:: nim
   :file: ../ormin/examples/chat/server.nim

Admittedly, this ``protocol`` DSL is hard to wrap your head around. The protocol
supports ``recv`` and ``send`` as special "keywords". The protocol always uses
JSON.

It helps to look at the produced code. We compile the server via::

  cd examples/chat
  nim c -d:debugOrminDsl server

The generated ``chatclient.nim`` contains:

.. code-block:: nim
   :file: ../ormin/examples/chat/chatclient.nim

The message dispatching is done via generated magic integer values. The responses
are the odd numbers 1, 3, 4, the requests the even numbers 0, 2, 4. Later versions
of Ormin might produce an ``enum`` instead to improve readability but since it's
generated code there is no chance of getting it wrong. We will later include this
file in our Karax-based frontend.

Thanks to the ``-d:debugOrminDsl`` switch the terminal showed us the server part
of the protocol implementation (simplified):


.. code-block:: nim

  when defined(js):
    type
      kstring = cstring
  else:
    type
      kstring = string
  type
    inet = kstring
    varchar = kstring
    timestamp = kstring
  proc dispatch(inp: JsonNode; receivers: var Receivers): JsonNode =
    let arg = inp["arg"]
    let cmd = inp["cmd"].getNum()
    case cmd
    of 0:
      let lastMessages =
        var :tmp449458 {.global.} = prepareStmt(db, "select m1.content, ...")
        var :tmp449459 = createJArray()
        block:
          startQuery(db, :tmp449458)
          while stepQuery(db, :tmp449458, 1):
            var :tmp449460 = createJObject()
            bindResultJson(db, :tmp449458, 0, :tmp449460, varchar, "content")
            bindResultJson(db, :tmp449458, 1, :tmp449460, timestamp, "creation")
            bindResultJson(db, :tmp449458, 2, :tmp449460, int, "author")
            bindResultJson(db, :tmp449458, 3, :tmp449460, varchar, "name")
            add :tmp449459, :tmp449460
          stopQuery(db, :tmp449458)
        :tmp449459
      result = newJObject()
      result["cmd"] = %1
      result["data"] = lastMessages
    of 2:
      ...
      let lastMessage =
        var :tmp449467 {.global.} = prepareStmt(db, "select m1.content, ...")
        var :tmp449468 = createJObject()
        block:
          startQuery(db, :tmp449467)
          if stepQuery(db, :tmp449467, 1):
            bindResultJson(db, :tmp449467, 0, :tmp449468, varchar, "content")
            bindResultJson(db, :tmp449467, 1, :tmp449468, timestamp, "creation")
            bindResultJson(db, :tmp449467, 2, :tmp449468, int, "author")
            bindResultJson(db, :tmp449467, 3, :tmp449468, varchar, "name")
            stopQuery(db, :tmp449467)
          else:
            stopQuery(db, :tmp449467)
            dbError(db)
        :tmp449468
      receivers = Receivers.all
      result = newJObject()
      result["cmd"] = %3
      result["data"] = lastMessage
    of 4:
      ...
    else:
      discard


Often it's more helpful to only look at the produced SQL queries. This
can be done via ``-d:debugOrminSql``::

  select m1.content, m1.creation, m1.author, u2.name
  from messages as m1
  inner join users as u2 on u2.id=m1.author
  order by m1.creation desc
  limit 100

  insert into messages(content, author)
  values (?, ?)

  update users set lastOnline = DATETIME('now')
  where id = ?

  select m1.content, m1.creation, m1.author, u2.name
  from messages as m1
  inner join users as u2 on u2.id=m1.author
  order by m1.creation desc
  limit 1

  select u1.id, u1.password
  from users as u1
  where u1.name = ?

  insert into users(name, password)
  values (?, ?)

  select u1.id
  from users as u1
  where u1.name = ? and u1.password = ?
  limit 1


Frontend
========

The frontend for our chat application looks like this:

.. code-block:: nim
   :file: ../ormin/examples/chat/frontend.nim

It uses the ``karax/errors`` module for error handling aka formular
input validation. We only check that the login username and password
are not empty. There is a lot more to say about these 100 lines of
code but this article is already too long. Study the code carefully.

The takeaway from all of this is that a single page application that
talks to a native SQLite backed server via websockets fits in under
200 lines of Nim code! The code is quite easy to read, modify; it
is typesafe and efficient. The power of an AST based macro system.
