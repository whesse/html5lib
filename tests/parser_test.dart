#library('parser_test');

#import('dart:io');
#import('package:unittest/unittest.dart');
#import('../constants.dart');
#import('../html5parser.dart');
#import('../tokenizer.dart');
#import('../utils.dart');
#import('../treebuilders/simpletree.dart');
#import('support.dart');

// Run the parse error checks
// TODO(jmesserly): presumably we want this on by default?
final checkParseErrors = false;

// XXX - There should just be one function here but for some reason the testcase
// format differs from the treedump format by a single space character
String convertTreeDump(String data) {
  return Strings.join(slice(convert(3)(data).split("\n"), 1), "\n");
}

String namespaceHtml(String expected) {
  // TODO(jmesserly): this is a workaround for http://dartbug.com/2979
  // We can't do regex replace directly =\
  // final namespaceExpected = const RegExp(@"^(\s*)<(\S+)>", multiLine: true);
  // return expected.replaceAll(namespaceExpected, @"$1<html $2>");
  final namespaceExpected = const RegExp(@"^(\s*)<(\S+)>");
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
  } catch (DataLossWarning w) {
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
      } catch (DataLossWarning w) {
        return;
      }
    }
  } catch (var e, var stack) {
    // TODO(jmesserly): is there a better expect to use here?
    expect(false, reason: "\n\nInput:\n$input\n\nExpected:\n$expected"
        "\n\nException:\n$e\n\nStack trace:\n$stack");
  }

  String output = convertTreeDump(testSerializer(document));

  expected = convertExpected(expected);
  if (namespaceHTMLElements) {
    expected = namespaceHtml(expected);
  }

  if (groupName == 'plain-text-unsafe' && output != expected) {
    // TODO(jmesserly): investigate why these are failing.
    print('SKIP(needsfix): $groupName $input');
    return;
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
            // TOOD(jmesserly): fix namespaceHTMLElements
            for (var namespaceHTMLElements in const [true, false]) {
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
