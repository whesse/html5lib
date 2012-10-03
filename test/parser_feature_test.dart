/** Additional feature tests that aren't based on test data. */
library parser_test;

import 'dart:io';
import 'package:unittest/unittest.dart';
import 'package:unittest/vm_config.dart';
import 'package:html5lib/dom.dart';
import 'package:html5lib/parser.dart';
import 'package:html5lib/src/constants.dart';
import 'package:html5lib/src/tokenizer.dart';
import 'package:html5lib/src/treebuilder.dart';

main() {
  useVmConfiguration();

  test('doctype is cloneable', () {
    var doc = parse('<!DOCTYPE HTML>');
    DocumentType doctype = doc.nodes[0];
    expect(doctype.clone().outerHTML, equals('<!DOCTYPE html>'));
  });

  test('line counter', () {
    // http://groups.google.com/group/html5lib-discuss/browse_frm/thread/f4f00e4a2f26d5c0
    var doc = parse("<pre>\nx\n&gt;\n</pre>");
    expect(doc.body.innerHTML, equals("<pre>x\n&gt;\n</pre>"));
  });

  test('namespace html elements on', () {
    var doc = new HtmlParser('', tree: new TreeBuilder(true)).parse();
    expect(doc.nodes[0].namespace, equals(Namespaces.html));
  });

  test('namespace html elements off', () {
    var doc = new HtmlParser('', tree: new TreeBuilder(false)).parse();
    expect(doc.nodes[0].namespace, isNull);
  });

  test('parse error spans - full', () {
    var parser = new HtmlParser('''
<!DOCTYPE html>
<html>
  <body>
  <!DOCTYPE html>
  </body>
</html>
''', generateSpans: true);
    var doc = parser.parse();
    expect(doc.body.outerHTML, equals('<body>\n  \n  \n\n</body>'));
    expect(parser.errors.length, equals(1));
    ParseError error = parser.errors[0];
    expect(error.errorCode, equals('unexpected-doctype'));

    // Note: these values are 0-based, but the printed format is 1-based.
    expect(error.span.line, equals(3));
    expect(error.span.endLine, equals(3));
    expect(error.span.column, equals(2));
    expect(error.span.endColumn, equals(17));
    expect(error.span.sourceText, equals('<!DOCTYPE html>'));

    expect(error.toString(), equals('''
ParseError:4:3: Unexpected DOCTYPE. Ignored.
  <!DOCTYPE html>
  ^^^^^^^^^^^^^^^'''));
  });

  test('parse error spans - minimal', () {
    var parser = new HtmlParser('''
<!DOCTYPE html>
<html>
  <body>
  <!DOCTYPE html>
  </body>
</html>
''');
    var doc = parser.parse();
    expect(doc.body.outerHTML, equals('<body>\n  \n  \n\n</body>'));
    expect(parser.errors.length, equals(1));
    ParseError error = parser.errors[0];
    expect(error.errorCode, equals('unexpected-doctype'));
    expect(error.span.line, equals(3));
    // Note: error position is at the end, not the beginning
    expect(error.span.column, equals(17));
  });

  test('void element innerHTML', () {
    var doc = parse('<div></div>');
    expect(doc.body.innerHTML, '<div></div>');
    doc = parse('<body><script></script></body>');
    expect(doc.body.innerHTML, '<script></script>');
    doc = parse('<br>');
    expect(doc.body.innerHTML, '<br>');
    doc = parse('<br><foo><bar>');
    expect(doc.body.innerHTML, '<br><foo><bar></bar></foo>');
  });

  test('empty document has html, body, and head', () {
    var doc = parse('');
    expect(doc.outerHTML, equals('<html><head></head><body></body></html>'));
    expect(doc.head.outerHTML, equals('<head></head>'));
    expect(doc.body.outerHTML, equals('<body></body>'));
  });

  test('strange table case', () {
    var doc = parseFragment('<table><tbody><foo>');
    expect(doc.outerHTML, equals('<foo></foo><table><tbody></tbody></table>'));
  });
}
