#library('html5parser');

#import('dart:math');
#import('package:logging/logging.dart');
#import('treebuilders/base.dart'); // for Marker
#import('treebuilders/simpletree.dart');
#import('lib/constants.dart');
#import('lib/encoding_parser.dart');
#import('lib/token.dart');
#import('lib/utils.dart');
#import('tokenizer.dart');

// TODO(jmesserly): these APIs, as well as the HTMLParser contructor and
// HTMLParser.parse and parseFragment were changed a bit to avoid passing a
// first class type that is used for construction. It might be okay, but I'd
// like to find a good dependency-injection pattern for Dart rather than
// copy the Python API.
// TODO(jmesserly): Also some of the HTMLParser APIs are messed up to avoid
// editor shadowing warnings :\. Look for trailing underscores.
/**
 * Parse an html5 [doc]ument that is a [String], [RandomAccessFile] or
 * [List<int>] of bytes into a tree.
 *
 * The optional [encoding] must be a string that indicates the encoding. If
 * specified, that encoding will be used, regardless of any BOM or later
 * declaration (such as in a meta element).
 */
Document parse(doc, [TreeBuilder treebuilder, String encoding]) {
  var tokenizer = new HTMLTokenizer(doc, encoding: encoding);
  return new HTMLParser(treebuilder).parse(tokenizer);
}

/**
 * Parse an html5 [doc]ument fragment that is a [String], [RandomAccessFile] or
 * [List<int>] of bytes into a tree. Pass a [container] to change the type of
 * the containing element.
 *
 * The optional [encoding] must be a string that indicates the encoding. If
 * specified, that encoding will be used, regardless of any BOM or later
 * declaration (such as in a meta element).
 */
DocumentFragment parseFragment(doc, [String container = "div",
    TreeBuilder treebuilder, String encoding]) {
  var tokenizer = new HTMLTokenizer(doc, encoding: encoding);
  var parser = new HTMLParser(treebuilder);
  return parser.parseFragment(tokenizer, container_: container);
}


/**
 * HTML parser. Generates a tree structure from a stream of (possibly malformed)
 * HTML.
 */
class HTMLParser {
  /** Raise an exception on the first error encountered. */
  bool strict;

  final TreeBuilder tree;

  List<ParseError> errors;

  // TODO(jmesserly): would be faster not to use Map lookup.
  Map<String, Phase> phases;

  bool innerHTMLMode;

  String container;

  bool firstStartTag = false;

  // TODO(jmesserly): use enum?
  /** "quirks" / "limited quirks" / "no quirks" */
  String compatMode = "no quirks";

  /** innerHTML container when parsing document fragment. */
  String innerHTML;

  Phase phase;

  Phase lastPhase;

  Phase originalPhase;

  Phase beforeRCDataPhase;

  bool framesetOK;

  HTMLTokenizer tokenizer;

  // These fields hold the different phase singletons. At any given time one
  // of them will be active.
  InitialPhase _initialPhase;
  BeforeHtmlPhase _beforeHtmlPhase;
  BeforeHeadPhase _beforeHeadPhase;
  InHeadPhase _inHeadPhase;
  AfterHeadPhase _afterHeadPhase;
  InBodyPhase _inBodyPhase;
  TextPhase _textPhase;
  InTablePhase _inTablePhase;
  InTableTextPhase _inTableTextPhase;
  InCaptionPhase _inCaptionPhase;
  InColumnGroupPhase _inColumnGroupPhase;
  InTableBodyPhase _inTableBodyPhase;
  InRowPhase _inRowPhase;
  InCellPhase _inCellPhase;
  InSelectPhase _inSelectPhase;
  InSelectInTablePhase _inSelectInTablePhase;
  InForeignContentPhase _inForeignContentPhase;
  AfterBodyPhase _afterBodyPhase;
  InFramesetPhase _inFramesetPhase;
  AfterFramesetPhase _afterFramesetPhase;
  AfterAfterBodyPhase _afterAfterBodyPhase;
  AfterAfterFramesetPhase _afterAfterFramesetPhase;

  /**
   * Create a new HTMLParser and configure the [tree] builder and [strict] mode.
   */
  HTMLParser([TreeBuilder tree, this.strict = false])
      : tree = tree != null ? tree : new TreeBuilder(true),
        errors = <ParseError>[] {

    _initialPhase = new InitialPhase(this);
    _beforeHtmlPhase = new BeforeHtmlPhase(this);
    _beforeHeadPhase = new BeforeHeadPhase(this);
    _inHeadPhase = new InHeadPhase(this);
      // XXX "inHeadNoscript": new InHeadNoScriptPhase(this);
    _afterHeadPhase = new AfterHeadPhase(this);
    _inBodyPhase = new InBodyPhase(this);
    _textPhase = new TextPhase(this);
    _inTablePhase = new InTablePhase(this);
    _inTableTextPhase = new InTableTextPhase(this);
    _inCaptionPhase = new InCaptionPhase(this);
    _inColumnGroupPhase = new InColumnGroupPhase(this);
    _inTableBodyPhase = new InTableBodyPhase(this);
    _inRowPhase = new InRowPhase(this);
    _inCellPhase = new InCellPhase(this);
    _inSelectPhase = new InSelectPhase(this);
    _inSelectInTablePhase = new InSelectInTablePhase(this);
    _inForeignContentPhase = new InForeignContentPhase(this);
    _afterBodyPhase = new AfterBodyPhase(this);
    _inFramesetPhase = new InFramesetPhase(this);
    _afterFramesetPhase = new AfterFramesetPhase(this);
    _afterAfterBodyPhase = new AfterAfterBodyPhase(this);
    _afterAfterFramesetPhase = new AfterAfterFramesetPhase(this);
    // XXX after after frameset
  }

  /**
   * Parse a HTML document into a well-formed tree
   *
   * [tokenizer_] - an object that provides a stream of tokens to the
   * treebuilder. This may be replaced for e.g. a sanitizer which converts some
   * tags to text. Otherwise, construct an instance of HTMLTokenizer with the
   * appropriate options.
   */
  Document parse(HTMLTokenizer tokenizer_) {
    _parse(tokenizer_, innerHTML_: false);
    return tree.getDocument();
  }

  /**
   * Parse a HTML fragment into a well-formed tree fragment.
   *
   * [container_] - name of the element we're setting the innerHTML property
   * if set to null, default to 'div'.
   *
   * [tokenizer_] - an object that provides a stream of tokens to the
   * treebuilder. This may be replaced for e.g. a sanitizer which converts some
   * tags to text. Otherwise, construct an instance of HTMLTokenizer with the
   * appropriate options.
   */
  DocumentFragment parseFragment(HTMLTokenizer tokenizer_,
      [String container_ = "div"]) {
    _parse(tokenizer_, innerHTML_: true, container_: container_);
    return tree.getFragment();
  }

  void _parse(HTMLTokenizer tokenizer_, [bool innerHTML_ = false,
      String container_ = "div"]) {

    innerHTMLMode = innerHTML_;
    container = container_;
    tokenizer = tokenizer_;
    // TODO(jmesserly): this feels a little strange, but it's needed for CDATA.
    // Maybe we should change the API to having the parser create the tokenizer.
    tokenizer.parser = this;

    reset();

    while (true) {
      try {
        mainLoop();
        break;
      } on ReparseException catch (e) {
        reset();
      }
    }
  }

  void reset() {
    tree.reset();
    firstStartTag = false;
    errors = <ParseError>[];
    // "quirks" / "limited quirks" / "no quirks"
    compatMode = "no quirks";

    if (innerHTMLMode) {
      innerHTML = container.toLowerCase();

      if (cdataElements.indexOf(innerHTML) >= 0) {
        tokenizer.state = tokenizer.rcdataState;
      } else if (rcdataElements.indexOf(innerHTML) >= 0) {
        tokenizer.state = tokenizer.rawtextState;
      } else if (innerHTML == 'plaintext') {
        tokenizer.state = tokenizer.plaintextState;
      } else {
        // state already is data state
        // tokenizer.state = tokenizer.dataState;
      }
      phase = _beforeHtmlPhase;
      _beforeHtmlPhase.insertHtmlElement();
      resetInsertionMode();
    } else {
      innerHTML = null;
      phase = _initialPhase;
    }

    lastPhase = null;
    beforeRCDataPhase = null;
    framesetOK = true;
  }

  bool isHTMLIntegrationPoint(Node element) {
    if (element.tagName == "annotation-xml" &&
        element.namespace == Namespaces.mathml) {
      var enc = element.attributes["encoding"];
      if (enc != null) enc = asciiUpper2Lower(enc);
      return enc == "text/html" || enc == "application/xhtml+xml";
    } else {
      return htmlIntegrationPointElements.indexOf(
          new Pair(element.namespace, element.tagName)) >= 0;
    }
  }

  bool isMathMLTextIntegrationPoint(Node element) {
    return mathmlTextIntegrationPointElements.indexOf(
        new Pair(element.namespace, element.tagName)) >= 0;
  }

  bool inForeignContent(Token token, int type) {
    if (tree.openElements.length == 0) return false;

    var node = tree.openElements.last();
    if (node.namespace == tree.defaultNamespace) return false;

    if (isMathMLTextIntegrationPoint(node)) {
      if (type == TokenKind.startTag &&
          (token as StartTagToken).name != "mglyph" &&
          (token as StartTagToken).name != "malignmark")  {
        return false;
      }
      if (type == TokenKind.characters || type == TokenKind.spaceCharacters) {
        return false;
      }
    }

    if (node.tagName == "annotation-xml" && type == TokenKind.startTag &&
        (token as StartTagToken).name == "svg") {
      return false;
    }

    if (isHTMLIntegrationPoint(node)) {
      if (type == TokenKind.startTag ||
          type == TokenKind.characters ||
          type == TokenKind.spaceCharacters) {
        return false;
      }
    }

    return true;
  }

  void mainLoop() {
    while (tokenizer.hasNext()) {
      var token = normalizeToken(tokenizer.next());
      var newToken = token;
      int type;
      while (newToken !== null) {
        type = newToken.kind;

        // Note: avoid "is" test here, see http://dartbug.com/4795
        if (type == TokenKind.parseError) {
          ParseErrorToken error = newToken;
          parseError(error.data, error.messageParams);
          newToken = null;
        } else {
          Phase phase_ = phase;
          if (inForeignContent(token, type)) {
            phase_ = _inForeignContentPhase;
          }

          switch (type) {
            case TokenKind.characters:
              newToken = phase_.processCharacters(newToken);
              break;
            case TokenKind.spaceCharacters:
              newToken = phase_.processSpaceCharacters(newToken);
              break;
            case TokenKind.startTag:
              newToken = phase_.processStartTag(newToken);
              break;
            case TokenKind.endTag:
              newToken = phase_.processEndTag(newToken);
              break;
            case TokenKind.comment:
              newToken = phase_.processComment(newToken);
              break;
            case TokenKind.doctype:
              newToken = phase_.processDoctype(newToken);
              break;
          }
        }
      }

      if (token is StartTagToken) {
        if (token.selfClosing && !token.selfClosingAcknowledged) {
          parseError("non-void-element-with-trailing-solidus",
              {"name": token.name});
        }
      }
    }

    // When the loop finishes it's EOF
    var reprocess = true;
    var reprocessPhases = [];
    while (reprocess) {
      reprocessPhases.add(phase);
      reprocess = phase.processEOF();
      if (reprocess) {
        assert(reprocessPhases.indexOf(phase) == -1);
      }
    }
  }

  void parseError([String errorcode = "XXX-undefined-error",
      Map datavars = const {}]) {
    // XXX The idea is to make errorcode mandatory.
    var position = tokenizer.stream.position();
    var err = new ParseError(errorcode, position, datavars);
    errors.add(err);
    if (strict) throw err;
  }

  /** HTML5 specific normalizations to the token stream. */
  Token normalizeToken(Token token) {
    if (token is StartTagToken) {
      token.data = makeDict(token.data);
    }
    return token;
  }

  void adjustMathMLAttributes(StartTagToken token) {
    var orig = token.data.remove("definitionurl");
    if (orig != null) {
      token.data["definitionURL"] = orig;
    }
  }

  void adjustSVGAttributes(Token token) {
    final replacements = const {
      "attributename":"attributeName",
      "attributetype":"attributeType",
      "basefrequency":"baseFrequency",
      "baseprofile":"baseProfile",
      "calcmode":"calcMode",
      "clippathunits":"clipPathUnits",
      "contentscripttype":"contentScriptType",
      "contentstyletype":"contentStyleType",
      "diffuseconstant":"diffuseConstant",
      "edgemode":"edgeMode",
      "externalresourcesrequired":"externalResourcesRequired",
      "filterres":"filterRes",
      "filterunits":"filterUnits",
      "glyphref":"glyphRef",
      "gradienttransform":"gradientTransform",
      "gradientunits":"gradientUnits",
      "kernelmatrix":"kernelMatrix",
      "kernelunitlength":"kernelUnitLength",
      "keypoints":"keyPoints",
      "keysplines":"keySplines",
      "keytimes":"keyTimes",
      "lengthadjust":"lengthAdjust",
      "limitingconeangle":"limitingConeAngle",
      "markerheight":"markerHeight",
      "markerunits":"markerUnits",
      "markerwidth":"markerWidth",
      "maskcontentunits":"maskContentUnits",
      "maskunits":"maskUnits",
      "numoctaves":"numOctaves",
      "pathlength":"pathLength",
      "patterncontentunits":"patternContentUnits",
      "patterntransform":"patternTransform",
      "patternunits":"patternUnits",
      "pointsatx":"pointsAtX",
      "pointsaty":"pointsAtY",
      "pointsatz":"pointsAtZ",
      "preservealpha":"preserveAlpha",
      "preserveaspectratio":"preserveAspectRatio",
      "primitiveunits":"primitiveUnits",
      "refx":"refX",
      "refy":"refY",
      "repeatcount":"repeatCount",
      "repeatdur":"repeatDur",
      "requiredextensions":"requiredExtensions",
      "requiredfeatures":"requiredFeatures",
      "specularconstant":"specularConstant",
      "specularexponent":"specularExponent",
      "spreadmethod":"spreadMethod",
      "startoffset":"startOffset",
      "stddeviation":"stdDeviation",
      "stitchtiles":"stitchTiles",
      "surfacescale":"surfaceScale",
      "systemlanguage":"systemLanguage",
      "tablevalues":"tableValues",
      "targetx":"targetX",
      "targety":"targetY",
      "textlength":"textLength",
      "viewbox":"viewBox",
      "viewtarget":"viewTarget",
      "xchannelselector":"xChannelSelector",
      "ychannelselector":"yChannelSelector",
      "zoomandpan":"zoomAndPan"
    };
    for (var originalName in token.data.getKeys()) {
      var svgName = replacements[originalName];
      if (svgName != null) {
        token.data[svgName] = token.data.remove(originalName);
      }
    }
  }

  void adjustForeignAttributes(Token token) {
    // TODO(jmesserly): I don't like mixing non-string objects with strings in
    // the Node.attributes Map. Is there another solution?
    final replacements = const {
      "xlink:actuate": const AttributeName("xlink", "actuate",
            Namespaces.xlink),
      "xlink:arcrole": const AttributeName("xlink", "arcrole",
            Namespaces.xlink),
      "xlink:href": const AttributeName("xlink", "href", Namespaces.xlink),
      "xlink:role": const AttributeName("xlink", "role", Namespaces.xlink),
      "xlink:show": const AttributeName("xlink", "show", Namespaces.xlink),
      "xlink:title": const AttributeName("xlink", "title", Namespaces.xlink),
      "xlink:type": const AttributeName("xlink", "type", Namespaces.xlink),
      "xml:base": const AttributeName("xml", "base", Namespaces.xml),
      "xml:lang": const AttributeName("xml", "lang", Namespaces.xml),
      "xml:space": const AttributeName("xml", "space", Namespaces.xml),
      "xmlns": const AttributeName(null, "xmlns", Namespaces.xmlns),
      "xmlns:xlink": const AttributeName("xmlns", "xlink", Namespaces.xmlns)
    };

    for (var originalName in token.data.getKeys()) {
      var foreignName = replacements[originalName];
      if (foreignName != null) {
        token.data[foreignName] = token.data.remove(originalName);
      }
    }
  }

  void resetInsertionMode() {
    // The name of this method is mostly historical. (It's also used in the
    // specification.)
    for (Node node in reversed(tree.openElements)) {
      var nodeName = node.tagName;
      bool last = node == tree.openElements[0];
      if (last) {
        assert(innerHTMLMode);
        nodeName = innerHTML;
      }
      // Check for conditions that should only happen in the innerHTML
      // case
      switch (nodeName) {
        case "select": case "colgroup": case "head": case "html":
          assert(innerHTMLMode);
          break;
      }
      if (!last && node.namespace != tree.defaultNamespace) {
        continue;
      }
      switch (nodeName) {
        case "select": phase = _inSelectPhase; return;
        case "td": phase = _inCellPhase; return;
        case "th": phase = _inCellPhase; return;
        case "tr": phase = _inRowPhase; return;
        case "tbody": phase = _inTableBodyPhase; return;
        case "thead": phase = _inTableBodyPhase; return;
        case "tfoot": phase = _inTableBodyPhase; return;
        case "caption": phase = _inCaptionPhase; return;
        case "colgroup": phase = _inColumnGroupPhase; return;
        case "table": phase = _inTablePhase; return;
        case "head": phase = _inBodyPhase; return;
        case "body": phase = _inBodyPhase; return;
        case "frameset": phase = _inFramesetPhase; return;
        case "html": phase = _beforeHeadPhase; return;
      }
    }
    phase = _inBodyPhase;
  }

  /**
   * Generic RCDATA/RAWTEXT Parsing algorithm
   * [contentType] - RCDATA or RAWTEXT
   */
  void parseRCDataRawtext(Token token, String contentType) {
    assert(contentType == "RAWTEXT" || contentType == "RCDATA");

    var element = tree.insertElement(token);

    if (contentType == "RAWTEXT") {
      tokenizer.state = tokenizer.rawtextState;
    } else {
      tokenizer.state = tokenizer.rcdataState;
    }

    originalPhase = phase;
    phase = _textPhase;
  }
}


/** Base class for helper object that implements each phase of processing. */
class Phase {
  // Order should be (they can be omitted):
  // * EOF
  // * Comment
  // * Doctype
  // * SpaceCharacters
  // * Characters
  // * StartTag
  //   - startTag* methods
  // * EndTag
  //   - endTag* methods

  final HTMLParser parser;

  final TreeBuilder tree;

  Phase(HTMLParser parser) : parser = parser, tree = parser.tree;

  bool processEOF() {
    throw const NotImplementedException();
  }

  Token processComment(CommentToken token) {
    // For most phases the following is correct. Where it's not it will be
    // overridden.
    tree.insertComment(token, tree.openElements.last());
  }

  Token processDoctype(DoctypeToken token) {
    parser.parseError("unexpected-doctype");
  }

  Token processCharacters(CharactersToken token) {
    tree.insertText(token.data);
  }

  Token processSpaceCharacters(SpaceCharactersToken token) {
    tree.insertText(token.data);
  }

  Token processStartTag(StartTagToken token) {
    throw const NotImplementedException();
  }

  Token startTagHtml(StartTagToken token) {
    if (parser.firstStartTag == false && token.name == "html") {
       parser.parseError("non-html-root");
    }
    // XXX Need a check here to see if the first start tag token emitted is
    // this token... If it's not, invoke parser.parseError().
    token.data.forEach((attr, value) {
      tree.openElements[0].attributes.putIfAbsent(attr, () => value);
    });
    parser.firstStartTag = false;
  }

  Token processEndTag(EndTagToken token) {
    throw const NotImplementedException();
  }

  /** Helper method for popping openElements. */
  void popOpenElementsUntil(String name) {
    var node = tree.openElements.removeLast();
    while (node.tagName != name) {
      node = tree.openElements.removeLast();
    }
  }
}

class InitialPhase extends Phase {
  InitialPhase(parser) : super(parser);

  Token processSpaceCharacters(SpaceCharactersToken token) {
  }

  Token processComment(CommentToken token) {
    tree.insertComment(token, tree.document);
  }

  Token processDoctype(DoctypeToken token) {
    var name = token.name;
    String publicId = token.publicId;
    var systemId = token.systemId;
    var correct = token.correct;

    if ((name != "html" || publicId != null ||
        systemId != null && systemId != "about:legacy-compat")) {
      parser.parseError("unknown-doctype");
    }

    if (publicId === null) {
      publicId = "";
    }

    tree.insertDoctype(token);

    if (publicId != "") {
      publicId = asciiUpper2Lower(publicId);
    }

    if (!correct || token.name != "html"
        || startsWithAny(publicId, const [
          "+//silmaril//dtd html pro v0r11 19970101//",
          "-//advasoft ltd//dtd html 3.0 aswedit + extensions//",
          "-//as//dtd html 3.0 aswedit + extensions//",
          "-//ietf//dtd html 2.0 level 1//",
          "-//ietf//dtd html 2.0 level 2//",
          "-//ietf//dtd html 2.0 strict level 1//",
          "-//ietf//dtd html 2.0 strict level 2//",
          "-//ietf//dtd html 2.0 strict//",
          "-//ietf//dtd html 2.0//",
          "-//ietf//dtd html 2.1e//",
          "-//ietf//dtd html 3.0//",
          "-//ietf//dtd html 3.2 final//",
          "-//ietf//dtd html 3.2//",
          "-//ietf//dtd html 3//",
          "-//ietf//dtd html level 0//",
          "-//ietf//dtd html level 1//",
          "-//ietf//dtd html level 2//",
          "-//ietf//dtd html level 3//",
          "-//ietf//dtd html strict level 0//",
          "-//ietf//dtd html strict level 1//",
          "-//ietf//dtd html strict level 2//",
          "-//ietf//dtd html strict level 3//",
          "-//ietf//dtd html strict//",
          "-//ietf//dtd html//",
          "-//metrius//dtd metrius presentational//",
          "-//microsoft//dtd internet explorer 2.0 html strict//",
          "-//microsoft//dtd internet explorer 2.0 html//",
          "-//microsoft//dtd internet explorer 2.0 tables//",
          "-//microsoft//dtd internet explorer 3.0 html strict//",
          "-//microsoft//dtd internet explorer 3.0 html//",
          "-//microsoft//dtd internet explorer 3.0 tables//",
          "-//netscape comm. corp.//dtd html//",
          "-//netscape comm. corp.//dtd strict html//",
          "-//o'reilly and associates//dtd html 2.0//",
          "-//o'reilly and associates//dtd html extended 1.0//",
          "-//o'reilly and associates//dtd html extended relaxed 1.0//",
          "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
          "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
          "-//spyglass//dtd html 2.0 extended//",
          "-//sq//dtd html 2.0 hotmetal + extensions//",
          "-//sun microsystems corp.//dtd hotjava html//",
          "-//sun microsystems corp.//dtd hotjava strict html//",
          "-//w3c//dtd html 3 1995-03-24//",
          "-//w3c//dtd html 3.2 draft//",
          "-//w3c//dtd html 3.2 final//",
          "-//w3c//dtd html 3.2//",
          "-//w3c//dtd html 3.2s draft//",
          "-//w3c//dtd html 4.0 frameset//",
          "-//w3c//dtd html 4.0 transitional//",
          "-//w3c//dtd html experimental 19960712//",
          "-//w3c//dtd html experimental 970421//",
          "-//w3c//dtd w3 html//",
          "-//w3o//dtd w3 html 3.0//",
          "-//webtechs//dtd mozilla html 2.0//",
          "-//webtechs//dtd mozilla html//"])
        || const ["-//w3o//dtd w3 html strict 3.0//en//",
           "-/w3c/dtd html 4.0 transitional/en",
           "html"].indexOf(publicId) >= 0
        || startsWithAny(publicId, const [
           "-//w3c//dtd html 4.01 frameset//",
           "-//w3c//dtd html 4.01 transitional//"]) && systemId == null
        || systemId != null && systemId.toLowerCase() ==
           "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd") {

      parser.compatMode = "quirks";
    } else if (startsWithAny(publicId, const [
          "-//w3c//dtd xhtml 1.0 frameset//",
          "-//w3c//dtd xhtml 1.0 transitional//"])
        || startsWithAny(publicId, const [
          "-//w3c//dtd html 4.01 frameset//",
          "-//w3c//dtd html 4.01 transitional//"]) &&
          systemId != null) {
      parser.compatMode = "limited quirks";
    }
    parser.phase = parser._beforeHtmlPhase;
  }

  void anythingElse() {
    parser.compatMode = "quirks";
    parser.phase = parser._beforeHtmlPhase;
  }

  Token processCharacters(CharactersToken token) {
    parser.parseError("expected-doctype-but-got-chars");
    anythingElse();
    return token;
  }

  Token processStartTag(StartTagToken token) {
    parser.parseError("expected-doctype-but-got-start-tag",
        {"name": token.name});
    anythingElse();
    return token;
  }

  Token processEndTag(EndTagToken token) {
    parser.parseError("expected-doctype-but-got-end-tag",
        {"name": token.name});
    anythingElse();
    return token;
  }

  bool processEOF() {
    parser.parseError("expected-doctype-but-got-eof");
    anythingElse();
    return true;
  }
}


class BeforeHtmlPhase extends Phase {
  BeforeHtmlPhase(parser) : super(parser);

  // helper methods
  void insertHtmlElement() {
    tree.insertRoot(new StartTagToken("html", data: {}));
    parser.phase = parser._beforeHeadPhase;
  }

  // other
  bool processEOF() {
    insertHtmlElement();
    return true;
  }

  Token processComment(CommentToken token) {
    tree.insertComment(token, tree.document);
  }

  Token processSpaceCharacters(SpaceCharactersToken token) {
  }

  Token processCharacters(CharactersToken token) {
    insertHtmlElement();
    return token;
  }

  Token processStartTag(StartTagToken token) {
    if (token.name == "html") {
      parser.firstStartTag = true;
    }
    insertHtmlElement();
    return token;
  }

  Token processEndTag(EndTagToken token) {
    switch (token.name) {
      case "head": case "body": case "html": case "br":
        insertHtmlElement();
        return token;
      default:
        parser.parseError("unexpected-end-tag-before-html",
            {"name": token.name});
        return null;
    }
  }
}


class BeforeHeadPhase extends Phase {
  BeforeHeadPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case 'html': return startTagHtml(token);
      case 'head': return startTagHead(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "head": case "body": case "html": case "br":
        return endTagImplyHead(token);
      default: return endTagOther(token);
    }
  }

  bool processEOF() {
    startTagHead(new StartTagToken("head", data: {}));
    return true;
  }

  Token processSpaceCharacters(SpaceCharactersToken token) {
  }

  Token processCharacters(CharactersToken token) {
    startTagHead(new StartTagToken("head", data: {}));
    return token;
  }

  Token startTagHtml(StartTagToken token) {
    return parser._inBodyPhase.processStartTag(token);
  }

  void startTagHead(StartTagToken token) {
    tree.insertElement(token);
    tree.headPointer = tree.openElements.last();
    parser.phase = parser._inHeadPhase;
  }

  Token startTagOther(StartTagToken token) {
    startTagHead(new StartTagToken("head", data: {}));
    return token;
  }

  Token endTagImplyHead(EndTagToken token) {
    startTagHead(new StartTagToken("head", data: {}));
    return token;
  }

  void endTagOther(EndTagToken token) {
    parser.parseError("end-tag-after-implied-root",
        {"name": token.name});
  }
}

class InHeadPhase extends Phase {
  InHeadPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "title": return startTagTitle(token);
      case "noscript": case "noframes": case "style":
        return startTagNoScriptNoFramesStyle(token);
      case "script": return startTagScript(token);
      case "base": case "basefont": case "bgsound": case "command": case "link":
        return startTagBaseLinkCommand(token);
      case "meta": return startTagMeta(token);
      case "head": return startTagHead(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "head": return endTagHead(token);
      case "br": case "html": case "body": return endTagHtmlBodyBr(token);
      default: return endTagOther(token);
    }
  }

  // the real thing
  bool processEOF() {
    anythingElse();
    return true;
  }

  Token processCharacters(CharactersToken token) {
    anythingElse();
    return token;
  }

  Token startTagHtml(StartTagToken token) {
    return parser._inBodyPhase.processStartTag(token);
  }

  void startTagHead(StartTagToken token) {
    parser.parseError("two-heads-are-not-better-than-one");
  }

  void startTagBaseLinkCommand(StartTagToken token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
    token.selfClosingAcknowledged = true;
  }

  void startTagMeta(StartTagToken token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
    token.selfClosingAcknowledged = true;

    var attributes = token.data;
    if (!parser.tokenizer.stream.charEncodingCertain) {
      var charset = attributes["charset"];
      var content = attributes["content"];
      if (charset != null) {
        parser.tokenizer.stream.changeEncoding(charset);
      } else if (content != null) {
        var data = new EncodingBytes(content);
        var codec = new ContentAttrParser(data).parse();
        parser.tokenizer.stream.changeEncoding(codec);
      }
    }
  }

  void startTagTitle(StartTagToken token) {
    parser.parseRCDataRawtext(token, "RCDATA");
  }

  void startTagNoScriptNoFramesStyle(StartTagToken token) {
    // Need to decide whether to implement the scripting-disabled case
    parser.parseRCDataRawtext(token, "RAWTEXT");
  }

  void startTagScript(StartTagToken token) {
    tree.insertElement(token);
    parser.tokenizer.state = parser.tokenizer.scriptDataState;
    parser.originalPhase = parser.phase;
    parser.phase = parser._textPhase;
  }

  Token startTagOther(StartTagToken token) {
    anythingElse();
    return token;
  }

  void endTagHead(EndTagToken token) {
    var node = parser.tree.openElements.removeLast();
    assert(node.tagName == "head");
    parser.phase = parser._afterHeadPhase;
  }

  Token endTagHtmlBodyBr(EndTagToken token) {
    anythingElse();
    return token;
  }

  void endTagOther(EndTagToken token) {
    parser.parseError("unexpected-end-tag", {"name": token.name});
  }

  void anythingElse() {
    endTagHead(new EndTagToken("head", data: {}));
  }
}


// XXX If we implement a parser for which scripting is disabled we need to
// implement this phase.
//
// class InHeadNoScriptPhase extends Phase {

class AfterHeadPhase extends Phase {
  AfterHeadPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "body": return startTagBody(token);
      case "frameset": return startTagFrameset(token);
      case "base": case "basefont": case "bgsound": case "link": case "meta":
      case "noframes": case "script": case "style": case "title":
        return startTagFromHead(token);
      case "head": return startTagHead(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "body": case "html": case "br":
        return endTagHtmlBodyBr(token);
      default: return endTagOther(token);
    }
  }

  bool processEOF() {
    anythingElse();
    return true;
  }

  Token processCharacters(CharactersToken token) {
    anythingElse();
    return token;
  }

  Token startTagHtml(StartTagToken token) {
    return parser._inBodyPhase.processStartTag(token);
  }

  void startTagBody(StartTagToken token) {
    parser.framesetOK = false;
    tree.insertElement(token);
    parser.phase = parser._inBodyPhase;
  }

  void startTagFrameset(StartTagToken token) {
    tree.insertElement(token);
    parser.phase = parser._inFramesetPhase;
  }

  void startTagFromHead(StartTagToken token) {
    parser.parseError("unexpected-start-tag-out-of-my-head",
      {"name": token.name});
    tree.openElements.add(tree.headPointer);
    parser._inHeadPhase.processStartTag(token);
    for (Node node in reversed(tree.openElements)) {
      if (node.tagName == "head") {
        removeFromList(tree.openElements, node);
        break;
      }
    }
  }

  void startTagHead(StartTagToken token) {
    parser.parseError("unexpected-start-tag", {"name":token.name});
  }

  Token startTagOther(StartTagToken token) {
    anythingElse();
    return token;
  }

  Token endTagHtmlBodyBr(EndTagToken token) {
    anythingElse();
    return token;
  }

  void endTagOther(EndTagToken token) {
    parser.parseError("unexpected-end-tag", {"name":token.name});
  }

  void anythingElse() {
    tree.insertElement(new StartTagToken("body", data: {}));
    parser.phase = parser._inBodyPhase;
    parser.framesetOK = true;
  }
}

typedef Token TokenProccessor(Token token);

class InBodyPhase extends Phase {
  TokenProccessor processSpaceCharactersFunc;

  // http://www.whatwg.org/specs/web-apps/current-work///parsing-main-inbody
  // the really-really-really-very crazy mode
  InBodyPhase(parser) : super(parser) {
    //Keep a ref to this for special handling of whitespace in <pre>
    processSpaceCharactersFunc = processSpaceCharactersNonPre;
  }

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html":
        return startTagHtml(token);
      case "base": case "basefont": case "bgsound": case "command": case "link":
      case "meta": case "noframes": case "script": case "style": case "title":
        return startTagProcessInHead(token);
      case "body":
        return startTagBody(token);
      case "frameset":
        return startTagFrameset(token);
      case "address": case "article": case "aside": case "blockquote":
      case "center": case "details": case "details": case "dir": case "div":
      case "dl": case "fieldset": case "figcaption": case "figure":
      case "footer": case "header": case "hgroup": case "menu": case "nav":
      case "ol": case "p": case "section": case "summary": case "ul":
        return startTagCloseP(token);
      // headingElements
      case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
        return startTagHeading(token);
      case "pre": case "listing":
        return startTagPreListing(token);
      case "form":
        return startTagForm(token);
      case "li": case "dd": case "dt":
        return startTagListItem(token);
      case "plaintext":
        return startTagPlaintext(token);
      case "a": return startTagA(token);
      case "b": case "big": case "code": case "em": case "font": case "i":
      case "s": case "small": case "strike": case "strong": case "tt": case "u":
        return startTagFormatting(token);
      case "nobr":
        return startTagNobr(token);
      case "button":
        return startTagButton(token);
      case "applet": case "marquee": case "object":
        return startTagAppletMarqueeObject(token);
      case "xmp":
        return startTagXmp(token);
      case "table":
        return startTagTable(token);
      case "area": case "br": case "embed": case "img": case "keygen":
      case "wbr":
        return startTagVoidFormatting(token);
      case "param": case "source": case "track":
        return startTagParamSource(token);
      case "input":
        return startTagInput(token);
      case "hr":
        return startTagHr(token);
      case "image":
        return startTagImage(token);
      case "isindex":
        return startTagIsIndex(token);
      case "textarea":
        return startTagTextarea(token);
      case "iframe":
        return startTagIFrame(token);
      case "noembed": case "noframes": case "noscript":
        return startTagRawtext(token);
      case "select":
        return startTagSelect(token);
      case "rp": case "rt":
        return startTagRpRt(token);
      case "option": case "optgroup":
        return startTagOpt(token);
      case "math":
        return startTagMath(token);
      case "svg":
        return startTagSvg(token);
      case "caption": case "col": case "colgroup": case "frame": case "head":
      case "tbody": case "td": case "tfoot": case "th": case "thead": case "tr":
        return startTagMisplaced(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "body": return endTagBody(token);
      case "html": return endTagHtml(token);
      case "address": case "article": case "aside": case "blockquote":
      case "center": case "details": case "dir": case "div": case "dl":
      case "fieldset": case "figcaption": case "figure": case "footer":
      case "header": case "hgroup": case "listing": case "menu": case "nav":
      case "ol": case "pre": case "section": case "summary": case "ul":
        return endTagBlock(token);
      case "form": return endTagForm(token);
      case "p": return endTagP(token);
      case "dd": case "dt": case "li": return endTagListItem(token);
      // headingElements
      case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
        return endTagHeading(token);
      case "a": case "b": case "big": case "code": case "em": case "font":
      case "i": case "nobr": case "s": case "small": case "strike":
      case "strong": case "tt": case "u":
        return endTagFormatting(token);
      case "applet": case "marquee": case "object":
        return endTagAppletMarqueeObject(token);
      case "br": return endTagBr(token);
        default: return endTagOther(token);
    }
  }

  bool isMatchingFormattingElement(Node node1, Node node2) {
    if (node1.tagName != node2.tagName || node1.namespace != node2.namespace) {
      return false;
    } else if (node1.attributes.length != node2.attributes.length) {
      return false;
    } else {
      for (var key in node1.attributes.getKeys()) {
        if (node1.attributes[key] != node2.attributes[key]) {
          return false;
        }
      }
    }
    return true;
  }

  // helper
  void addFormattingElement(token) {
    tree.insertElement(token);
    var element = tree.openElements.last();

    var matchingElements = [];
    for (Node node in reversed(tree.activeFormattingElements)) {
      if (node === Marker) {
        break;
      } else if (isMatchingFormattingElement(node, element)) {
        matchingElements.add(node);
      }
    }

    assert(matchingElements.length <= 3);
    if (matchingElements.length == 3) {
      removeFromList(tree.activeFormattingElements, matchingElements.last());
    }
    tree.activeFormattingElements.add(element);
  }

  // the real deal
  bool processEOF() {
    for (Node node in reversed(tree.openElements)) {
      switch (node.tagName) {
        case "dd": case "dt": case "li": case "p": case "tbody": case "td":
        case "tfoot": case "th": case "thead": case "tr": case "body":
        case "html":
          continue;
      }
      parser.parseError("expected-closing-tag-but-got-eof");
      break;
    }
    //Stop parsing
    return false;
  }

  Token processSpaceCharactersDropNewline(token) {
    // Sometimes (start of <pre>, <listing>, and <textarea> blocks) we
    // want to drop leading newlines
    var data = token.data;
    processSpaceCharactersFunc = processSpaceCharactersNonPre;
    if (data.startsWith("\n")) {
      var lastOpen = tree.openElements.last();
      if (const ["pre", "listing", "textarea"].indexOf(lastOpen.tagName) >= 0
          && !lastOpen.hasContent()) {
        data = data.substring(1);
      }
    }
    if (data.length > 0) {
      tree.reconstructActiveFormattingElements();
      tree.insertText(data);
    }
  }

  Token processCharacters(CharactersToken token) {
    if (token.data == "\u0000") {
      //The tokenizer should always emit null on its own
      return null;
    }
    tree.reconstructActiveFormattingElements();
    tree.insertText(token.data);
    if (parser.framesetOK && !allWhitespace(token.data)) {
      parser.framesetOK = false;
    }
  }

  Token processSpaceCharactersNonPre(token) {
    tree.reconstructActiveFormattingElements();
    tree.insertText(token.data);
  }

  Token processSpaceCharacters(token) => processSpaceCharactersFunc(token);

  Token startTagProcessInHead(StartTagToken token) {
    return parser._inHeadPhase.processStartTag(token);
  }

  void startTagBody(StartTagToken token) {
    parser.parseError("unexpected-start-tag", {"name": "body"});
    if (tree.openElements.length == 1
        || tree.openElements[1].tagName != "body") {
      assert(parser.innerHTMLMode);
    } else {
      parser.framesetOK = false;
      token.data.forEach((attr, value) {
        tree.openElements[1].attributes.putIfAbsent(attr, () => value);
      });
    }
  }

  void startTagFrameset(StartTagToken token) {
    parser.parseError("unexpected-start-tag", {"name": "frameset"});
    if ((tree.openElements.length == 1 ||
        tree.openElements[1].tagName != "body")) {
      assert(parser.innerHTMLMode);
    } else if (parser.framesetOK) {
      if (tree.openElements[1].parent != null) {
        tree.openElements[1].parent.$dom_removeChild(tree.openElements[1]);
      }
      while (tree.openElements.last().tagName != "html") {
        tree.openElements.removeLast();
      }
      tree.insertElement(token);
      parser.phase = parser._inFramesetPhase;
    }
  }

  void startTagCloseP(StartTagToken token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(new EndTagToken("p", data: {}));
    }
    tree.insertElement(token);
  }

  void startTagPreListing(StartTagToken token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(new EndTagToken("p", data: {}));
    }
    tree.insertElement(token);
    parser.framesetOK = false;
    processSpaceCharactersFunc = processSpaceCharactersDropNewline;
  }

  void startTagForm(StartTagToken token) {
    if (tree.formPointer != null) {
      parser.parseError("unexpected-start-tag", {"name": "form"});
    } else {
      if (tree.elementInScope("p", variant: "button")) {
        endTagP(new EndTagToken("p", data: {}));
      }
      tree.insertElement(token);
      tree.formPointer = tree.openElements.last();
    }
  }

  void startTagListItem(StartTagToken token) {
    parser.framesetOK = false;

    final stopNamesMap = const {"li": const ["li"],
                                "dt": const ["dt", "dd"],
                                "dd": const ["dt", "dd"]};
    var stopNames = stopNamesMap[token.name];
    for (Node node in reversed(tree.openElements)) {
      if (stopNames.indexOf(node.tagName) >= 0) {
        parser.phase.processEndTag(new EndTagToken(node.tagName, data: {}));
        break;
      }
      if (specialElements.indexOf(node.nameTuple) >= 0 &&
          const ["address", "div", "p"].indexOf(node.tagName) == -1) {
        break;
      }
    }

    if (tree.elementInScope("p", variant: "button")) {
      parser.phase.processEndTag(new EndTagToken("p", data: {}));
    }

    tree.insertElement(token);
  }

  void startTagPlaintext(StartTagToken token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(new EndTagToken("p", data: {}));
    }
    tree.insertElement(token);
    parser.tokenizer.state = parser.tokenizer.plaintextState;
  }

  void startTagHeading(StartTagToken token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(new EndTagToken("p", data: {}));
    }
    if (headingElements.indexOf(tree.openElements.last().tagName) >= 0) {
      parser.parseError("unexpected-start-tag", {"name": token.name});
      tree.openElements.removeLast();
    }
    tree.insertElement(token);
  }

  void startTagA(StartTagToken token) {
    var afeAElement = tree.elementInActiveFormattingElements("a");
    if (afeAElement != null) {
      parser.parseError("unexpected-start-tag-implies-end-tag",
          {"startName": "a", "endName": "a"});
      endTagFormatting(new EndTagToken("a", data: {}));
      removeFromList(tree.openElements, afeAElement);
      removeFromList(tree.activeFormattingElements, afeAElement);
    }
    tree.reconstructActiveFormattingElements();
    addFormattingElement(token);
  }

  void startTagFormatting(StartTagToken token) {
    tree.reconstructActiveFormattingElements();
    addFormattingElement(token);
  }

  void startTagNobr(StartTagToken token) {
    tree.reconstructActiveFormattingElements();
    if (tree.elementInScope("nobr")) {
      parser.parseError("unexpected-start-tag-implies-end-tag",
        {"startName": "nobr", "endName": "nobr"});
      processEndTag(new EndTagToken("nobr", data: {}));
      // XXX Need tests that trigger the following
      tree.reconstructActiveFormattingElements();
    }
    addFormattingElement(token);
  }

  Token startTagButton(StartTagToken token) {
    if (tree.elementInScope("button")) {
      parser.parseError("unexpected-start-tag-implies-end-tag",
        {"startName": "button", "endName": "button"});
      processEndTag(new EndTagToken("button", data: {}));
      return token;
    } else {
      tree.reconstructActiveFormattingElements();
      tree.insertElement(token);
      parser.framesetOK = false;
    }
  }

  void startTagAppletMarqueeObject(StartTagToken token) {
    tree.reconstructActiveFormattingElements();
    tree.insertElement(token);
    tree.activeFormattingElements.add(Marker);
    parser.framesetOK = false;
  }

  void startTagXmp(StartTagToken token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(new EndTagToken("p", data: {}));
    }
    tree.reconstructActiveFormattingElements();
    parser.framesetOK = false;
    parser.parseRCDataRawtext(token, "RAWTEXT");
  }

  void startTagTable(StartTagToken token) {
    if (parser.compatMode != "quirks") {
      if (tree.elementInScope("p", variant: "button")) {
        processEndTag(new EndTagToken("p", data: {}));
      }
    }
    tree.insertElement(token);
    parser.framesetOK = false;
    parser.phase = parser._inTablePhase;
  }

  void startTagVoidFormatting(StartTagToken token) {
    tree.reconstructActiveFormattingElements();
    tree.insertElement(token);
    tree.openElements.removeLast();
    token.selfClosingAcknowledged = true;
    parser.framesetOK = false;
  }

  void startTagInput(StartTagToken token) {
    var savedFramesetOK = parser.framesetOK;
    startTagVoidFormatting(token);
    if (asciiUpper2Lower(token.data["type"]) == "hidden") {
      //input type=hidden doesn't change framesetOK
      parser.framesetOK = savedFramesetOK;
    }
  }

  void startTagParamSource(StartTagToken token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
    token.selfClosingAcknowledged = true;
  }

  void startTagHr(StartTagToken token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(new EndTagToken("p", data: {}));
    }
    tree.insertElement(token);
    tree.openElements.removeLast();
    token.selfClosingAcknowledged = true;
    parser.framesetOK = false;
  }

  void startTagImage(StartTagToken token) {
    // No really...
    parser.parseError("unexpected-start-tag-treated-as",
        {"originalName": "image", "newName": "img"});
    processStartTag(new StartTagToken("img", data: token.data,
        selfClosing: token.selfClosing));
  }

  void startTagIsIndex(StartTagToken token) {
    parser.parseError("deprecated-tag", {"name": "isindex"});
    if (tree.formPointer != null) {
      return;
    }
    var formAttrs = {};
    var dataAction = token.data["action"];
    if (dataAction != null) {
      formAttrs["action"] = dataAction;
    }
    processStartTag(new StartTagToken("form", data: formAttrs));
    processStartTag(new StartTagToken("hr", data: {}));
    processStartTag(new StartTagToken("label", data: {}));
    // XXX Localization ...
    var prompt = token.data["prompt"];
    if (prompt == null) {
      prompt = "This is a searchable index. Enter search keywords: ";
    }
    processCharacters(new CharactersToken(prompt));
    var attributes = new Map.from(token.data);
    attributes.remove('action');
    attributes.remove('prompt');
    attributes["name"] = "isindex";
    processStartTag(new StartTagToken("input",
                    data: attributes, selfClosing: token.selfClosing));
    processEndTag(new EndTagToken("label", data: {}));
    processStartTag(new StartTagToken("hr", data: {}));
    processEndTag(new EndTagToken("form", data: {}));
  }

  void startTagTextarea(StartTagToken token) {
    tree.insertElement(token);
    parser.tokenizer.state = parser.tokenizer.rcdataState;
    processSpaceCharactersFunc = processSpaceCharactersDropNewline;
    parser.framesetOK = false;
  }

  void startTagIFrame(StartTagToken token) {
    parser.framesetOK = false;
    startTagRawtext(token);
  }

  /** iframe, noembed noframes, noscript(if scripting enabled). */
  void startTagRawtext(StartTagToken token) {
    parser.parseRCDataRawtext(token, "RAWTEXT");
  }

  void startTagOpt(StartTagToken token) {
    if (tree.openElements.last().tagName == "option") {
      parser.phase.processEndTag(new EndTagToken("option", data: {}));
    }
    tree.reconstructActiveFormattingElements();
    parser.tree.insertElement(token);
  }

  void startTagSelect(StartTagToken token) {
    tree.reconstructActiveFormattingElements();
    tree.insertElement(token);
    parser.framesetOK = false;

    if (parser._inTablePhase == parser.phase ||
        parser._inCaptionPhase == parser.phase ||
        parser._inColumnGroupPhase == parser.phase ||
        parser._inTableBodyPhase == parser.phase ||
        parser._inRowPhase == parser.phase ||
        parser._inCellPhase == parser.phase) {
      parser.phase = parser._inSelectInTablePhase;
    } else {
      parser.phase = parser._inSelectPhase;
    }
  }

  void startTagRpRt(StartTagToken token) {
    if (tree.elementInScope("ruby")) {
      tree.generateImpliedEndTags();
      if (tree.openElements.last().tagName != "ruby") {
        parser.parseError();
      }
    }
    tree.insertElement(token);
  }

  void startTagMath(StartTagToken token) {
    tree.reconstructActiveFormattingElements();
    parser.adjustMathMLAttributes(token);
    parser.adjustForeignAttributes(token);
    token.namespace = Namespaces.mathml;
    tree.insertElement(token);
    //Need to get the parse error right for the case where the token
    //has a namespace not equal to the xmlns attribute
    if (token.selfClosing) {
      tree.openElements.removeLast();
      token.selfClosingAcknowledged = true;
    }
  }

  void startTagSvg(StartTagToken token) {
    tree.reconstructActiveFormattingElements();
    parser.adjustSVGAttributes(token);
    parser.adjustForeignAttributes(token);
    token.namespace = Namespaces.svg;
    tree.insertElement(token);
    //Need to get the parse error right for the case where the token
    //has a namespace not equal to the xmlns attribute
    if (token.selfClosing) {
      tree.openElements.removeLast();
      token.selfClosingAcknowledged = true;
    }
  }

  /**
   * Elements that should be children of other elements that have a
   * different insertion mode; here they are ignored
   * "caption", "col", "colgroup", "frame", "frameset", "head",
   * "option", "optgroup", "tbody", "td", "tfoot", "th", "thead",
   * "tr", "noscript"
  */
  void startTagMisplaced(StartTagToken token) {
    parser.parseError("unexpected-start-tag-ignored",
        {"name": token.name});
  }

  Token startTagOther(StartTagToken token) {
    tree.reconstructActiveFormattingElements();
    tree.insertElement(token);
  }

  void endTagP(EndTagToken token) {
    if (!tree.elementInScope("p", variant: "button")) {
      startTagCloseP(new StartTagToken("p", data: {}));
      parser.parseError("unexpected-end-tag", {"name": "p"});
      endTagP(new EndTagToken("p", data: {}));
    } else {
      tree.generateImpliedEndTags("p");
      if (tree.openElements.last().tagName != "p") {
        parser.parseError("unexpected-end-tag", {"name": "p"});
      }
      popOpenElementsUntil("p");
    }
  }

  void endTagBody(EndTagToken token) {
    if (!tree.elementInScope("body")) {
      parser.parseError();
      return;
    } else if (tree.openElements.last().tagName != "body") {
      for (Node node in slice(tree.openElements, 2)) {
        switch (node.tagName) {
          case "dd": case "dt": case "li": case "optgroup": case "option":
          case "p": case "rp": case "rt": case "tbody": case "td": case "tfoot":
          case "th": case "thead": case "tr": case "body": case "html":
            continue;
        }
        // Not sure this is the correct name for the parse error
        parser.parseError("expected-one-end-tag-but-got-another",
            {"expectedName": "body", "gotName": node.tagName});
        break;
      }
    }
    parser.phase = parser._afterBodyPhase;
  }

  Token endTagHtml(EndTagToken token) {
    //We repeat the test for the body end tag token being ignored here
    if (tree.elementInScope("body")) {
      endTagBody(new EndTagToken("body", data: {}));
      return token;
    }
  }

  void endTagBlock(EndTagToken token) {
    //Put us back in the right whitespace handling mode
    if (token.name == "pre") {
      processSpaceCharactersFunc = processSpaceCharactersNonPre;
    }
    var inScope = tree.elementInScope(token.name);
    if (inScope) {
      tree.generateImpliedEndTags();
    }
    if (tree.openElements.last().tagName != token.name) {
      parser.parseError("end-tag-too-early", {"name": token.name});
    }
    if (inScope) {
      popOpenElementsUntil(token.name);
    }
  }

  void endTagForm(EndTagToken token) {
    var node = tree.formPointer;
    tree.formPointer = null;
    if (node === null || !tree.elementInScope(node)) {
      parser.parseError("unexpected-end-tag", {"name": "form"});
    } else {
      tree.generateImpliedEndTags();
      if (tree.openElements.last() != node) {
        parser.parseError("end-tag-too-early-ignored", {"name": "form"});
      }
      removeFromList(tree.openElements, node);
    }
  }

  void endTagListItem(EndTagToken token) {
    var variant;
    if (token.name == "li") {
      variant = "list";
    } else {
      variant = null;
    }
    if (!tree.elementInScope(token.name, variant: variant)) {
      parser.parseError("unexpected-end-tag", {"name": token.name});
    } else {
      tree.generateImpliedEndTags(exclude: token.name);
      if (tree.openElements.last().tagName != token.name) {
        parser.parseError("end-tag-too-early", {"name": token.name});
      }
      popOpenElementsUntil(token.name);
    }
  }

  void endTagHeading(EndTagToken token) {
    for (var item in headingElements) {
      if (tree.elementInScope(item)) {
        tree.generateImpliedEndTags();
        break;
      }
    }
    if (tree.openElements.last().tagName != token.name) {
      parser.parseError("end-tag-too-early", {"name": token.name});
    }

    for (var item in headingElements) {
      if (tree.elementInScope(item)) {
        item = tree.openElements.removeLast();
        while (headingElements.indexOf(item.tagName) == -1) {
          item = tree.openElements.removeLast();
        }
        break;
      }
    }
  }

  /** The much-feared adoption agency algorithm. */
  endTagFormatting(EndTagToken token) {
    // http://www.whatwg.org/specs/web-apps/current-work/multipage/tree-construction.html#adoptionAgency
    // TODO(jmesserly): the comments here don't match the numbered steps in the
    // updated spec. This needs a pass over it to verify that it still matches.
    // In particular the html5lib Python code skiped "step 4", I'm not sure why.
    // XXX Better parseError messages appreciated.
    int outerLoopCounter = 0;
    while (outerLoopCounter < 8) {
      outerLoopCounter += 1;

      // Step 1 paragraph 1
      var formattingElement = tree.elementInActiveFormattingElements(
          token.name);
      if (formattingElement == null ||
          (tree.openElements.indexOf(formattingElement) >= 0 &&
           !tree.elementInScope(formattingElement.tagName))) {
        parser.parseError("adoption-agency-1.1", {"name": token.name});
        return;
      // Step 1 paragraph 2
      } else if (tree.openElements.indexOf(formattingElement) == -1) {
        parser.parseError("adoption-agency-1.2", {"name": token.name});
        removeFromList(tree.activeFormattingElements, formattingElement);
        return;
      }

      // Step 1 paragraph 3
      if (formattingElement != tree.openElements.last()) {
        parser.parseError("adoption-agency-1.3", {"name": token.name});
      }

      // Step 2
      // Start of the adoption agency algorithm proper
      var afeIndex = tree.openElements.indexOf(formattingElement);
      Node furthestBlock = null;
      for (Node element in slice(tree.openElements, afeIndex)) {
        if (specialElements.indexOf(element.nameTuple) >= 0) {
          furthestBlock = element;
          break;
        }
      }
      // Step 3
      if (furthestBlock === null) {
        var element = tree.openElements.removeLast();
        while (element != formattingElement) {
          element = tree.openElements.removeLast();
        }
        removeFromList(tree.activeFormattingElements, element);
        return;
      }

      var commonAncestor = tree.openElements[afeIndex - 1];

      // Step 5
      // The bookmark is supposed to help us identify where to reinsert
      // nodes in step 12. We have to ensure that we reinsert nodes after
      // the node before the active formatting element. Note the bookmark
      // can move in step 7.4
      var bookmark = tree.activeFormattingElements.indexOf(formattingElement);

      // Step 6
      Node lastNode = furthestBlock;
      var node = furthestBlock;
      int innerLoopCounter = 0;

      var index = tree.openElements.indexOf(node);
      while (innerLoopCounter < 3) {
        innerLoopCounter += 1;

        // Node is element before node in open elements
        index -= 1;
        node = tree.openElements[index];
        if (tree.activeFormattingElements.indexOf(node) == -1) {
          removeFromList(tree.openElements, node);
          continue;
        }
        // Step 6.3
        if (node == formattingElement) {
          break;
        }
        // Step 6.4
        if (lastNode == furthestBlock) {
          bookmark = (tree.activeFormattingElements.indexOf(node) + 1);
        }
        // Step 6.5
        //cite = node.parent
        var clone = node.clone();
        // Replace node with clone
        tree.activeFormattingElements[
            tree.activeFormattingElements.indexOf(node)] = clone;
        tree.openElements[tree.openElements.indexOf(node)] = clone;
        node = clone;

        // Step 6.6
        // Remove lastNode from its parents, if any
        if (lastNode.parent != null) {
          lastNode.parent.$dom_removeChild(lastNode);
        }
        node.$dom_appendChild(lastNode);
        // Step 7.7
        lastNode = node;
        // End of inner loop
      }

      // Step 7
      // Foster parent lastNode if commonAncestor is a
      // table, tbody, tfoot, thead, or tr we need to foster parent the
      // lastNode
      if (lastNode.parent != null) {
        lastNode.parent.$dom_removeChild(lastNode);
      }

      if (const ["table", "tbody", "tfoot", "thead", "tr"].indexOf(
          commonAncestor.tagName) >= 0) {
        var nodePos = tree.getTableMisnestedNodePosition();
        nodePos[0].insertBefore(lastNode, nodePos[1]);
      } else {
        commonAncestor.$dom_appendChild(lastNode);
      }

      // Step 8
      var clone = formattingElement.clone();

      // Step 9
      furthestBlock.reparentChildren(clone);

      // Step 10
      furthestBlock.$dom_appendChild(clone);

      // Step 11
      removeFromList(tree.activeFormattingElements, formattingElement);
      tree.activeFormattingElements.insertRange(
          min(bookmark, tree.activeFormattingElements.length), 1, clone);

      // Step 12
      removeFromList(tree.openElements, formattingElement);
      tree.openElements.insertRange(
          tree.openElements.indexOf(furthestBlock) + 1, 1, clone);
    }
  }

  void endTagAppletMarqueeObject(EndTagToken token) {
    if (tree.elementInScope(token.name)) {
      tree.generateImpliedEndTags();
    }
    if (tree.openElements.last().tagName != token.name) {
      parser.parseError("end-tag-too-early", {"name": token.name});
    }
    if (tree.elementInScope(token.name)) {
      popOpenElementsUntil(token.name);
      tree.clearActiveFormattingElements();
    }
  }

  void endTagBr(EndTagToken token) {
    parser.parseError("unexpected-end-tag-treated-as",
        {"originalName": "br", "newName": "br element"});
    tree.reconstructActiveFormattingElements();
    tree.insertElement(new StartTagToken("br", data: {}));
    tree.openElements.removeLast();
  }

  void endTagOther(EndTagToken token) {
    for (Node node in reversed(tree.openElements)) {
      if (node.tagName == token.name) {
        tree.generateImpliedEndTags(exclude: token.name);
        if (tree.openElements.last().tagName != token.name) {
          parser.parseError("unexpected-end-tag", {"name": token.name});
        }
        while (tree.openElements.removeLast() != node);
        break;
      } else {
        if (specialElements.indexOf(node.nameTuple) >= 0) {
          parser.parseError("unexpected-end-tag", {"name": token.name});
          break;
        }
      }
    }
  }
}


class TextPhase extends Phase {
  TextPhase(parser) : super(parser);

  // "Tried to process start tag %s in RCDATA/RAWTEXT mode"%token.name
  processStartTag(StartTagToken token) { assert(false); }

  processEndTag(EndTagToken token) {
    if (token.name == 'script') return endTagScript(token);
    return endTagOther(token);
  }

  Token processCharacters(CharactersToken token) {
    tree.insertText(token.data);
  }

  bool processEOF() {
    parser.parseError("expected-named-closing-tag-but-got-eof",
        {'name': tree.openElements.last().tagName});
    tree.openElements.removeLast();
    parser.phase = parser.originalPhase;
    return true;
  }

  void endTagScript(EndTagToken token) {
    var node = tree.openElements.removeLast();
    assert(node.tagName == "script");
    parser.phase = parser.originalPhase;
    //The rest of this method is all stuff that only happens if
    //document.write works
  }

  void endTagOther(EndTagToken token) {
    var node = tree.openElements.removeLast();
    parser.phase = parser.originalPhase;
  }
}

class InTablePhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-table
  InTablePhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "caption": return startTagCaption(token);
      case "colgroup": return startTagColgroup(token);
      case "col": return startTagCol(token);
      case "tbody": case "tfoot": case "thead": return startTagRowGroup(token);
      case "td": case "th": case "tr": return startTagImplyTbody(token);
      case "table": return startTagTable(token);
      case "style": case "script": return startTagStyleScript(token);
      case "input": return startTagInput(token);
      case "form": return startTagForm(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "table": return endTagTable(token);
      case "body": case "caption": case "col": case "colgroup": case "html":
      case "tbody": case "td": case "tfoot": case "th": case "thead": case "tr":
        return endTagIgnore(token);
      default: return endTagOther(token);
    }
  }

  // helper methods
  void clearStackToTableContext() {
    // "clear the stack back to a table context"
    while (tree.openElements.last().tagName != "table" &&
           tree.openElements.last().tagName != "html") {
      //parser.parseError("unexpected-implied-end-tag-in-table",
      //  {"name":  tree.openElements.last().name})
      tree.openElements.removeLast();
    }
    // When the current node is <html> it's an innerHTML case
  }

  // processing methods
  bool processEOF() {
    if (tree.openElements.last().tagName != "html") {
      parser.parseError("eof-in-table");
    } else {
      assert(parser.innerHTMLMode);
    }
    //Stop parsing
    return false;
  }

  Token processSpaceCharacters(SpaceCharactersToken token) {
    var originalPhase = parser.phase;
    parser.phase = parser._inTableTextPhase;
    parser._inTableTextPhase.originalPhase = originalPhase;
    parser.phase.processSpaceCharacters(token);
  }

  Token processCharacters(CharactersToken token) {
    var originalPhase = parser.phase;
    parser.phase = parser._inTableTextPhase;
    parser._inTableTextPhase.originalPhase = originalPhase;
    parser.phase.processCharacters(token);
  }

  void insertText(CharactersToken token) {
    // If we get here there must be at least one non-whitespace character
    // Do the table magic!
    tree.insertFromTable = true;
    parser._inBodyPhase.processCharacters(token);
    tree.insertFromTable = false;
  }

  void startTagCaption(StartTagToken token) {
    clearStackToTableContext();
    tree.activeFormattingElements.add(Marker);
    tree.insertElement(token);
    parser.phase = parser._inCaptionPhase;
  }

  void startTagColgroup(StartTagToken token) {
    clearStackToTableContext();
    tree.insertElement(token);
    parser.phase = parser._inColumnGroupPhase;
  }

  Token startTagCol(StartTagToken token) {
    startTagColgroup(new StartTagToken("colgroup", data: {}));
    return token;
  }

  void startTagRowGroup(StartTagToken token) {
    clearStackToTableContext();
    tree.insertElement(token);
    parser.phase = parser._inTableBodyPhase;
  }

  Token startTagImplyTbody(StartTagToken token) {
    startTagRowGroup(new StartTagToken("tbody", data: {}));
    return token;
  }

  Token startTagTable(StartTagToken token) {
    parser.parseError("unexpected-start-tag-implies-end-tag",
        {"startName": "table", "endName": "table"});
    parser.phase.processEndTag(new EndTagToken("table", data: {}));
    if (!parser.innerHTMLMode) {
      return token;
    }
  }

  Token startTagStyleScript(StartTagToken token) {
    return parser._inHeadPhase.processStartTag(token);
  }

  void startTagInput(StartTagToken token) {
    if (asciiUpper2Lower(token.data["type"]) == "hidden") {
      parser.parseError("unexpected-hidden-input-in-table");
      tree.insertElement(token);
      // XXX associate with form
      tree.openElements.removeLast();
    } else {
      startTagOther(token);
    }
  }

  void startTagForm(StartTagToken token) {
    parser.parseError("unexpected-form-in-table");
    if (tree.formPointer === null) {
      tree.insertElement(token);
      tree.formPointer = tree.openElements.last();
      tree.openElements.removeLast();
    }
  }

  void startTagOther(StartTagToken token) {
    parser.parseError("unexpected-start-tag-implies-table-voodoo",
        {"name": token.name});
    // Do the table magic!
    tree.insertFromTable = true;
    parser._inBodyPhase.processStartTag(token);
    tree.insertFromTable = false;
  }

  void endTagTable(EndTagToken token) {
    if (tree.elementInScope("table", variant: "table")) {
      tree.generateImpliedEndTags();
      if (tree.openElements.last().tagName != "table") {
        parser.parseError("end-tag-too-early-named", {"gotName": "table",
            "expectedName": tree.openElements.last().tagName});
      }
      while (tree.openElements.last().tagName != "table") {
        tree.openElements.removeLast();
      }
      tree.openElements.removeLast();
      parser.resetInsertionMode();
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
  }

  void endTagIgnore(EndTagToken token) {
    parser.parseError("unexpected-end-tag", {"name": token.name});
  }

  void endTagOther(EndTagToken token) {
    parser.parseError("unexpected-end-tag-implies-table-voodoo",
        {"name": token.name});
    // Do the table magic!
    tree.insertFromTable = true;
    parser._inBodyPhase.processEndTag(token);
    tree.insertFromTable = false;
  }
}

class InTableTextPhase extends Phase {
  Phase originalPhase;
  List<StringToken> characterTokens;

  InTableTextPhase(parser)
      : characterTokens = <StringToken>[],
        super(parser);

  void flushCharacters() {
    var data = joinStr(characterTokens.map((t) => t.data));
    if (!allWhitespace(data)) {
      parser._inTablePhase.insertText(new CharactersToken(data));
    } else if (data.length > 0) {
      tree.insertText(data);
    }
    characterTokens = <StringToken>[];
  }

  Token processComment(CommentToken token) {
    flushCharacters();
    parser.phase = originalPhase;
    return token;
  }

  bool processEOF() {
    flushCharacters();
    parser.phase = originalPhase;
    return true;
  }

  Token processCharacters(CharactersToken token) {
    if (token.data == "\u0000") {
      return null;
    }
    characterTokens.add(token);
  }

  Token processSpaceCharacters(SpaceCharactersToken token) {
    //pretty sure we should never reach here
    characterTokens.add(token);
    // XXX assert(false);
  }

  Token processStartTag(StartTagToken token) {
    flushCharacters();
    parser.phase = originalPhase;
    return token;
  }

  Token processEndTag(EndTagToken token) {
    flushCharacters();
    parser.phase = originalPhase;
    return token;
  }
}


class InCaptionPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-caption
  InCaptionPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "caption": case "col": case "colgroup": case "tbody": case "td":
      case "tfoot": case "th": case "thead": case "tr":
        return startTagTableElement(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "caption": return endTagCaption(token);
      case "table": return endTagTable(token);
      case "body": case "col": case "colgroup": case "html": case "tbody":
      case "td": case "tfoot": case "th": case "thead": case "tr":
        return endTagIgnore(token);
      default: return endTagOther(token);
    }
  }

  bool ignoreEndTagCaption() {
    return !tree.elementInScope("caption", variant: "table");
  }

  bool processEOF() {
    parser._inBodyPhase.processEOF();
    return false;
  }

  Token processCharacters(CharactersToken token) {
    return parser._inBodyPhase.processCharacters(token);
  }

  Token startTagTableElement(StartTagToken token) {
    parser.parseError();
    //XXX Have to duplicate logic here to find out if the tag is ignored
    var ignoreEndTag = ignoreEndTagCaption();
    parser.phase.processEndTag(new EndTagToken("caption", data: {}));
    if (!ignoreEndTag) {
      return token;
    }
    return null;
  }

  Token startTagOther(StartTagToken token) {
    return parser._inBodyPhase.processStartTag(token);
  }

  void endTagCaption(EndTagToken token) {
    if (!ignoreEndTagCaption()) {
      // AT this code is quite similar to endTagTable in "InTable"
      tree.generateImpliedEndTags();
      if (tree.openElements.last().tagName != "caption") {
        parser.parseError("expected-one-end-tag-but-got-another",
          {"gotName": "caption",
           "expectedName": tree.openElements.last().tagName});
      }
      while (tree.openElements.last().tagName != "caption") {
        tree.openElements.removeLast();
      }
      tree.openElements.removeLast();
      tree.clearActiveFormattingElements();
      parser.phase = parser._inTablePhase;
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
  }

  Token endTagTable(EndTagToken token) {
    parser.parseError();
    var ignoreEndTag = ignoreEndTagCaption();
    parser.phase.processEndTag(new EndTagToken("caption", data: {}));
    if (!ignoreEndTag) {
      return token;
    }
    return null;
  }

  void endTagIgnore(EndTagToken token) {
    parser.parseError("unexpected-end-tag", {"name": token.name});
  }

  Token endTagOther(EndTagToken token) {
    return parser._inBodyPhase.processEndTag(token);
  }
}


class InColumnGroupPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-column
  InColumnGroupPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "col": return startTagCol(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "colgroup": return endTagColgroup(token);
      case "col": return endTagCol(token);
      default: return endTagOther(token);
    }
  }

  bool ignoreEndTagColgroup() {
    return tree.openElements.last().tagName == "html";
  }

  bool processEOF() {
    var ignoreEndTag = ignoreEndTagColgroup();
    if (ignoreEndTag) {
      assert(parser.innerHTMLMode);
      return false;
    } else {
      endTagColgroup(new EndTagToken("colgroup", data: {}));
      return true;
    }
  }

  Token processCharacters(CharactersToken token) {
    var ignoreEndTag = ignoreEndTagColgroup();
    endTagColgroup(new EndTagToken("colgroup", data: {}));
    return ignoreEndTag ? null : token;
  }

  void startTagCol(StartTagToken token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
  }

  Token startTagOther(StartTagToken token) {
    var ignoreEndTag = ignoreEndTagColgroup();
    endTagColgroup(new EndTagToken("colgroup", data: {}));
    return ignoreEndTag ? null : token;
  }

  void endTagColgroup(EndTagToken token) {
    if (ignoreEndTagColgroup()) {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    } else {
      tree.openElements.removeLast();
      parser.phase = parser._inTablePhase;
    }
  }

  void endTagCol(EndTagToken token) {
    parser.parseError("no-end-tag", {"name": "col"});
  }

  Token endTagOther(EndTagToken token) {
    var ignoreEndTag = ignoreEndTagColgroup();
    endTagColgroup(new EndTagToken("colgroup", data: {}));
    return ignoreEndTag ? null : token;
  }
}


class InTableBodyPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-table0
  InTableBodyPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "tr": return startTagTr(token);
      case "td": case "th": return startTagTableCell(token);
      case "caption": case "col": case "colgroup": case "tbody": case "tfoot":
      case "thead":
        return startTagTableOther(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "tbody": case "tfoot": case "thead":
        return endTagTableRowGroup(token);
      case "table": return endTagTable(token);
      case "body": case "caption": case "col": case "colgroup": case "html":
      case "td": case "th": case "tr":
        return endTagIgnore(token);
      default: return endTagOther(token);
    }
  }

  // helper methods
  void clearStackToTableBodyContext() {
    while (const ["tbody", "tfoot","thead", "html"].indexOf(
        tree.openElements.last().tagName) == -1) {
      //XXX parser.parseError("unexpected-implied-end-tag-in-table",
      //  {"name": tree.openElements.last().name})
      tree.openElements.removeLast();
    }
    if (tree.openElements.last().tagName == "html") {
      assert(parser.innerHTMLMode);
    }
  }

  // the rest
  bool processEOF() {
    parser._inTablePhase.processEOF();
    return false;
  }

  Token processSpaceCharacters(SpaceCharactersToken token) {
    return parser._inTablePhase.processSpaceCharacters(token);
  }

  Token processCharacters(CharactersToken token) {
    return parser._inTablePhase.processCharacters(token);
  }

  void startTagTr(StartTagToken token) {
    clearStackToTableBodyContext();
    tree.insertElement(token);
    parser.phase = parser._inRowPhase;
  }

  Token startTagTableCell(StartTagToken token) {
    parser.parseError("unexpected-cell-in-table-body",
        {"name": token.name});
    startTagTr(new StartTagToken("tr", data: {}));
    return token;
  }

  Token startTagTableOther(token) => endTagTable(token);

  Token startTagOther(StartTagToken token) {
    return parser._inTablePhase.processStartTag(token);
  }

  void endTagTableRowGroup(EndTagToken token) {
    if (tree.elementInScope(token.name, variant: "table")) {
      clearStackToTableBodyContext();
      tree.openElements.removeLast();
      parser.phase = parser._inTablePhase;
    } else {
      parser.parseError("unexpected-end-tag-in-table-body",
          {"name": token.name});
    }
  }

  Token endTagTable(TagToken token) {
    // XXX AT Any ideas on how to share this with endTagTable?
    if (tree.elementInScope("tbody", variant: "table") ||
        tree.elementInScope("thead", variant: "table") ||
        tree.elementInScope("tfoot", variant: "table")) {
      clearStackToTableBodyContext();
      endTagTableRowGroup(
          new EndTagToken(tree.openElements.last().tagName, data: {}));
      return token;
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
    return null;
  }

  void endTagIgnore(EndTagToken token) {
    parser.parseError("unexpected-end-tag-in-table-body",
        {"name": token.name});
  }

  Token endTagOther(EndTagToken token) {
    return parser._inTablePhase.processEndTag(token);
  }
}


class InRowPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-row
  InRowPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "td": case "th": return startTagTableCell(token);
      case "caption": case "col": case "colgroup": case "tbody": case "tfoot":
      case "thead": case "tr":
        return startTagTableOther(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "tr": return endTagTr(token);
      case "table": return endTagTable(token);
      case "tbody": case "tfoot": case "thead":
        return endTagTableRowGroup(token);
      case "body": case "caption": case "col": case "colgroup": case "html":
      case "td": case "th":
        return endTagIgnore(token);
      default: return endTagOther(token);
    }
  }

  // helper methods (XXX unify this with other table helper methods)
  void clearStackToTableRowContext() {
    while (tree.openElements.last().tagName != "tr" &&
        tree.openElements.last().tagName != "html") {
      parser.parseError("unexpected-implied-end-tag-in-table-row",
        {"name": tree.openElements.last().tagName});
      tree.openElements.removeLast();
    }
  }

  bool ignoreEndTagTr() {
    return !tree.elementInScope("tr", variant: "table");
  }

  // the rest
  bool processEOF() {
    parser._inTablePhase.processEOF();
    return false;
  }

  Token processSpaceCharacters(SpaceCharactersToken token) {
    return parser._inTablePhase.processSpaceCharacters(token);
  }

  Token processCharacters(CharactersToken token) {
    return parser._inTablePhase.processCharacters(token);
  }

  void startTagTableCell(StartTagToken token) {
    clearStackToTableRowContext();
    tree.insertElement(token);
    parser.phase = parser._inCellPhase;
    tree.activeFormattingElements.add(Marker);
  }

  Token startTagTableOther(StartTagToken token) {
    bool ignoreEndTag = ignoreEndTagTr();
    endTagTr(new EndTagToken("tr", data: {}));
    // XXX how are we sure it's always ignored in the innerHTML case?
    return ignoreEndTag ? null : token;
  }

  Token startTagOther(StartTagToken token) {
    return parser._inTablePhase.processStartTag(token);
  }

  void endTagTr(EndTagToken token) {
    if (!ignoreEndTagTr()) {
      clearStackToTableRowContext();
      tree.openElements.removeLast();
      parser.phase = parser._inTableBodyPhase;
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
  }

  Token endTagTable(EndTagToken token) {
    var ignoreEndTag = ignoreEndTagTr();
    endTagTr(new EndTagToken("tr", data: {}));
    // Reprocess the current tag if the tr end tag was not ignored
    // XXX how are we sure it's always ignored in the innerHTML case?
    return ignoreEndTag ? null : token;
  }

  Token endTagTableRowGroup(EndTagToken token) {
    if (tree.elementInScope(token.name, variant: "table")) {
      endTagTr(new EndTagToken("tr", data: {}));
      return token;
    } else {
      parser.parseError();
      return null;
    }
  }

  void endTagIgnore(EndTagToken token) {
    parser.parseError("unexpected-end-tag-in-table-row",
        {"name": token.name});
  }

  Token endTagOther(EndTagToken token) {
    return parser._inTablePhase.processEndTag(token);
  }
}

class InCellPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-cell
  InCellPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "caption": case "col": case "colgroup": case "tbody": case "td":
      case "tfoot": case "th": case "thead": case "tr":
        return startTagTableOther(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "td": case "th":
        return endTagTableCell(token);
      case "body": case "caption": case "col": case "colgroup": case "html":
        return endTagIgnore(token);
      case "table": case "tbody": case "tfoot": case "thead": case "tr":
        return endTagImply(token);
      default: return endTagOther(token);
    }
  }

  // helper
  void closeCell() {
    if (tree.elementInScope("td", variant: "table")) {
      endTagTableCell(new EndTagToken("td", data: {}));
    } else if (tree.elementInScope("th", variant: "table")) {
      endTagTableCell(new EndTagToken("th", data: {}));
    }
  }

  // the rest
  bool processEOF() {
    parser._inBodyPhase.processEOF();
    return false;
  }

  Token processCharacters(CharactersToken token) {
    return parser._inBodyPhase.processCharacters(token);
  }

  Token startTagTableOther(StartTagToken token) {
    if (tree.elementInScope("td", variant: "table") ||
      tree.elementInScope("th", variant: "table")) {
      closeCell();
      return token;
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
  }

  Token startTagOther(StartTagToken token) {
    return parser._inBodyPhase.processStartTag(token);
  }

  void endTagTableCell(EndTagToken token) {
    if (tree.elementInScope(token.name, variant: "table")) {
      tree.generateImpliedEndTags(token.name);
      if (tree.openElements.last().tagName != token.name) {
        parser.parseError("unexpected-cell-end-tag", {"name": token.name});
        popOpenElementsUntil(token.name);
      } else {
        tree.openElements.removeLast();
      }
      tree.clearActiveFormattingElements();
      parser.phase = parser._inRowPhase;
    } else {
      parser.parseError("unexpected-end-tag", {"name": token.name});
    }
  }

  void endTagIgnore(EndTagToken token) {
    parser.parseError("unexpected-end-tag", {"name": token.name});
  }

  Token endTagImply(EndTagToken token) {
    if (tree.elementInScope(token.name, variant: "table")) {
      closeCell();
      return token;
    } else {
      // sometimes innerHTML case
      parser.parseError();
    }
  }

  Token endTagOther(EndTagToken token) {
    return parser._inBodyPhase.processEndTag(token);
  }
}

class InSelectPhase extends Phase {
  InSelectPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "option": return startTagOption(token);
      case "optgroup": return startTagOptgroup(token);
      case "select": return startTagSelect(token);
      case "input": case "keygen": case "textarea":
        return startTagInput(token);
      case "script": return startTagScript(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "option": return endTagOption(token);
      case "optgroup": return endTagOptgroup(token);
      case "select": return endTagSelect(token);
      default: return endTagOther(token);
    }
  }

  // http://www.whatwg.org/specs/web-apps/current-work///in-select
  bool processEOF() {
    if (tree.openElements.last().tagName != "html") {
      parser.parseError("eof-in-select");
    } else {
      assert(parser.innerHTMLMode);
    }
    return false;
  }

  Token processCharacters(CharactersToken token) {
    if (token.data == "\u0000") {
      return null;
    }
    tree.insertText(token.data);
  }

  void startTagOption(StartTagToken token) {
    // We need to imply </option> if <option> is the current node.
    if (tree.openElements.last().tagName == "option") {
      tree.openElements.removeLast();
    }
    tree.insertElement(token);
  }

  void startTagOptgroup(StartTagToken token) {
    if (tree.openElements.last().tagName == "option") {
      tree.openElements.removeLast();
    }
    if (tree.openElements.last().tagName == "optgroup") {
      tree.openElements.removeLast();
    }
    tree.insertElement(token);
  }

  void startTagSelect(StartTagToken token) {
    parser.parseError("unexpected-select-in-select");
    endTagSelect(new EndTagToken("select", data: {}));
  }

  Token startTagInput(StartTagToken token) {
    parser.parseError("unexpected-input-in-select");
    if (tree.elementInScope("select", variant: "select")) {
      endTagSelect(new EndTagToken("select", data: {}));
      return token;
    } else {
      assert(parser.innerHTMLMode);
    }
  }

  Token startTagScript(StartTagToken token) {
    return parser._inHeadPhase.processStartTag(token);
  }

  Token startTagOther(StartTagToken token) {
    parser.parseError("unexpected-start-tag-in-select",
        {"name": token.name});
  }

  void endTagOption(EndTagToken token) {
    if (tree.openElements.last().tagName == "option") {
      tree.openElements.removeLast();
    } else {
      parser.parseError("unexpected-end-tag-in-select",
          {"name": "option"});
    }
  }

  void endTagOptgroup(EndTagToken token) {
    // </optgroup> implicitly closes <option>
    if (tree.openElements.last().tagName == "option" &&
      tree.openElements[tree.openElements.length - 2].tagName == "optgroup") {
      tree.openElements.removeLast();
    }
    // It also closes </optgroup>
    if (tree.openElements.last().tagName == "optgroup") {
      tree.openElements.removeLast();
    // But nothing else
    } else {
      parser.parseError("unexpected-end-tag-in-select",
        {"name": "optgroup"});
    }
  }

  void endTagSelect(EndTagToken token) {
    if (tree.elementInScope("select", variant: "select")) {
      popOpenElementsUntil("select");
      parser.resetInsertionMode();
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
  }

  void endTagOther(EndTagToken token) {
    parser.parseError("unexpected-end-tag-in-select",
        {"name": token.name});
  }
}


class InSelectInTablePhase extends Phase {
  InSelectInTablePhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "caption": case "table": case "tbody": case "tfoot": case "thead":
      case "tr": case "td": case "th":
        return startTagTable(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "caption": case "table": case "tbody": case "tfoot": case "thead":
      case "tr": case "td": case "th":
        return endTagTable(token);
      default: return endTagOther(token);
    }
  }

  bool processEOF() {
    parser._inSelectPhase.processEOF();
    return false;
  }

  Token processCharacters(CharactersToken token) {
    return parser._inSelectPhase.processCharacters(token);
  }

  Token startTagTable(StartTagToken token) {
    parser.parseError("unexpected-table-element-start-tag-in-select-in-table",
        {"name": token.name});
    endTagOther(new EndTagToken("select", data: {}));
    return token;
  }

  Token startTagOther(StartTagToken token) {
    return parser._inSelectPhase.processStartTag(token);
  }

  Token endTagTable(EndTagToken token) {
    parser.parseError("unexpected-table-element-end-tag-in-select-in-table",
        {"name": token.name});
    if (tree.elementInScope(token.name, variant: "table")) {
      endTagOther(new EndTagToken("select", data: {}));
      return token;
    }
  }

  Token endTagOther(EndTagToken token) {
    return parser._inSelectPhase.processEndTag(token);
  }
}


class InForeignContentPhase extends Phase {
  // TODO(jmesserly): this is sorted so we could binary search.
  const breakoutElements = const [
    'b', 'big', 'blockquote', 'body', 'br','center', 'code', 'dd', 'div', 'dl',
    'dt', 'em', 'embed', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'hr', 'i',
    'img', 'li', 'listing', 'menu', 'meta', 'nobr', 'ol', 'p', 'pre', 'ruby',
    's', 'small', 'span', 'strike', 'strong', 'sub', 'sup', 'table', 'tt', 'u',
    'ul', 'var'
  ];

  InForeignContentPhase(parser) : super(parser);

  void adjustSVGTagNames(token) {
    final replacements = const {
      "altglyph":"altGlyph",
      "altglyphdef":"altGlyphDef",
      "altglyphitem":"altGlyphItem",
      "animatecolor":"animateColor",
      "animatemotion":"animateMotion",
      "animatetransform":"animateTransform",
      "clippath":"clipPath",
      "feblend":"feBlend",
      "fecolormatrix":"feColorMatrix",
      "fecomponenttransfer":"feComponentTransfer",
      "fecomposite":"feComposite",
      "feconvolvematrix":"feConvolveMatrix",
      "fediffuselighting":"feDiffuseLighting",
      "fedisplacementmap":"feDisplacementMap",
      "fedistantlight":"feDistantLight",
      "feflood":"feFlood",
      "fefunca":"feFuncA",
      "fefuncb":"feFuncB",
      "fefuncg":"feFuncG",
      "fefuncr":"feFuncR",
      "fegaussianblur":"feGaussianBlur",
      "feimage":"feImage",
      "femerge":"feMerge",
      "femergenode":"feMergeNode",
      "femorphology":"feMorphology",
      "feoffset":"feOffset",
      "fepointlight":"fePointLight",
      "fespecularlighting":"feSpecularLighting",
      "fespotlight":"feSpotLight",
      "fetile":"feTile",
      "feturbulence":"feTurbulence",
      "foreignobject":"foreignObject",
      "glyphref":"glyphRef",
      "lineargradient":"linearGradient",
      "radialgradient":"radialGradient",
      "textpath":"textPath"
    };

    var replace = replacements[token.name];
    if (replace != null) {
      token.name = replace;
    }
  }

  Token processCharacters(CharactersToken token) {
    if (token.data == "\u0000") {
      token.data = "\uFFFD";
    } else if (parser.framesetOK && !allWhitespace(token.data)) {
      parser.framesetOK = false;
    }
    super.processCharacters(token);
  }

  Token processStartTag(StartTagToken token) {
    var currentNode = tree.openElements.last();
    if (breakoutElements.indexOf(token.name) >= 0 ||
        (token.name == "font" &&
         (token.data.containsKey("color") ||
          token.data.containsKey("face") ||
          token.data.containsKey("size")))) {

      parser.parseError("unexpected-html-element-in-foreign-content",
          {'name': token.name});
      while (tree.openElements.last().namespace !=
           tree.defaultNamespace &&
           !parser.isHTMLIntegrationPoint(tree.openElements.last()) &&
           !parser.isMathMLTextIntegrationPoint(tree.openElements.last())) {
        tree.openElements.removeLast();
      }
      return token;

    } else {
      if (currentNode.namespace == Namespaces.mathml) {
        parser.adjustMathMLAttributes(token);
      } else if (currentNode.namespace == Namespaces.svg) {
        adjustSVGTagNames(token);
        parser.adjustSVGAttributes(token);
      }
      parser.adjustForeignAttributes(token);
      token.namespace = currentNode.namespace;
      tree.insertElement(token);
      if (token.selfClosing) {
        tree.openElements.removeLast();
        token.selfClosingAcknowledged = true;
      }
    }
  }

  Token processEndTag(EndTagToken token) {
    var nodeIndex = tree.openElements.length - 1;
    var node = tree.openElements.last();
    if (node.tagName != token.name) {
      parser.parseError("unexpected-end-tag", {"name": token.name});
    }

    var newToken = null;
    while (true) {
      if (asciiUpper2Lower(node.tagName) == token.name) {
        //XXX this isn't in the spec but it seems necessary
        if (parser.phase == parser._inTableTextPhase) {
          InTableTextPhase inTableText = parser.phase;
          inTableText.flushCharacters();
          parser.phase = inTableText.originalPhase;
        }
        while (tree.openElements.removeLast() != node) {
          assert(tree.openElements.length > 0);
        }
        newToken = null;
        break;
      }
      nodeIndex -= 1;

      node = tree.openElements[nodeIndex];
      if (node.namespace != tree.defaultNamespace) {
        continue;
      } else {
        newToken = parser.phase.processEndTag(token);
        break;
      }
    }
    return newToken;
  }
}


class AfterBodyPhase extends Phase {
  AfterBodyPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    if (token.name == "html") return startTagHtml(token);
    return startTagOther(token);
  }

  processEndTag(EndTagToken token) {
    if (token.name == "html") return endTagHtml(token);
    return endTagOther(token);
  }

  //Stop parsing
  bool processEOF() => false;

  Token processComment(CommentToken token) {
    // This is needed because data is to be appended to the <html> element
    // here and not to whatever is currently open.
    tree.insertComment(token, tree.openElements[0]);
  }

  Token processCharacters(CharactersToken token) {
    parser.parseError("unexpected-char-after-body");
    parser.phase = parser._inBodyPhase;
    return token;
  }

  Token startTagHtml(StartTagToken token) {
    return parser._inBodyPhase.processStartTag(token);
  }

  Token startTagOther(StartTagToken token) {
    parser.parseError("unexpected-start-tag-after-body",
        {"name": token.name});
    parser.phase = parser._inBodyPhase;
    return token;
  }

  void endTagHtml(name) {
    if (parser.innerHTMLMode) {
      parser.parseError("unexpected-end-tag-after-body-innerhtml");
    } else {
      parser.phase = parser._afterAfterBodyPhase;
    }
  }

  Token endTagOther(EndTagToken token) {
    parser.parseError("unexpected-end-tag-after-body",
        {"name": token.name});
    parser.phase = parser._inBodyPhase;
    return token;
  }
}

class InFramesetPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-frameset
  InFramesetPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "frameset": return startTagFrameset(token);
      case "frame": return startTagFrame(token);
      case "noframes": return startTagNoframes(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "frameset": return endTagFrameset(token);
      default: return endTagOther(token);
    }
  }

  bool processEOF() {
    if (tree.openElements.last().tagName != "html") {
      parser.parseError("eof-in-frameset");
    } else {
      assert(parser.innerHTMLMode);
    }
    return false;
  }

  Token processCharacters(CharactersToken token) {
    parser.parseError("unexpected-char-in-frameset");
  }

  void startTagFrameset(StartTagToken token) {
    tree.insertElement(token);
  }

  void startTagFrame(StartTagToken token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
  }

  Token startTagNoframes(StartTagToken token) {
    return parser._inBodyPhase.processStartTag(token);
  }

  Token startTagOther(StartTagToken token) {
    parser.parseError("unexpected-start-tag-in-frameset",
        {"name": token.name});
  }

  void endTagFrameset(EndTagToken token) {
    if (tree.openElements.last().tagName == "html") {
      // innerHTML case
      parser.parseError("unexpected-frameset-in-frameset-innerhtml");
    } else {
      tree.openElements.removeLast();
    }
    if (!parser.innerHTMLMode && tree.openElements.last().tagName != "frameset") {
      // If we're not in innerHTML mode and the the current node is not a
      // "frameset" element (anymore) then switch.
      parser.phase = parser._afterFramesetPhase;
    }
  }

  void endTagOther(EndTagToken token) {
    parser.parseError("unexpected-end-tag-in-frameset",
        {"name": token.name});
  }
}


class AfterFramesetPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///after3
  AfterFramesetPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "noframes": return startTagNoframes(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(EndTagToken token) {
    switch (token.name) {
      case "html": return endTagHtml(token);
      default: return endTagOther(token);
    }
  }

  // Stop parsing
  bool processEOF() => false;

  Token processCharacters(CharactersToken token) {
    parser.parseError("unexpected-char-after-frameset");
  }

  Token startTagNoframes(StartTagToken token) {
    return parser._inHeadPhase.processStartTag(token);
  }

  void startTagOther(StartTagToken token) {
    parser.parseError("unexpected-start-tag-after-frameset",
        {"name": token.name});
  }

  void endTagHtml(EndTagToken token) {
    parser.phase = parser._afterAfterFramesetPhase;
  }

  void endTagOther(EndTagToken token) {
    parser.parseError("unexpected-end-tag-after-frameset",
        {"name": token.name});
  }
}


class AfterAfterBodyPhase extends Phase {
  AfterAfterBodyPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    if (token.name == 'html') return startTagHtml(token);
    return startTagOther(token);
  }

  bool processEOF() => false;

  Token processComment(CommentToken token) {
    tree.insertComment(token, tree.document);
  }

  Token processSpaceCharacters(SpaceCharactersToken token) {
    return parser._inBodyPhase.processSpaceCharacters(token);
  }

  Token processCharacters(CharactersToken token) {
    parser.parseError("expected-eof-but-got-char");
    parser.phase = parser._inBodyPhase;
    return token;
  }

  Token startTagHtml(StartTagToken token) {
    return parser._inBodyPhase.processStartTag(token);
  }

  Token startTagOther(StartTagToken token) {
    parser.parseError("expected-eof-but-got-start-tag", {"name": token.name});
    parser.phase = parser._inBodyPhase;
    return token;
  }

  Token processEndTag(EndTagToken token) {
    parser.parseError("expected-eof-but-got-end-tag", {"name": token.name});
    parser.phase = parser._inBodyPhase;
    return token;
  }
}

class AfterAfterFramesetPhase extends Phase {
  AfterAfterFramesetPhase(parser) : super(parser);

  processStartTag(StartTagToken token) {
    switch (token.name) {
      case "html": return startTagHtml(token);
      case "noframes": return startTagNoFrames(token);
      default: return startTagOther(token);
    }
  }

  bool processEOF() => false;

  Token processComment(CommentToken token) {
    tree.insertComment(token, tree.document);
  }

  Token processSpaceCharacters(SpaceCharactersToken token) {
    return parser._inBodyPhase.processSpaceCharacters(token);
  }

  Token processCharacters(CharactersToken token) {
    parser.parseError("expected-eof-but-got-char");
  }

  Token startTagHtml(StartTagToken token) {
    return parser._inBodyPhase.processStartTag(token);
  }

  Token startTagNoFrames(StartTagToken token) {
    return parser._inHeadPhase.processStartTag(token);
  }

  void startTagOther(StartTagToken token) {
    parser.parseError("expected-eof-but-got-start-tag",
        {"name": token.name});
  }

  Token processEndTag(EndTagToken token) {
    parser.parseError("expected-eof-but-got-end-tag",
        {"name": token.name});
  }
}


/** Error in parsed document. */
class ParseError implements Exception {
  final String errorCode;
  final Span span;
  final Map data;

  ParseError(this.errorCode, this.span, this.data);

  int get line() => span.line;

  int get column() => span.column;

  String get message => formatStr(errorMessages[errorCode], data);

  String toString() => "ParseError at line $line column $column: $message";
}
