==================================
       Ormin
==================================

*2017-11-21*

This is the second part of "chat application" example. In the first part
we developed a single page application with Karax as the frontend for
out application. You can find it `here <https://nim-lang.org/araq/karax.html>`_

To create a backend server for our chat application we use
`Ormin <https://github.com/Araq/ormin>`_ which is a library for the construction
of SQL queries. It does so with the ``query`` macro:

.. code-block:: nim

  const maxMessages = 100

  let recentMessages = query:
    select messages(content, creation, author)
    orderby desc(creation)
    limit ?maxMessages


The DSL is deliberately close to SQL so that it's obvious what the produced
SQL will look like without nasty performance surprises. **Ormin typechecks
these queries and hence needs to know about the database model.**

Expressions starting with ``?`` are Nim expressions taken from the outside
scope. They produce the ``?`` placeholder in the resulting prepared statement.
Expressions starting with ``%`` are JSON expressions; Ormin uses JSON instead
of some ``value`` sum type that ends up being equivalent to Nim's ``JsonNode``
type and requires back and forth conversions everywhere.

The above query produces the following SQL code::

  select content, creation, author
  from messages
  order by creation desc
  limit ?


SQL is full of vendor specific functions or extensions in general. Ormin
only covers a common subset of SQL as well as a few builtin functions
like ``MIN``, ``MAX`` and ``COUNT``. In order to allow for vendor specific
functions the notation ``!!"sql code here"`` has to be used. The ``!!``
remind us that it is a dangerous feature as this part of the query is
not checked by Ormin:

.. code-block:: nim

    query:
      update users(lastOnline = !!"DATETIME('now')")
      where id == ?userId


..
  Another peculiar feature of Ormin is the so called "automatic join
  generation".

Ok, enough of these examples that nobody can compile. Let's continue
with our chat application to see a somewhat realistic example.


Database design
===============

We'll design the database model first. Ormin will generate the full
backend for us as well as some parts of the frontend. In fact, it can
generate a fullblown websocket based server for us via the ``protocol``
macro.


We'll use SQLite as the database. Our schema is:

.. code-block:: sql
   :file: ../ormin/examples/chat/chat_model.sql

Save this code as ``chat_model.sql``.

Interestingly, Ormin's DSL for generating SQL does not cover schema creations.
It is assumed that you need to interface to some existing database. Well, that
is not true for our example, so here is a short program that runs this script:

.. code-block:: nim
   :file: ../ormin/examples/chat/createdb.nim


To import the model we need the ``ormin_importer`` tool::

  nim c tools/ormin_importer

  tools/ormin_importer examples/chat/chat_model.sql

Ok, now let's write our backend code. Ormin supports generation of a WebSockets
based protocol. It generates a fullblown websocket based server for us via the
``protocol`` macro. Part of the generated protocol is the client-side code so it's
impossible to get the messaging infrastructure wrong.

.. code-block:: nim
   :file: ../ormin/examples/chat/server.nim

(This file can also be seen `here <https://github.com/Araq/ormin/blob/master/examples/chat/server.nim>`_.)

The protocol
supports ``recv``, ``broadcast`` and ``send`` as special "keywords". The protocol
always uses JSON. **Note that you do not have to use the protocol macro to take
advantage of Ormin.**

Every ``server`` section has to be paired with a ``client`` section that
describes what the frontend does in order to receive the message. The string argument
only aims for better readability, it is checked for consistency and otherwise ignored.
Proc declarations without a body are filled in by Ormin and define the entry
points that the frontend can call in order to make requests.

Admittedly, this ``protocol`` DSL is hard to wrap your head around.
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

  when not defined(js):
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

(This file can also be seen `here <https://github.com/Araq/ormin/blob/master/examples/chat/frontend.nim>`_.)

The changes are rather minimal:

1. We ``include`` the produced ``chatclient.nim``.

2. After initialization, we query the backend for the most recent messages:

.. code-block:: nim

  runLater proc() =
    getRecentMessages()

3. Implement a ``send`` operation for the generated include file:

.. code-block:: nim

  # here we setup the connection to the server:
  let conn = newWebSocket("ws://localhost:8080", "orminchat")

  proc send(msg: JsonNode) =
    # The Ormin "protocol" requires us to have 'send' implementation.
    conn.send(toJson(msg))


Conclusion
==========

The takeaway from all of this is that a single page application that
talks to a native database backed server via websockets fits in **under
200** lines of Nim code! The code is quite easy to read and modify; it
is typesafe and efficient. The power of an AST based macro system.
