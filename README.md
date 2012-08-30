html5lib in Pure Dart
=====================

This is a pure [Dart][dart] [html5 parser][html5parse]. It's a port of
[html5lib](http://code.google.com/p/html5lib/) from Python. Since it's 100%
Dart you can use it safely from a script or server side app.

Eventually the parse tree API will be compatible with [dart:html][d_html], so
the same code will work on the client or the server.

Installation
------------

Add this to your `pubspec.yaml` (or create it):

    dependencies:
      html5lib:
        git: https://github.com/dart-lang/html5lib.git

Then run the [Pub Package Manager][pub] (comes with the Dart SDK):

    pub install

Usage
-----

Parsing HTML is easy!

    #import('package:html5lib/html5parser.dart', prefix: 'html5parser');

    main() {
      var document = html5parser.parse(
        '<body>Hello world! <a href="www.html5rocks.com">HTML5 rocks!');
      print(document.outerHTML);
    }

You can pass a String, [RandomAccessFile][file], or list of bytes to `parse`.
There's also `parseFragment` for parsing a document fragment, and `HTMLParser`
if you want more low level control. Finally, you can get the simple DOM tree
types like this:

    #import('package:html5lib/treebuilders/simpletree.dart');


Updating
--------

You can upgrade the library with:

    pub update

Disclaimer: the APIs are not finished. Updating may break your code. If that
happens, you can check the
[commit log](https://github.com/dart-lang/html5lib/commits/master), to figure
out what the change was.


Implementation Status
---------------------

Right now the tokenizer, html5parser, and simpletree are working.

These files from the [html5lib directory][files] still need to be ported:

* `ihatexml.py`
* `sanitizer.py`
* `filters/*`
* `serializer/*`
* most of `treebuilders/*`
* `treewalkers/*`
* most of `tests`


Running Tests
-------------

All tests should be passing.

    # Make sure dependencies are installed
    pub install

    # Run command line tests
    #export DART_SDK=path/to/dart/sdk
    tests/run.sh


[dart]: http://www.dartlang.org/
[html5parse]: http://dev.w3.org/html5/spec/parsing.html
[d_html]: http://api.dartlang.org/docs/continuous/dart_html.html
[files]: http://html5lib.googlecode.com/hg/python/html5lib/
[pub]: http://www.dartlang.org/docs/pub-package-manager/
[file]: http://api.dartlang.org/docs/continuous/dart_io/RandomAccessFile.html

