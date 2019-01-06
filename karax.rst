==================================
       Araq's Musings
==================================


Karax
=====

*2017-11-20*

`Karax <https://github.com/pragmagic/karax>`_ is a relatively simple library
which leverages Nim's JS backend to allow the development of so called
"single page applications" that run in the browser. In this blog post I will
explain how its DSL works under the hood.

In a following blog post we will have a look at
`Ormin <https://github.com/Araq/ormin>`_, a library for the
construction of SQL queries and websocket based servers. We will then combine
Karax and Ormin to create a simple, yet fully functional chat application.

To start, run this::

  nimble install karax

Unfortunately the nimble package does not install the examples to tinker
with; ``git clone`` is an alternative::

  git clone https://github.com/pragmagic/karax.git
  cd karax
  nimble develop


Hello World
===========

The simplest Karax program looks like this:

.. code-block:: nim
   :file: ../karax/examples/helloworld.nim

(Full example `here <https://github.com/pragmagic/karax/blob/master/examples/helloworld.nim>`_.)

Since ``div`` is a keyword in Nim, karax choose to use ``tdiv`` instead
here. ``tdiv`` produces a ``<div>`` virtual DOM node.

As you can see, karax comes with its own ``buildHtml`` DSL for convenient
construction of (virtual) DOM trees (of type ``VNode``). Karax provides
a tiny build tool called ``karun`` that generates the HTML boilerplate code that
embeds and invokes the generated JavaScript code::

  nim c tools/karun
  tools/karun -r helloworld.nim

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
   :file: ../karax/examples/hellouniverse.nim

Produces:

.. code-block:: nim

  let tmp1 = tree(VNodeKind.tdiv)
  if random(100) <= 50:
    add(tmp1, text "Hello World!")
  else:
    add(tmp1, text "Hello Universe")
  tmp1


Event model
===========

Karax does not change the DOM's event model much, here is a program
that writes "Hello simulated universe" on a button click:

.. code-block:: nim
   :file: ../karax/examples/button.nim

(Full example `here <https://github.com/pragmagic/karax/blob/master/examples/button.nim>`_.)


``kstring`` is Karax's alias for ``cstring`` (which stands for "compatible
string"; for the JS target that is an immutable JavaScript string) which
is preferred for efficiency on the JS target. However, on the native targets
``kstring`` is mapped  to ``string`` for efficiency. The DSL for HTML
construction is also avaible for the native targets (!) and the ``kstring``
abstraction helps to deal with these conflicting requirements.

Karax's DSL is quite flexible when it comes to event handlers, so the
following syntax is also supported:

.. code-block:: nim
   :file: ../karax/examples/buttonlambda.nim

(Full example `here <https://github.com/pragmagic/karax/blob/master/examples/buttonlambda.nim>`_.)


The ``buildHtml`` macro produces this code for us:

.. code-block:: nim

  let tmp2 = tree(VNodeKind.tdiv)
  let tmp3 = tree(VNodeKind.button)
  addEventHandler(tmp3, EventKind.onclick,
                  () => lines.add "Hello simulated universe", kxi)
  add(tmp3, text "Say hello!")
  add(tmp2, tmp3)
  for x in lines:
    let tmp4 = tree(VNodeKind.tdiv)
    add(tmp4, text x)
    add(tmp2, tmp4)
  tmp2

As the examples grow larger it becomes more and more visible of what
a DSL that composes with the builtin Nim control flow constructs buys us.
Once you have tasted this power there is no going back and languages
without AST based macro system simply don't cut it anymore.


DOM diffing
===========

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

Karax also offers "reactive" extensions that use a dynamic dependency
graph to compute the minimal set of state updates. However, these are
harder to use and in practice these constant virtual DOM recreations
are more than fast enough.


Form validation
===============

The chat application we're writing should have a simple "login"
mechanism consisting of ``username`` and ``password`` and
a ``login`` button. The login button should only be clickable
if ``username`` and ``password`` are not empty. An error
message should be shown as long as one input field is empty.

To create new UI elements we write a ``loginField`` proc that
returns a ``VNode``:

.. code-block:: nim

  proc loginField(desc, field, class: kstring;
                  validator: proc (field: kstring): proc ()): VNode =
    result = buildHtml(tdiv):
      label(`for` = field):
        text desc
      input(class = class, id = field, onchange = validator(field))

We use the ``karax / errors`` module to help with this error
logic. The ``errors`` module is mostly a mapping from strings to
strings but it turned out that the logic is tricky enough to warrant
a library solution. ``validateNotEmpty`` returns a closure that
captures the ``field`` parameter:

.. code-block:: nim

  proc validateNotEmpty(field: kstring): proc () =
    result = proc () =
      let x = getVNodeById(field)
      if x.text.isNil or x.text == "":
        errors.setError(field, field & " must not be empty")
      else:
        errors.setError(field, "")

This indirection is required because
event handlers in Karax need to have the type ``proc ()``
or ``proc (ev: Event; n: VNode)``. The errors module also
gives us a handy ``disableOnError`` helper. It returns
``"disabled"`` if there are errors. Now we have all the
pieces together to write our login dialog:


.. code-block:: nim

  # some consts in order to prevent typos:
  const
    username = kstring"username"
    password = kstring"password"

  var loggedIn: bool

  proc loginDialog(): VNode =
    result = buildHtml(tdiv):
      if not loggedIn:
        loginField("Name :", username, "input", validateNotEmpty)
        loginField("Password: ", password, "password", validateNotEmpty)
        button(onclick = () => (loggedIn = true), disabled = errors.disableOnError()):
          text "Login"
        p:
          text errors.getError(username)
        p:
          text errors.getError(password)
      else:
        p:
          text "You are now logged in."

  setRenderer loginDialog

(Full example `here <https://github.com/pragmagic/karax/blob/master/examples/login.nim>`_.)

This code still has a bug though, when you run it, the ``login`` button is not
disabled until some input fields are validated! This is easily fixed,
at initialization we have to do:

.. code-block:: nim
  setError username, username & " must not be empty"
  setError password, password & " must not be empty"

There are likely more elegant solutions to this problem.


Chat frontend
=============

Once logged in, we are allowed to send new messages, the code for this is
straight-forward:

.. code-block:: nim

  const
    message = "message"

  type
    TextMessage = ref object
      name, content: kstring

  var allMessages: seq[Message] = @[]

  proc doSendMessage() =
    let inputField = getVNodeById(message)
    allMessages.add(TextMessage(name: "you", content: inputField.text))
    inputField.setInputText ""

  proc main(): VNode =
    result = buildHtml(tdiv):
      loginDialog()
      tdiv:
        table:
          for m in allMessages:
            tr:
              td:
                bold:
                  text m.name
              td:
                text m.content
      tdiv:
        if loggedIn:
          label(`for` = message):
            text "Message: "
          input(class = "input", id = message, onkeyupenter = doSendMessage)

(Full example `here <https://github.com/pragmagic/karax/blob/master/examples/toychat.nim>`_.)

Without a server that takes our written messages and tells us what other users wrote
this is a rather limited example though. In the next post I'll talk about how
Ormin can give us a websockets based backend server. Karax and Ormin are a
powerful combination for application development, stay tuned!
