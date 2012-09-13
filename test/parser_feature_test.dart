/** Additional feature tests that aren't based on test data. */
#library('parser_test');

#import('dart:io');
#import('package:unittest/unittest.dart');
#import('package:unittest/vm_config.dart');
#import('package:html5lib/src/constants.dart');
#import('package:html5lib/src/treebuilder.dart');
#import('package:html5lib/dom.dart');
#import('package:html5lib/html5parser.dart');
#import('package:html5lib/tokenizer.dart');

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
    var builder = new TreeBuilder(true);
    var doc = new HTMLParser(builder).parse(new HTMLTokenizer(''));
    expect(doc.nodes[0].namespace, equals(Namespaces.html));
  });

  test('namespace html elements off', () {
    var builder = new TreeBuilder(false);
    var doc = new HTMLParser(builder).parse(new HTMLTokenizer(''));
    expect(doc.nodes[0].namespace, isNull);
  });

  test('parse error spans', () {
    var parser = new HTMLParser();
    var doc = parser.parse(new HTMLTokenizer('''
<!DOCTYPE html>
<html>
  <body>
  <!DOCTYPE html>
  </body>
</html>
'''));
    expect(doc.body.outerHTML, equals('<body>\n  \n  \n\n</body>'));
    expect(parser.errors.length, equals(1));
    ParseError error = parser.errors[0];
    expect(error.errorCode, equals('unexpected-doctype'));
    expect(error.span.line, equals(4));
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
}
