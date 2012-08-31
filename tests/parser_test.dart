#library('parser_test');

#import('dart:io');
#import('package:unittest/unittest.dart');
#import('../lib/constants.dart');
#import('../lib/utils.dart');
#import('../treebuilders/simpletree.dart');
#import('../html5parser.dart');
#import('../tokenizer.dart');
#import('support.dart');

// Run the parse error checks
// TODO(jmesserly): presumably we want this on by default?
final checkParseErrors = false;

String namespaceHtml(String expected) {
  // TODO(jmesserly): this is a workaround for http://dartbug.com/2979
  // We can't do regex replace directly =\
  // final namespaceExpected = const RegExp(@"^(\s*)<(\S+)>", multiLine: true);
  // return expected.replaceAll(namespaceExpected, @"$1<html $2>");
  final namespaceExpected = const RegExp(@"^(\|\s*)<(\S+)>");
  var lines =  expected.split("\n");
  for (int i = 0; i < lines.length; i++) {
    var match = namespaceExpected.firstMatch(lines[i]);
    if (match != null) {
      lines[i] = "${match[1]}<html ${match[2]}>";
    }
  }
  return Strings.join(lines, "\n");
}

void runParserTest(String groupName, String innerHTML, String input,
    String expected, List errors, TreeBuilderFactory treeCtor,
    bool namespaceHTMLElements) {

  // XXX - move this out into the setup function
  // concatenate all consecutive character tokens into a single token
  var builder = treeCtor(namespaceHTMLElements);
  HTMLParser p;
  try {
    p = new HTMLParser(builder);
  } on DataLossWarning catch (w) {
    return;
  }

  var document;
  try {
    var tokenizer = new HTMLTokenizer(input);
    if (innerHTML != null) {
      document = p.parseFragment(tokenizer, container_: innerHTML);
    } else {
      try {
        document = p.parse(tokenizer);
      } on DataLossWarning catch (w) {
        return;
      }
    }
  } catch (e, stack) {
    // TODO(jmesserly): is there a better expect to use here?
    expect(false, reason: "\n\nInput:\n$input\n\nExpected:\n$expected"
        "\n\nException:\n$e\n\nStack trace:\n$stack");
  }

  var output = testSerializer(document);

  if (namespaceHTMLElements) {
    expected = namespaceHtml(expected);
  }

  expect(output, equals(expected), reason:
      "\n\nInput:\n$input\n\nExpected:\n$expected\n\nReceived:\n$output");

  if (checkParseErrors) {
    expect(p.errors.length, equals(errors.length), reason:
        "\n\nInput:\n$input\n\nExpected errors (${errors.length}):\n"
        "${Strings.join(errors, '\n')}\n\nActual errors (${p.errors.length}):\n"
        "${Strings.join(p.errors.map((e) => '$e'), '\n')}");
  }
}


void main() {
  getDataFiles('tree-construction').then((files) {
    for (var path in files) {
      var tests = new TestData(path, "data");
      var testName = new Path.fromNative(path).filename.replaceAll(".dat", "");

      group(testName, () {
        int index = 0;
        for (var testData in tests) {
          var input = testData['data'];
          var errors = testData['errors'];
          var innerHTML = testData['document-fragment'];
          var expected = testData['document'];
          if (errors != null) {
            errors = errors.split("\n");
          }

          for (var treeCtor in treeTypes.getValues()) {
            for (var namespaceHTMLElements in const [false, true]) {
              test(input, () {
                runParserTest(testName, innerHTML, input, expected, errors,
                    treeCtor, namespaceHTMLElements);
              });
            }
          }

          index++;
        }
      });
    }
  });
}
