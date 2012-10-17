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
```yaml
dependencies:
  html5lib: any
```
Then run the [Pub Package Manager][pub] (comes with the Dart SDK):

    pub install

Usage
-----

Parsing HTML is easy!
```dart
import 'package:html5lib/parser.dart'; // show parse
import 'package:html5lib/dom.dart';

main() {
  var document = parse(
      '<body>Hello world! <a href="www.html5rocks.com">HTML5 rocks!');
  print(document.outerHTML);
}
```

You can pass a String or list of bytes to `parse`.
There's also `parseFragment` for parsing a document fragment, and `HtmlParser`
if you want more low level control.


Updating
--------

You can upgrade the library with:

    pub update

Disclaimer: the APIs are not finished. Updating may break your code. If that
happens, you can check the
[commit log](https://github.com/dart-lang/html5lib/commits/master), to figure
out what the change was.

If you want to avoid breakage, you can also put the version constraint in your
`pubspec.yaml` in place of the word `any`.


Implementation Status
---------------------

Right now the tokenizer, html5parser, and simpletree are working.

These files from the [html5lib directory][files] still need to be ported:

* `ihatexml.py`
* `sanitizer.py`
* `filters/*`
* `serializer/*`
* some of `treebuilders/*`
* `treewalkers/*`
* the `tests` corresponding to the above files


Running Tests
-------------

All tests should be passing.
```bash
# Make sure dependencies are installed
pub install

# Run command line tests
#export DART_SDK=path/to/dart/sdk
test/run.sh
```

[dart]: http://www.dartlang.org/
[html5parse]: http://dev.w3.org/html5/spec/parsing.html
[d_html]: http://api.dartlang.org/docs/continuous/dart_html.html
[files]: http://html5lib.googlecode.com/hg/python/html5lib/
[pub]: http://www.dartlang.org/docs/pub-package-manager/
