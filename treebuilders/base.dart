/** Internals to the tree builders. */
#library('base');

#import('../lib/constants.dart');
#import('../lib/list_proxy.dart');
#import('../lib/utils.dart');

// The scope markers are inserted when entering object elements,
// marquees, table cells, and table captions, and are used to prevent formatting
// from "leaking" into tables, object elements, and marquees.
final Marker = null;

// TODO(jmesserly): the generic type here is strange. But it seems the only
// way to get the right type on childNodes. (and overriding that field didn't
// work on the VM in checked mode.
// We should probably get rid of this entire abstraction layer, though.
/** Node representing an item in the tree. */
class Node<T extends Node> {
  /** The tag name associated with the node. */
  final String name;

  /** The parent of the current node (or null for the document node). */
  Node parent;

  /** A map holding name, value pairs for attributes of the node. */
  Map attributes;

  /**
   * A list of child nodes of the current node. This must
   * include all elements but not necessarily other node types.
   */
  final List<T> childNodes;

  Node(this.name) : attributes = {}, childNodes = <T>[];

  /**
   * Insert [node] as a child of the current node
   */
  abstract void appendChild(node);

  /**
   * Insert [data] as text in the current node, positioned before the
   * start of node [refNode] or to the end of the node's text.
   */
  abstract insertText(String data, [Node refNode]);

  /**
   * Insert [node] as a child of the current node, before [refNode] in the
   * list of child nodes. Raises [UnsupportedOperationException] if [refNode]
   * is not a child of the current node.
   */
  abstract insertBefore(Node node, Node refNode);

  /**
   * Remove [node] from the children of the current node
   */
  abstract void removeChild(Node node);

  /**
   * Return a shallow copy of the current node i.e. a node with the same
   * name and attributes but with no parent or child nodes.
   */
  abstract Node cloneNode();

  // TODO(jmesserly): should this be a property?
  /**
   * Return true if the node has children or text, false otherwise.
   */
  abstract bool hasContent();

  String get namespace => null;

  Pair get nameTuple => null;

  // TODO(jmesserly): do we need this here?
  /** The value of the current node (applies to text nodes and comments). */
  String get value => null;

  String toString() {
    if (attributes.length == 0) {
      return "<$name>";
    }
    var attrStr = new StringBuffer();
    attributes.forEach((k, v) => attrStr.add(' $k=$v'));
    return "<${name}attrStr>";
  }

  /**
   * Move all the children of the current node to [newParent].
   * This is needed so that trees that don't store text as nodes move the
   * text in the correct way.
   */
  void reparentChildren(Node newParent) {
    //XXX - should this method be made more general?
    for (var child in childNodes) {
      newParent.appendChild(child);
    }
    childNodes.clear();
  }
}

class ActiveFormattingElements extends ListProxy<Node> {
  ActiveFormattingElements() : super();

  void addLast(Node node) => add(node);
  void add(Node node) {
    int equalCount = 0;
    if (node != Marker) {
      for (var element in reversed(this)) {
        if (element == Marker) {
          break;
        }
        if (_nodesEqual(element, node)) {
          equalCount += 1;
        }
        if (equalCount == 3) {
          removeFromList(this, element);
          break;
        }
      }
    }
    super.add(node);
  }
}

// TODO(jmesserly): this should exist in corelib...
bool _mapEquals(Map a, Map b) {
  if (a.length != b.length) return false;
  if (a.length == 0) return true;

  for (var keyA in a.getKeys()) {
    var valB = b[keyA];
    if (valB == null && !b.containsKey(keyA)) {
      return false;
    }

    if (a[keyA] != valB) {
      return false;
    }
  }
  return true;
}


bool _nodesEqual(Node node1, Node node2) {
  return node1.nameTuple == node2.nameTuple &&
      _mapEquals(node1.attributes, node2.attributes);
}

/** Base treebuilder implementation. */
abstract class TreeBuilder<
    // TODO(jmesserly): is there a better design here?
    // This seems like the only way to get accurate types.
    Document extends Node,
    Element extends Node,
    Comment extends Node,
    Doctype extends Node,
    Fragment extends Node> {

  final String defaultNamespace;

  Document document;

  final List<Node> openElements;

  final ActiveFormattingElements activeFormattingElements;

  Node headPointer;

  Node formPointer;

  /**
   * Switch the function used to insert an element from the
   * normal one to the misnested table one and back again
   */
  bool insertFromTable;

  TreeBuilder(bool namespaceHTMLElements)
      : defaultNamespace = namespaceHTMLElements ? Namespaces.html : null,
        openElements = <Node>[],
        activeFormattingElements = new ActiveFormattingElements() {
    reset();
  }

  /** The factory to use for the bottommost node of a document. */
  abstract Document newDocument();

  /** The factory to use for creating a node. */
  abstract Element newElement(String name, String namespace);

  /** The factory to use for creating comments. */
  abstract Comment newComment(String comment);

  /** The factory to use for creating doctypes. */
  abstract Doctype newDoctype(String name, String publicId, String systemId);

  /** The factory to use for creating fragments. */
  abstract Fragment newFragment();

  void reset() {
    openElements.clear();
    activeFormattingElements.clear();

    //XXX - rename these to headElement, formElement
    headPointer = null;
    formPointer = null;

    insertFromTable = false;

    document = newDocument();
  }

  bool elementInScope(target, [String variant]) {
    //If we pass a node in we match that. if we pass a string
    //match any node with that name
    bool exactNode = target is Node && target.nameTuple != null;

    List listElements1 = scopingElements;
    List listElements2 = const [];
    bool invert = false;
    if (variant != null) {
      switch (variant) {
        case "button":
          listElements2 = const [const Pair(Namespaces.html, "button")];
          break;
        case "list":
          listElements2 = const [const Pair(Namespaces.html, "ol"),
                                 const Pair(Namespaces.html, "ul")];
          break;
        case "table":
          listElements1 = const [const Pair(Namespaces.html, "html"),
                                 const Pair(Namespaces.html, "table")];
          break;
        case "select":
          listElements1 = const [const Pair(Namespaces.html, "optgroup"),
                                 const Pair(Namespaces.html, "option")];
          invert = true;
          break;
        default: assert(false);
      }
    }

    for (var node in reversed(openElements)) {
      if (node.name == target && !exactNode ||
          node == target && exactNode) {
        return true;
      } else if (invert !=
          (listElements1.indexOf(node.nameTuple) >= 0 ||
           listElements2.indexOf(node.nameTuple) >= 0)) {
        return false;
      }
    }

    assert(false); // We should never reach this point
  }

  void reconstructActiveFormattingElements() {
    // Within this algorithm the order of steps described in the
    // specification is not quite the same as the order of steps in the
    // code. It should still do the same though.

    // Step 1: stop the algorithm when there's nothing to do.
    if (activeFormattingElements.length == 0) {
      return;
    }

    // Step 2 and step 3: we start with the last element. So i is -1.
    int i = activeFormattingElements.length - 1;
    var entry = activeFormattingElements[i];
    if (entry == Marker || openElements.indexOf(entry) >= 0) {
      return;
    }

    // Step 6
    while (entry != Marker && openElements.indexOf(entry) == -1) {
      if (i == 0) {
        //This will be reset to 0 below
        i = -1;
        break;
      }
      i -= 1;
      // Step 5: let entry be one earlier in the list.
      entry = activeFormattingElements[i];
    }

    while (true) {
      // Step 7
      i += 1;

      // Step 8
      entry = activeFormattingElements[i];
      var clone = entry.cloneNode(); // Mainly to get a new copy of the attributes

      // Step 9
      var element = insertElement({"type": "StartTag", "name": clone.name,
          "namespace": clone.namespace, "data": clone.attributes});

      // Step 10
      activeFormattingElements[i] = element;

      // Step 11
      if (element == activeFormattingElements.last()) {
        break;
      }
    }
  }

  void clearActiveFormattingElements() {
    var entry = activeFormattingElements.removeLast();
    while (activeFormattingElements.length > 0 && entry != Marker) {
      entry = activeFormattingElements.removeLast();
    }
  }

  /**
   * Check if an element exists between the end of the active
   * formatting elements and the last marker. If it does, return it, else
   * return null
   */
  Node elementInActiveFormattingElements(String name) {
    for (var item in reversed(activeFormattingElements)) {
      // Check for Marker first because if it's a Marker it doesn't have a
      // name attribute.
      if (item == Marker) {
        break;
      } else if (item.name == name) {
        return item;
      }
    }
    return null;
  }

  void insertRoot(Map token) {
    var element = createElement(token);
    openElements.add(element);
    document.appendChild(element);
  }

  void insertDoctype(Map token) {
    var name = token["name"];
    var publicId = token["publicId"];
    var systemId = token["systemId"];

    var doctype = newDoctype(name, publicId, systemId);
    document.appendChild(doctype);
  }

  void insertComment(Map token, [Node parent]) {
    if (parent == null) {
      parent = openElements.last();
    }
    parent.appendChild(newComment(token["data"]));
  }

    /** Create an element but don't insert it anywhere */
  Element createElement(Map token) {
    var name = token["name"];
    var namespace = token["namespace"];
    if (namespace == null) namespace = defaultNamespace;
    var element = newElement(name, namespace);
    element.attributes = token["data"];
    return element;
  }

  Element insertElement(Map token) {
    if (insertFromTable) return insertElementTable(token);
    return insertElementNormal(token);
  }

  Element insertElementNormal(token) {
    var name = token["name"];
    var namespace = token["namespace"];
    if (namespace == null) namespace = defaultNamespace;
    Element element = newElement(name, namespace);
    element.attributes = token["data"];
    openElements.last().appendChild(element);
    openElements.add(element);
    return element;
  }

  Element insertElementTable(token) {
    /** Create an element and insert it into the tree */
    var element = createElement(token);
    if (tableInsertModeElements.indexOf(openElements.last().name) == -1) {
      return insertElementNormal(token);
    } else {
      // We should be in the InTable mode. This means we want to do
      // special magic element rearranging
      var nodePos = getTableMisnestedNodePosition();
      if (nodePos[1] == null) {
        nodePos[0].appendChild(element);
      } else {
        nodePos[0].insertBefore(element, nodePos[1]);
      }
      openElements.add(element);
    }
    return element;
  }

  /** Insert text data. */
  void insertText(String data, [Node parent]) {
    if (parent == null) parent = openElements.last();

    if (!insertFromTable || insertFromTable &&
        tableInsertModeElements.indexOf(openElements.last().name) == -1) {
      parent.insertText(data);
    } else {
      // We should be in the InTable mode. This means we want to do
      // special magic element rearranging
      var nodePos = getTableMisnestedNodePosition();
      nodePos[0].insertText(data, nodePos[1]);
    }
  }

  /**
   * Get the foster parent element, and sibling to insert before
   * (or null) when inserting a misnested table node
   */
  List getTableMisnestedNodePosition() {
    // The foster parent element is the one which comes before the most
    // recently opened table element
    // XXX - this is really inelegant
    var lastTable = null;
    var fosterParent = null;
    var insertBefore = null;
    for (var elm in reversed(openElements)) {
      if (elm.name == "table") {
        lastTable = elm;
        break;
      }
    }
    if (lastTable != null) {
      // XXX - we should really check that this parent is actually a
      // node here
      if (lastTable.parent != null) {
        fosterParent = lastTable.parent;
        insertBefore = lastTable;
      } else {
        fosterParent = openElements[openElements.indexOf(lastTable) - 1];
      }
    } else {
      fosterParent = openElements[0];
    }
    return [fosterParent, insertBefore];
  }

  void generateImpliedEndTags([String exclude]) {
    var name = openElements.last().name;
    // XXX td, th and tr are not actually needed
    if (name != exclude && const ["dd", "dt", "li", "option", "optgroup", "p",
        "rp", "rt"].indexOf(name) >= 0) {
      openElements.removeLast();
      // XXX This is not entirely what the specification says. We should
      // investigate it more closely.
      generateImpliedEndTags(exclude);
    }
  }

  /** Return the final tree. */
  Document getDocument() => document;

  /** Return the final fragment. */
  Fragment getFragment() {
    //XXX assert innerHTML
    var fragment = newFragment();
    openElements[0].reparentChildren(fragment);
    return fragment;
  }

  /**
   * Serialize the subtree of node in the format required by unit tests
   * node - the node from which to start serializing
   */
  String testSerializer(node) {
    throw const NotImplementedException();
  }
}
