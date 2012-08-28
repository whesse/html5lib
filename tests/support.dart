#library('support');
#import('dart:io');
#import('../treebuilders/simpletree.dart');

typedef TreeBuilder TreeBuilderFactory(bool namespaceHTMLElements);

Map _treeTypes;
Map<String, TreeBuilderFactory> get treeTypes {
  if (_treeTypes == null) {
    // TODO(jmesserly): add DOM here once it's implemented
    _treeTypes = { "simpletree": (useNs) => new TreeBuilder(useNs) };
  }
  return _treeTypes;
}

final testDataDir = '';

typedef bool FileMatcher(String fileName);

Future<List<String>> getDataFiles(String subdirectory, [FileMatcher matcher]) {
  if (matcher == null) matcher = (path) => path.endsWith('.dat');

  // TODO(jmesserly): should have listSync for scripting...
  // This entire method was one line of Python code
  var dir = new Directory.fromPath(new Path('tests/data/$subdirectory'));
  var lister = dir.list();
  var files = <String>[];
  lister.onFile = (file) {
    if (matcher(file)) files.add(file);
  };
  var completer = new Completer<List<String>>();
  lister.onDone = (success) {
    completer.complete(files);
  };
  return completer.future;
}

Function convert(int stripChars) {
  // convert the output of str(document) to the format used in the testcases
  convertData(data) {
    var rv = [];
    for (var line in data.split("\n")) {
      if (line.startsWith("|")) {
        rv.add(line.substring(stripChars));
      } else {
        rv.add(line);
      }
    }
    return Strings.join(rv, "\n");
  }
  return convertData;
}

Function get convertExpected => convert(2);

class TestData implements Iterable<Map> {
  final List<String> _lines;
  final String newTestHeading;

  TestData(String filename, [this.newTestHeading = "data"])
      : _lines = new File(filename).readAsLinesSync();

  // Note: in Python this was a generator, but since we can't do that in Dart,
  // it's easier to convert it into an upfront computation.
  Iterator<Map> iterator() => _getData().iterator();

  List<Map> _getData() {
    var data = <String, String>{};
    var key = null;
    var result = <Map>[];
    for (var line in _lines) {
      var heading = sectionHeading(line);
      if (heading != null) {
        if (data.length > 0 && heading == newTestHeading) {
          // Remove trailing newline
          data[key] = data[key].substring(0, data[key].length - 1);
          result.add(normaliseOutput(data));
          data = <String, String>{};
        }
        key = heading;
        data[key] = "";
      } else if (key != null) {
        data[key] = '${data[key]}$line\n';
      }
    }

    if (data.length > 0) {
      result.add(normaliseOutput(data));
    }
    return result;
  }

  /**
   * If the current heading is a test section heading return the heading,
   * otherwise return null.
   */
  static String sectionHeading(String line) {
    return line.startsWith("#") ? line.substring(1).trim() : null;
  }

  static Map normaliseOutput(Map data) {
    // Remove trailing newlines
    data.forEach((key, value) {
      if (value.endsWith("\n")) {
        data[key] = value.substring(0, value.length - 1);
      }
    });
    return data;
  }
}

/**
 * Serialize the [document] into the html5 test data format.
 */
testSerializer(Document document) {
  return new TestSerializer()..visit(document).toString();
}

/** Serializes the DOM into test format. See [testSerializer]. */
class TestSerializer extends TreeVisitor {
  final StringBuffer _str;
  int _indent;
  String _spaces;

  TestSerializer() : _str = new StringBuffer();

  String toString() => _str.toString();

  int get indent => _indent;

  set indent(int value) {
    if (_indent == value) return;

    var arr = new List<int>(value);
    for (int i = 0; i < value; i++) {
      arr[i] = 32;
    }
    _spaces = new String.fromCharCodes(arr);
    _indent = value;
  }

  visitNodeFallback(Node node) {
    _str.add('\n|${_spaces}$node');
    visitChildren(node);
  }

  visitChildren(Node node) {
    indent += 2;
    for (var child in node.nodes) visit(child);
    indent -= 2;
  }

  visitDocument(Document node) {
    _str.add(node);
    visitChildren(node);
  }

  visitElement(Element node) {
    _str.add('\n|${_spaces}$node');
    if (node.attributes.length > 0) {
      indent += 2;
      var keys = new List.from(node.attributes.getKeys());
      keys.sort((x, y) => x.compareTo(y));
      for (var key in keys) {
        var v = node.attributes[key];
        if (key is AttributeName) {
          AttributeName attr = key;
          key = "${attr.prefix} ${attr.name}";
        }
        _str.add('\n|${_spaces}$key="$v"');
      }
      indent -= 2;
    }
    visitChildren(node);
  }
}
