/**
 * A simple tree API that results from parsing html. Intended to be compatible
 * with dart:html, but right now it resembles the classic JS DOM.
 */
#library('simpletree');

#import('base.dart', prefix: 'base');
#import('../lib/constants.dart');
#import('../lib/utils.dart');

final Marker = base.Marker;

// TODO(jmesserly): I added this class to replace the tuple usage in Python.
// It needs to be hashable and store the prefix, name, and namespace.
class AttributeName implements Hashable, Comparable {
  /** The namespace prefix, e.g. `xlink`. */
  final String prefix;

  /** The attribute name, e.g. `title`. */
  final String name;

  /** The namespace url, e.g. `http://www.w3.org/1999/xlink` */
  final String namespace;

  const AttributeName(this.prefix, this.name, this.namespace);

  int hashCode() {
    int h = prefix.hashCode();
    h = 37 * (h & 0x1FFFFF) + name.hashCode();
    h = 37 * (h & 0x1FFFFF) + namespace.hashCode();
    return h & 0x3FFFFFFF;
  }

  int compareTo(other) {
    // Not sure about this sort order
    if (other is! AttributeName) return 1;
    int cmp = (prefix != null ? prefix : "").compareTo(
          (other.prefix != null ? other.prefix : ""));
    if (cmp != 0) return cmp;
    cmp = name.compareTo(other.name);
    if (cmp != 0) return cmp;
    return namespace.compareTo(other.namespace);
  }

  bool operator ==(x) {
    if (x is! AttributeName) return false;
    return prefix == x.prefix && name == x.name && namespace == x.namespace;
  }
}

/**
 * Note: this is meant to match:
 * <http://docs.python.org/library/xml.sax.utils.html#xml.sax.saxutils.escape>
 * So we only escape `&` `<` and `>`, unlike Dart's htmlEscape function.
 */
String _escape(String text, [Map extraReplace]) {
  // TODO(efortuna): A more efficient implementation.
  text = text.replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");
  if (extraReplace != null) {
    extraReplace.forEach((k, v) { text = text.replaceAll(k, v); });
  }
  return text;
}

String _spaces(int indent) {
  if (indent == 0) return '';
  var arr = new List<int>(indent);
  for (int i = 0; i < indent; i++) {
    arr[i] = 32;
  }
  return new String.fromCharCodes(arr);
}

/** Really basic implementation of a DOM-core like thing. */
class Node extends base.Node implements Iterable<Node> {
  static const int type = -1;

  Node(name) : super(name);

  // TODO(jmesserly): some bug is preventing this from working.
  // List<Node> get childNodes() => super.childNodes;

  /** Iterates over children recursively, via preorder traversal. */
  base.PreorderNodeIterator<Node> iterator() =>
      new base.PreorderNodeIterator(this);

  // TODO(jmesserly): fix the efficiency of the string methods. They do tons of
  // string concat.
  abstract String toxml();

  abstract String hilite();

  abstract Node cloneNode();

  String toString() => name;

  String printTree([int indent = 0]) {
    var tree = '\n|${_spaces(indent)}$this';
    for (var child in childNodes) {
      tree = '${tree}${child.printTree(indent + 2)}';
    }
    return tree;
  }

  void appendChild(Node node) {
    if (node is TextNode && childNodes.length > 0 &&
        childNodes.last() is TextNode) {
      TextNode last = childNodes.last();
      last.value = '${last.value}${node.value}';
    } else {
      childNodes.add(node);
    }
    node.parent = this;
  }

  void insertText(String data, [Node refNode]) {
    if (refNode == null) {
      appendChild(new TextNode(data));
    } else {
      insertBefore(new TextNode(data), refNode);
    }
  }

  void insertBefore(Node node, Node refNode) {
    int index = childNodes.indexOf(refNode);
    if (node is TextNode && index > 0 &&
        childNodes[index - 1] is TextNode) {
      TextNode last = childNodes[index - 1];
      last.value = '${last.value}${node.value}';
    } else {
      childNodes.insertRange(index, 1, node);
    }
    node.parent = this;
  }

  void removeChild(Node node) {
    removeFromList(childNodes, node);
    node.parent = null;
  }

  /** Return true if the node has children or text. */
  bool hasContent() => childNodes.length > 0;

  Pair<String, String> get nameTuple {
    var ns = namespace != null ? namespace : Namespaces.html;
    return new Pair(ns, name);
  }
}

class Document extends Node {
  static const type = 1;

  Document() : super(null);

  String toString() => "#document";

  String toxml() {
    var result = "";
    for (var child in childNodes) {
      result = '${result}${child.toxml()}';
    }
    return result;
  }

  String hilite() {
    var result = "<pre>";
    for (var child in childNodes) {
      result = '${result}${child.hilite()}';
    }
    return "${result}</pre>";
  }

  String printTree([int indent = 0]) {
    var tree = toString();
    indent += 2;
    for (var child in childNodes) {
      tree = '${tree}${child.printTree(indent)}';
    }
    return tree;
  }

  Document cloneNode() => new Document();
}

class DocumentFragment extends Document {
  static const type = 2;

  String toString() => "#document-fragment";

  DocumentFragment cloneNode() => new DocumentFragment();
}

class DocumentType extends Node {
  static const type = 3;

  final String publicId;
  final String systemId;

  DocumentType(String name, this.publicId, this.systemId) : super(name);

  String toString() {
    if (publicId != null || systemId != null) {
      var pid = publicId != null ? publicId : '';
      var sid = systemId != null ? systemId : '';
      return '<!DOCTYPE $name "$pid" "$sid">';
    } else {
      return '<!DOCTYPE $name>';
    }
  }


  String toxml() => toString();

  String hilite() => '<code class="markup doctype">&lt;!DOCTYPE $name></code>';

  DocumentType cloneNode() =>
      new DocumentType(name, publicId, systemId);
}

class TextNode extends Node {
  static const type = 4;

  String value;

  TextNode(this.value) : super(null);

  String toString() => '"$value"';

  String toxml() => _escape(value);

  String hilite() => toxml();

  TextNode cloneNode() => new TextNode(value);
}

class Element extends Node {
  static const type = 5;

  final String namespace;

  Element(String name, [this.namespace]) : super(name);

  String toString() {
    if (namespace == null) return "<$name>";
    return "<${Namespaces.getPrefix(namespace)} $name>";
  }

  String toxml() {
    var result = '<$name';
    if (attributes.length > 0) {
      attributes.forEach((key, v) {
        v = _escape(v, {'"': "&quot;"});
        result = '$result $key="$v"';
      });
    }
    if (childNodes.length > 0) {
      result = '${result}>';
      for (var child in childNodes) {
        result = '${result}${child.toxml()}';
      }
      result = '${result}</$name>';
    } else {
      result = '$result/>';
    }
    return result;
  }

  String hilite() {
    var result = '&lt;<code class="markup element-name">$name</code>';
    if (attributes.length > 0) {
      attributes.forEach((key, v) {
        v = _escape(v, {'"': "&quot;"});
        result = '$result <code class="markup attribute-name">$key</code>'
            '=<code class="markup attribute-value">"$v"</code>';
      });
    }
    if (childNodes.length > 0) {
      result = "${result}>";
      for (var child in childNodes) {
        result = '${result}${child.hilite()}';
      }
    } else if (voidElements.indexOf(name) >= 0) {
      return "${result}>";
    }
    return '${result}&lt;/<code class="markup element-name">$name</code>>';
  }

  String printTree([int indent = 0]) {
    var tree = '\n|${_spaces(indent)}$this';
    indent += 2;
    if (attributes.length > 0) {
      var keys = new List.from(attributes.getKeys());
      keys.sort((x, y) => x.compareTo(y));
      for (var key in keys) {
        var v = attributes[key];
        if (key is AttributeName) {
          AttributeName attr = key;
          key = "${attr.prefix} ${attr.name}";
        }
        tree = '${tree}\n|${_spaces(indent)}$key="$v"';
      }
    }
    for (var child in childNodes) {
      tree = '${tree}${child.printTree(indent)}';
    }
    return tree;
  }

  Element cloneNode() =>
      new Element(name, namespace)..attributes = new Map.from(attributes);
}

class CommentNode extends Node {
  static const type = 6;

  final String data;

  CommentNode(this.data) : super(null);

  String toString() => "<!-- $data -->";

  String toxml() => "<!--$data-->";

  String hilite() =>
      '<code class="markup comment">&lt;!--${_escape(data)}--></code>';

  CommentNode cloneNode() => new CommentNode(data);
}

class TreeBuilder extends
  base.TreeBuilder<Document, Element, CommentNode, DocumentType, DocumentFragment> {

  TreeBuilder(bool namespaceHTMLElements) : super(namespaceHTMLElements);

  // Implement constructors for the generic args.
  Document newDocument() => new Document();
  Element newElement(String name, String ns) => new Element(name, ns);
  CommentNode newComment(String comment) => new CommentNode(comment);
  DocumentType newDoctype(String name, String publicId, String systemId) =>
      new DocumentType(name, publicId, systemId);
  DocumentFragment newFragment() => new DocumentFragment();

  String testSerializer(Node node) => node.printTree();
}


