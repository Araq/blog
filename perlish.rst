==================================
  Perl and Nim
==================================


Perl and Nim
============

**Warning: The information presented here is severely outdated.**

*2016-10-02*

**Disclaimer**: If you like to skim over things, don't miss the end!

Last month I tried to reimplement Perl in Nim and to see how well Nim's macro
system holds up for unusual domain specific language requests. Personally I do
not like Perl at all, but for a language designer it does "interesting" things.
The feature I was mostly interested in is Perl's ``$_`` magical context
variable. So let's see how it works (from `<http://perldoc.perl.org/perlvar.html>`_):


.. container:: manual

  ``$_``

    The default input and pattern-searching space. The following pairs are
    equivalent::

      while (<>) {...}    # equivalent only in while!
      while (defined($_ = <>)) {...}

      /^Subject:/
      $_ =~ /^Subject:/

      tr/a-z/A-Z/
      $_ =~ tr/a-z/A-Z/

      chomp
      chomp($_)

There are other places where ``$_`` is implicitly assumed in Perl, but the above
paragraph captures what I'm interested in.

Here is a Perl script that computes the average of each column in a table of
data. Only lines that look like they contain a list of numbers are dealt with:

.. code-block:: C
    :number-lines:

  #!/usr/local/bin/perl

  $count = 0;
  while (<stdin>) {
    if(/(\d+\s*)+/) {
      @w = split;
      $count++;
      for ($i=0; $i<=$#w; $i++) {
        $s[$i] += $w[$i];
      }
    }
  }
  for ($i=0; $i<=$#w; $i++) {
    print $s[$i]/$count, "\t";
  }
  print "\n";

Lines 4-6 make use of this magical hidden ``$_`` variable, so it really means:

.. code-block:: C
    while (defined($_ = <>)) {
      if($_ ~= /(\d+\s*)+/) {
        @w = split($_);
        ...
      }
    }


Let's rewrite this script as a Nim program that approaches the
terseness and somehow models Perl's ``$_``.

The first solution that crossed my mind is to create a ``perlish`` macro.
``perlish`` takes a proc written in some Perl inspired Nim style and rewrites
the proc to full Nim:

.. code-block:: nim
  macro perlish(x: untyped): untyped =
    # implementation left as an exercise for the reader
    ...

  proc ensureLen[T](s: var seq[T]; len: int) =
    ## helper to mimic Perl's array accesses.
    if len > s.len: setLen(s, len)

  proc p {.perlish.} =
    var count = 0
    var s = newSeq[int]()
    while stdin:
      if re"(\d+\s*)+":
        let w = split
        inc count
        for i in 0..w.high:
          ensureLen s, i+1
          s[i] += parseInt(w[i])
    for x in s:
      print x / count, "\t"
    print "\n"

So for our example program this ``perlish`` macro would transform the
``while stdin``,  ``if re"x"``, ``split`` (without parenthesis), ``print``
snippets to something like:

.. code-block:: nim
  proc p =
    var count = 0
    var s = newSeq[int]()
    for it in lines(stdin):
      if it =~ re"(\d+\s*)+":
        let w = splitWhitespace(it)
        inc count
        for i in 0..w.high:
          ensureLen s, i+1
          s[i] += parseInt(w[i])
    for x in s:
      stdout.write x / count, "\t"
    stdout.write "\n"

Alright, this would work, but it's a pointless hack really: You don't know
which "Perl inspired" features are supported by ``perlish``, nor does it save
that much typing (Nim is concise out of the box!). And we haven't even written
the ``perlish`` macro yet...

Let's step back a bit: What does ``$_`` do? It is used in contexts if no
explicit argument is given or if too few arguments are given. In other words
calls like ``f()`` are rewritten to ``f(it)`` and calls with arguments
``f(args)`` are rewritten to ``f(it, args)`` **if** it cannot be interpreted
otherwise. This smells like Nim's overloading feature. And indeed, it turns out,
Nim does not only support the required overloading of procs like ``split`` and
``=~``, it has exactly this rewrite rule builtin! It's tied to a ``this``
parameter though.

As its name implies, Nim's ``this`` feature was inspired by OO languages but
internally works quite differently because Nim strives to overcome classic OOP
and to provide more power by not tying things to classes. The
`manual <http://nim-lang.org/docs/manual.html#overloading-resolution-automatic-self-insertions>`_
has a nice explanation of how Nim's ``this`` feature works:


.. container:: manual

  Starting with version 0.14 of the language, Nim supports ``field`` as a
  shortcut for ``self.field`` comparable to the ``this`` keyword in Java or C++.
  This feature has to be explicitly enabled via a ``{.this: self.}`` statement
  pragma. This pragma is active for the rest of the module:

  .. code-block:: nim

    type
      Parent = object of RootObj
        parentField: int
      Child = object of Parent
        childField: int

    {.this: self.}
    proc sumFields(self: Child): int =
      result = parentField + childField
      # is rewritten to:
      # result = self.parentField + self.childField

  Instead of ``self`` any other identifier can be used too, but ``{.this: self.}``
  will become the default directive for the whole language eventually.

  In addition to fields, routine applications are also rewritten, but only if no
  other interpretation of the call is possible:

  .. code-block:: nim

    proc test(self: Child) =
      echo childField, " ", sumFields()
      # is rewritten to:
      echo self.childField, " ", sumFields(self)
      # but NOT rewritten to:
      echo self, self.childField, " ", sumFields(self)


OK, this is useful and we can choose to name it ``it`` instead of ``self``,
but we still need to introduce an ``it`` parameter
somehow. We wrap this in a template:

.. code-block:: nim

  template perlish(body: untyped) {.dirty.} =
    {.this: it.}
    block:
      proc main(it: var string) =
        body

      var buffer = newStringOfCap(80)
      main buffer

We need another helper to deal with the ``while stdin`` idiom, but instead of
introducing ``while_stdin``, we'll support ``while readLine()`` which is not
much longer, but more readable:

.. code-block:: nim
  template readLine(it): untyped = stdin.readLine(it)

And we need ``print`` since Nim only has ``echo`` which always produces a
newline (bah!):

.. code-block:: nim

  proc print(args: varargs[string, `$`]) =
    for x in args: stdout.write x

Now let's see in action:

.. code-block:: nim
  perlish:
    var count = 0
    var s = newSeq[int]()
    while readLine():
      if =~ re"(\d+\s*)+":
        let w = splitWhitespace()
        inc count
        for i in 0..w.high:
          ensureLen s, i+1
          s[i] += parseInt(w[i])
    for x in s:
      print x / count, "\t"
    print "\n"

Note that the ``re`` module comes with an ``=~`` operator which is actually a
binary operator. Thanks to Nim's ``this`` rewrite rule, we can also use it
as an unary operator here! There is no need to wrap an arbitrary list of
"builtin" operations to support our ``it`` feature.

Now there is another thing that is not convenient for Perl-like scripting: The
need for the explicit string to integer conversion via ``parseInt``. We can
write a converter to deal with this issue:

.. code-block:: nim
  converter toInt(x: string): int = parseInt(x)

All that is left to do is to clean things up a bit and distinguish
between example code and library code.


Library code
============

.. code-block:: nim
   :file: perlish.nim


Example code
============

.. code-block:: nim
   :file: perlex.nim


Conclusion
==========

Now what's the point in all of this? Good question. It shows a bit of my
philosophy as a language designer. Yes, Nim's features can be used in
interesting and confusing ways resulting in bad code, but as a language designer
I don't come up with arbitrary restrictions to prevent bad things since it would
make the language more complex and not help much: Real bad code comes from bad
design, not from the desire to save a few keystrokes.


Happy hacking!
