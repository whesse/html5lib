#library('html5parser');

#import('dart:math');
#import('package:logging/logging.dart');
#import('treebuilders/simpletree.dart');
#import('encoding_parser.dart');
#import('tokenizer.dart');
#import('utils.dart');
#import('constants.dart');

// TODO(jmesserly): these APIs, as well as the HTMLParser contructor and
// HTMLParser.parse and parseFragment were changed a bit to avoid passing a
// first class type that is used for construction. It might be okay, but I'd
// like to find a good dependency-injection pattern for Dart rather than
// copy the Python API.
// TODO(jmesserly): Also some of the HTMLParser APIs are messed up to avoid
// editor shadowing warnings :\
/**
 * Parse an html5 [doc]ument that is a [String], [RandomAccessFile] or
 * [List<int>] of bytes into a tree.
 *
 * The optional [encoding] must be a string that indicates the encoding. If
 * specified, that encoding will be used, regardless of any BOM or later
 * declaration (such as in a meta element).
 */
parse(doc, [TreeBuilder treebuilder, String encoding]) {
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
parseFragment(doc, [String container = "div", TreeBuilder treebuilder,
    String encoding]) {
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

  /**
   * Create a new HTMLParser and configure the [tree] builder and [strict] mode.
   */
  HTMLParser([TreeBuilder tree, this.strict = false])
      : tree = tree != null ? tree : new TreeBuilder(true),
        errors = <ParseError>[] {

    // TODO(jmesserly): optimize. These should all be fields.
    phases = {
      "initial": new InitialPhase(this),
      "beforeHtml": new BeforeHtmlPhase(this),
      "beforeHead": new BeforeHeadPhase(this),
      "inHead": new InHeadPhase(this),
      // XXX "inHeadNoscript": new InHeadNoScriptPhase(this),
      "afterHead": new AfterHeadPhase(this),
      "inBody": new InBodyPhase(this),
      "text": new TextPhase(this),
      "inTable": new InTablePhase(this),
      "inTableText": new InTableTextPhase(this),
      "inCaption": new InCaptionPhase(this),
      "inColumnGroup": new InColumnGroupPhase(this),
      "inTableBody": new InTableBodyPhase(this),
      "inRow": new InRowPhase(this),
      "inCell": new InCellPhase(this),
      "inSelect": new InSelectPhase(this),
      "inSelectInTable": new InSelectInTablePhase(this),
      "inForeignContent": new InForeignContentPhase(this),
      "afterBody": new AfterBodyPhase(this),
      "inFrameset": new InFramesetPhase(this),
      "afterFrameset": new AfterFramesetPhase(this),
      "afterAfterBody": new AfterAfterBodyPhase(this),
      "afterAfterFrameset": new AfterAfterFramesetPhase(this),
      // XXX after after frameset
    };
  }

  /**
   * Parse a HTML document into a well-formed tree
   *
   * [tokenizer_] - an object that provides a stream of tokens to the
   * treebuilder. This may be replaced for e.g. a sanitizer which converts some
   * tags to text. Otherwise, construct an instance of HTMLTokenizer with the
   * appropriate options.
   */
  parse(HTMLTokenizer tokenizer_) {
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
  parseFragment(HTMLTokenizer tokenizer_, [String container_ = "div"]) {
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
      } catch (ReparseException e) {
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
      phase = phases["beforeHtml"];
      (phase as BeforeHtmlPhase).insertHtmlElement();
      resetInsertionMode();
    } else {
      innerHTML = null;
      phase = phases["initial"];
    }

    lastPhase = null;
    beforeRCDataPhase = null;
    framesetOK = true;
  }

  bool isHTMLIntegrationPoint(element) {
    if (element.name == "annotation-xml" &&
        element.namespace == Namespaces.mathml) {
      var enc = element.attributes["encoding"];
      if (enc != null) enc = asciiUpper2Lower(enc);
      return enc == "text/html" || enc == "application/xhtml+xml";
    } else {
      return htmlIntegrationPointElements.indexOf(
          new Pair(element.namespace, element.name)) >= 0;
    }
  }

  bool isMathMLTextIntegrationPoint(element) {
    return mathmlTextIntegrationPointElements.indexOf(
        new Pair(element.namespace, element.name)) >= 0;
  }

  bool inForeignContent(token, int type) {
    if (tree.openElements.length == 0) return false;

    var node = tree.openElements.last();
    if (node.namespace == tree.defaultNamespace) return false;

    if (isMathMLTextIntegrationPoint(node)) {
      if (type == StartTagToken &&
          token["name"] != "mglyph" &&
          token["name"] != "malignmark")  {
        return false;
      }
      if (type == CharactersToken || type == SpaceCharactersToken) {
        return false;
      }
    }

    if (node.name == "annotation-xml" && type == StartTagToken &&
        token["name"] == "svg") {
      return false;
    }

    if (isHTMLIntegrationPoint(node)) {
      if (type == StartTagToken ||
          type == CharactersToken ||
          type == SpaceCharactersToken) {
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
        type = newToken["type"];

        if (type == ParseErrorToken) {
          parseError(newToken["data"], newToken["datavars"]);
          newToken = null;
        } else {
          Phase phase_ = phase;
          if (inForeignContent(token, type)) {
            phase_ = phases["inForeignContent"];
          }

          switch (type) {
            case CharactersToken:
              newToken = phase_.processCharacters(newToken);
              break;
            case SpaceCharactersToken:
              newToken = phase_.processSpaceCharacters(newToken);
              break;
            case StartTagToken:
              newToken = phase_.processStartTag(newToken);
              break;
            case EndTagToken:
              newToken = phase_.processEndTag(newToken);
              break;
            case CommentToken:
              newToken = phase_.processComment(newToken);
              break;
            case DoctypeToken:
              newToken = phase_.processDoctype(newToken);
              break;
          }
        }
      }

      if (type == StartTagToken && token["selfClosing"]
          && !token["selfClosingAcknowledged"]) {
        parseError("non-void-element-with-trailing-solidus",
            {"name": token["name"]});
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
    var err = new ParseError(errorcode, position[0], position[1], datavars);
    errors.add(err);
    if (strict) throw err;
  }

  /** HTML5 specific normalizations to the token stream. */
  Map normalizeToken(Map token) {
    if (token["type"] == StartTagToken) {
      token["data"] = makeDict(token["data"]);
    }
    return token;
  }

  void adjustMathMLAttributes(Map token) {
    var orig = token["data"].remove("definitionurl");
    if (orig != null) {
      token["data"]["definitionURL"] = orig;
    }
  }

  void adjustSVGAttributes(Map token) {
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
    for (var originalName in token["data"].getKeys()) {
      var svgName = replacements[originalName];
      if (svgName != null) {
        token["data"][svgName] = token["data"].remove(originalName);
      }
    }
  }

  void adjustForeignAttributes(Map token) {
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

    for (var originalName in token["data"].getKeys()) {
      var foreignName = replacements[originalName];
      if (foreignName != null) {
        token["data"][foreignName] = token["data"].remove(originalName);
      }
    }
  }

  void resetInsertionMode() {
    // The name of this method is mostly historical. (It's also used in the
    // specification.)
    var last = false;
    final newModes = const {
      "select":"inSelect",
      "td":"inCell",
      "th":"inCell",
      "tr":"inRow",
      "tbody":"inTableBody",
      "thead":"inTableBody",
      "tfoot":"inTableBody",
      "caption":"inCaption",
      "colgroup":"inColumnGroup",
      "table":"inTable",
      "head":"inBody",
      "body":"inBody",
      "frameset":"inFrameset",
      "html":"beforeHead"
    };
    var newPhase = null;
    for (var node in reversed(tree.openElements)) {
      var nodeName = node.name;
      if (node == tree.openElements[0]) {
        assert(innerHTMLMode);
        last = true;
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
      var newMode = newModes[nodeName];
      if (newMode != null) {
        newPhase = phases[newMode];
        break;
      } else if (last) {
        newPhase = phases["inBody"];
        break;
      }
    }
    phase = newPhase;
  }

  /**
   * Generic RCDATA/RAWTEXT Parsing algorithm
   * [contentType] - RCDATA or RAWTEXT
   */
  void parseRCDataRawtext(Map token, String contentType) {
    assert(contentType == "RAWTEXT" || contentType == "RCDATA");

    var element = tree.insertElement(token);

    if (contentType == "RAWTEXT") {
      tokenizer.state = tokenizer.rawtextState;
    } else {
      tokenizer.state = tokenizer.rcdataState;
    }

    originalPhase = phase;
    phase = phases["text"];
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

  Map processComment(token) {
    // For most phases the following is correct. Where it's not it will be
    // overridden.
    tree.insertComment(token, tree.openElements.last());
  }

  Map processDoctype(token) {
    parser.parseError("unexpected-doctype");
  }

  Map processCharacters(token) {
    tree.insertText(token["data"]);
  }

  Map processSpaceCharacters(token) {
    tree.insertText(token["data"]);
  }

  Map processStartTag(token) {
    throw const NotImplementedException();
  }

  Map startTagHtml(token) {
    if (parser.firstStartTag == false && token["name"] == "html") {
       parser.parseError("non-html-root");
    }
    // XXX Need a check here to see if the first start tag token emitted is
    // this token... If it's not, invoke parser.parseError().
    token["data"].forEach((attr, value) {
      tree.openElements[0].attributes.putIfAbsent(attr, () => value);
    });
    parser.firstStartTag = false;
  }

  Map processEndTag(token) {
    throw const NotImplementedException();
  }

  /** Helper method for popping openElements. */
  void popOpenElementsUntil(String name) {
    var node = tree.openElements.removeLast();
    while (node.name != name) {
      node = tree.openElements.removeLast();
    }
  }
}

class InitialPhase extends Phase {
  InitialPhase(parser) : super(parser);

  Map processSpaceCharacters(token) {
  }

  Map processComment(token) {
    tree.insertComment(token, tree.document);
  }

  Map processDoctype(token) {
    var name = token["name"];
    var publicId = token["publicId"];
    var systemId = token["systemId"];
    var correct = token["correct"];

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

    if (!correct || token["name"] != "html"
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
    parser.phase = parser.phases["beforeHtml"];
  }

  void anythingElse() {
    parser.compatMode = "quirks";
    parser.phase = parser.phases["beforeHtml"];
  }

  Map processCharacters(token) {
    parser.parseError("expected-doctype-but-got-chars");
    anythingElse();
    return token;
  }

  Map processStartTag(token) {
    parser.parseError("expected-doctype-but-got-start-tag",
        {"name": token["name"]});
    anythingElse();
    return token;
  }

  Map processEndTag(token) {
    parser.parseError("expected-doctype-but-got-end-tag",
        {"name": token["name"]});
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
    tree.insertRoot(impliedTagToken("html", "StartTag"));
    parser.phase = parser.phases["beforeHead"];
  }

  // other
  bool processEOF() {
    insertHtmlElement();
    return true;
  }

  Map processComment(token) {
    tree.insertComment(token, tree.document);
  }

  Map processSpaceCharacters(token) {
  }

  Map processCharacters(token) {
    insertHtmlElement();
    return token;
  }

  Map processStartTag(token) {
    if (token["name"] == "html") {
      parser.firstStartTag = true;
    }
    insertHtmlElement();
    return token;
  }

  Map processEndTag(token) {
    switch (token["name"]) {
      case "head": case "body": case "html": case "br":
        insertHtmlElement();
        return token;
      default:
        parser.parseError("unexpected-end-tag-before-html",
            {"name": token["name"]});
        return null;
    }
  }
}


class BeforeHeadPhase extends Phase {
  BeforeHeadPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case 'html': return startTagHtml(token);
      case 'head': return startTagHead(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(token) {
    switch (token['name']) {
      case "head": case "body": case "html": case "br":
        return endTagImplyHead(token);
      default: return endTagOther(token);
    }
  }

  bool processEOF() {
    startTagHead(impliedTagToken("head", "StartTag"));
    return true;
  }

  Map processSpaceCharacters(token) {
  }

  Map processCharacters(token) {
    startTagHead(impliedTagToken("head", "StartTag"));
    return token;
  }

  Map startTagHtml(token) {
    return parser.phases["inBody"].processStartTag(token);
  }

  void startTagHead(token) {
    tree.insertElement(token);
    tree.headPointer = tree.openElements.last();
    parser.phase = parser.phases["inHead"];
  }

  Map startTagOther(token) {
    startTagHead(impliedTagToken("head", "StartTag"));
    return token;
  }

  Map endTagImplyHead(token) {
    startTagHead(impliedTagToken("head", "StartTag"));
    return token;
  }

  void endTagOther(token) {
    parser.parseError("end-tag-after-implied-root",
      {"name": token["name"]});
  }
}

class InHeadPhase extends Phase {
  InHeadPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
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

  processEndTag(token) {
    switch (token['name']) {
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

  Map processCharacters(token) {
    anythingElse();
    return token;
  }

  Map startTagHtml(token) {
    return parser.phases["inBody"].processStartTag(token);
  }

  void startTagHead(token) {
    parser.parseError("two-heads-are-not-better-than-one");
  }

  void startTagBaseLinkCommand(token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
    token["selfClosingAcknowledged"] = true;
  }

  void startTagMeta(token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
    token["selfClosingAcknowledged"] = true;

    var attributes = token["data"];
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

  void startTagTitle(token) {
    parser.parseRCDataRawtext(token, "RCDATA");
  }

  void startTagNoScriptNoFramesStyle(token) {
    // Need to decide whether to implement the scripting-disabled case
    parser.parseRCDataRawtext(token, "RAWTEXT");
  }

  void startTagScript(token) {
    tree.insertElement(token);
    parser.tokenizer.state = parser.tokenizer.scriptDataState;
    parser.originalPhase = parser.phase;
    parser.phase = parser.phases["text"];
  }

  Map startTagOther(token) {
    anythingElse();
    return token;
  }

  void endTagHead(token) {
    var node = parser.tree.openElements.removeLast();
    assert(node.name == "head");
    parser.phase = parser.phases["afterHead"];
  }

  Map endTagHtmlBodyBr(token) {
    anythingElse();
    return token;
  }

  void endTagOther(token) {
    parser.parseError("unexpected-end-tag", {"name": token["name"]});
  }

  void anythingElse() {
    endTagHead(impliedTagToken("head"));
  }
}


// XXX If we implement a parser for which scripting is disabled we need to
// implement this phase.
//
// class InHeadNoScriptPhase extends Phase {

class AfterHeadPhase extends Phase {
  AfterHeadPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
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

  processEndTag(token) {
    switch (token['name']) {
      case "body": case "html": case "br":
        return endTagHtmlBodyBr(token);
      default: return endTagOther(token);
    }
  }

  bool processEOF() {
    anythingElse();
    return true;
  }

  Map processCharacters(token) {
    anythingElse();
    return token;
  }

  Map startTagHtml(token) {
    return parser.phases["inBody"].processStartTag(token);
  }

  void startTagBody(token) {
    parser.framesetOK = false;
    tree.insertElement(token);
    parser.phase = parser.phases["inBody"];
  }

  void startTagFrameset(token) {
    tree.insertElement(token);
    parser.phase = parser.phases["inFrameset"];
  }

  void startTagFromHead(token) {
    parser.parseError("unexpected-start-tag-out-of-my-head",
      {"name": token["name"]});
    tree.openElements.add(tree.headPointer);
    parser.phases["inHead"].processStartTag(token);
    for (var node in reversed(tree.openElements)) {
      if (node.name == "head") {
        removeFromList(tree.openElements, node);
        break;
      }
    }
  }

  void startTagHead(token) {
    parser.parseError("unexpected-start-tag", {"name":token["name"]});
  }

  Map startTagOther(token) {
    anythingElse();
    return token;
  }

  Map endTagHtmlBodyBr(token) {
    anythingElse();
    return token;
  }

  void endTagOther(token) {
    parser.parseError("unexpected-end-tag", {"name":token["name"]});
  }

  void anythingElse() {
    tree.insertElement(impliedTagToken("body", "StartTag"));
    parser.phase = parser.phases["inBody"];
    parser.framesetOK = true;
  }
}

typedef Map TokenProccessor(Map token);

class InBodyPhase extends Phase {
  TokenProccessor processSpaceCharactersFunc;

  // http://www.whatwg.org/specs/web-apps/current-work///parsing-main-inbody
  // the really-really-really-very crazy mode
  InBodyPhase(parser) : super(parser) {
    //Keep a ref to this for special handling of whitespace in <pre>
    processSpaceCharactersFunc = processSpaceCharactersNonPre;
  }

  processStartTag(token) {
    switch (token['name']) {
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

  processEndTag(token) {
    switch (token['name']) {
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

  bool isMatchingFormattingElement(node1, node2) {
    if (node1.name != node2.name || node1.namespace != node2.namespace) {
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
    for (var node in reversed(tree.activeFormattingElements)) {
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
    for (var node in reversed(tree.openElements)) {
      switch (node.name) {
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

  Map processSpaceCharactersDropNewline(token) {
    // Sometimes (start of <pre>, <listing>, and <textarea> blocks) we
    // want to drop leading newlines
    var data = token["data"];
    processSpaceCharactersFunc = processSpaceCharactersNonPre;
    if (data.startsWith("\n")) {
      var lastOpen = tree.openElements.last();
      if (const ["pre", "listing", "textarea"].indexOf(lastOpen.name) >= 0
          && !lastOpen.hasContent()) {
        data = data.substring(1);
      }
    }
    if (data.length > 0) {
      tree.reconstructActiveFormattingElements();
      tree.insertText(data);
    }
  }

  Map processCharacters(token) {
    if (token["data"] == "\u0000") {
      //The tokenizer should always emit null on its own
      return null;
    }
    tree.reconstructActiveFormattingElements();
    tree.insertText(token["data"]);
    if (parser.framesetOK && !allWhitespace(token["data"])) {
      parser.framesetOK = false;
    }
  }

  Map processSpaceCharactersNonPre(token) {
    tree.reconstructActiveFormattingElements();
    tree.insertText(token["data"]);
  }

  Map processSpaceCharacters(token) => processSpaceCharactersFunc(token);

  Map startTagProcessInHead(token) {
    return parser.phases["inHead"].processStartTag(token);
  }

  void startTagBody(token) {
    parser.parseError("unexpected-start-tag", {"name": "body"});
    if (tree.openElements.length == 1
        || tree.openElements[1].name != "body") {
      assert(parser.innerHTMLMode);
    } else {
      parser.framesetOK = false;
      token["data"].forEach((attr, value) {
        tree.openElements[1].attributes.putIfAbsent(attr, () => value);
      });
    }
  }

  void startTagFrameset(token) {
    parser.parseError("unexpected-start-tag", {"name": "frameset"});
    if ((tree.openElements.length == 1 ||
        tree.openElements[1].name != "body")) {
      assert(parser.innerHTMLMode);
    } else if (parser.framesetOK) {
      if (tree.openElements[1].parent != null) {
        tree.openElements[1].parent.removeChild(tree.openElements[1]);
      }
      while (tree.openElements.last().name != "html") {
        tree.openElements.removeLast();
      }
      tree.insertElement(token);
      parser.phase = parser.phases["inFrameset"];
    }
  }

  void startTagCloseP(token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(impliedTagToken("p"));
    }
    tree.insertElement(token);
  }

  void startTagPreListing(token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(impliedTagToken("p"));
    }
    tree.insertElement(token);
    parser.framesetOK = false;
    processSpaceCharactersFunc = processSpaceCharactersDropNewline;
  }

  void startTagForm(token) {
    if (tree.formPointer != null) {
      parser.parseError("unexpected-start-tag", {"name": "form"});
    } else {
      if (tree.elementInScope("p", variant: "button")) {
        endTagP(impliedTagToken("p"));
      }
      tree.insertElement(token);
      tree.formPointer = tree.openElements.last();
    }
  }

  void startTagListItem(token) {
    parser.framesetOK = false;

    final stopNamesMap = const {"li": const ["li"],
                                "dt": const ["dt", "dd"],
                                "dd": const ["dt", "dd"]};
    var stopNames = stopNamesMap[token["name"]];
    for (var node in reversed(tree.openElements)) {
      if (stopNames.indexOf(node.name) >= 0) {
        parser.phase.processEndTag(impliedTagToken(node.name, "EndTag"));
        break;
      }
      if (specialElements.indexOf(node.nameTuple) >= 0 &&
          const ["address", "div", "p"].indexOf(node.name) == -1) {
        break;
      }
    }

    if (tree.elementInScope("p", variant: "button")) {
      parser.phase.processEndTag(impliedTagToken("p", "EndTag"));
    }

    tree.insertElement(token);
  }

  void startTagPlaintext(token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(impliedTagToken("p"));
    }
    tree.insertElement(token);
    parser.tokenizer.state = parser.tokenizer.plaintextState;
  }

  void startTagHeading(token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(impliedTagToken("p"));
    }
    if (headingElements.indexOf(tree.openElements.last().name) >= 0) {
      parser.parseError("unexpected-start-tag", {"name": token["name"]});
      tree.openElements.removeLast();
    }
    tree.insertElement(token);
  }

  void startTagA(token) {
    var afeAElement = tree.elementInActiveFormattingElements("a");
    if (afeAElement != null) {
      parser.parseError("unexpected-start-tag-implies-end-tag",
          {"startName": "a", "endName": "a"});
      endTagFormatting(impliedTagToken("a"));
      removeFromList(tree.openElements, afeAElement);
      removeFromList(tree.activeFormattingElements, afeAElement);
    }
    tree.reconstructActiveFormattingElements();
    addFormattingElement(token);
  }

  void startTagFormatting(token) {
    tree.reconstructActiveFormattingElements();
    addFormattingElement(token);
  }

  void startTagNobr(token) {
    tree.reconstructActiveFormattingElements();
    if (tree.elementInScope("nobr")) {
      parser.parseError("unexpected-start-tag-implies-end-tag",
        {"startName": "nobr", "endName": "nobr"});
      processEndTag(impliedTagToken("nobr"));
      // XXX Need tests that trigger the following
      tree.reconstructActiveFormattingElements();
    }
    addFormattingElement(token);
  }

  Map startTagButton(token) {
    if (tree.elementInScope("button")) {
      parser.parseError("unexpected-start-tag-implies-end-tag",
        {"startName": "button", "endName": "button"});
      processEndTag(impliedTagToken("button"));
      return token;
    } else {
      tree.reconstructActiveFormattingElements();
      tree.insertElement(token);
      parser.framesetOK = false;
    }
  }

  void startTagAppletMarqueeObject(token) {
    tree.reconstructActiveFormattingElements();
    tree.insertElement(token);
    tree.activeFormattingElements.add(Marker);
    parser.framesetOK = false;
  }

  void startTagXmp(token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(impliedTagToken("p"));
    }
    tree.reconstructActiveFormattingElements();
    parser.framesetOK = false;
    parser.parseRCDataRawtext(token, "RAWTEXT");
  }

  void startTagTable(token) {
    if (parser.compatMode != "quirks") {
      if (tree.elementInScope("p", variant: "button")) {
        processEndTag(impliedTagToken("p"));
      }
    }
    tree.insertElement(token);
    parser.framesetOK = false;
    parser.phase = parser.phases["inTable"];
  }

  void startTagVoidFormatting(token) {
    tree.reconstructActiveFormattingElements();
    tree.insertElement(token);
    tree.openElements.removeLast();
    token["selfClosingAcknowledged"] = true;
    parser.framesetOK = false;
  }

  void startTagInput(token) {
    var savedFramesetOK = parser.framesetOK;
    startTagVoidFormatting(token);
    if (asciiUpper2Lower(token["data"]["type"]) == "hidden") {
      //input type=hidden doesn't change framesetOK
      parser.framesetOK = savedFramesetOK;
    }
  }

  void startTagParamSource(token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
    token["selfClosingAcknowledged"] = true;
  }

  void startTagHr(token) {
    if (tree.elementInScope("p", variant: "button")) {
      endTagP(impliedTagToken("p"));
    }
    tree.insertElement(token);
    tree.openElements.removeLast();
    token["selfClosingAcknowledged"] = true;
    parser.framesetOK = false;
  }

  void startTagImage(token) {
    // No really...
    parser.parseError("unexpected-start-tag-treated-as",
        {"originalName": "image", "newName": "img"});
    processStartTag(impliedTagToken("img", "StartTag",
        attributes: token["data"], selfClosing: token["selfClosing"]));
  }

  void startTagIsIndex(token) {
    parser.parseError("deprecated-tag", {"name": "isindex"});
    if (tree.formPointer != null) {
      return;
    }
    var formAttrs = {};
    var dataAction = token["data"]["action"];
    if (dataAction != null) {
      formAttrs["action"] = dataAction;
    }
    processStartTag(impliedTagToken("form", "StartTag",
                    attributes: formAttrs));
    processStartTag(impliedTagToken("hr", "StartTag"));
    processStartTag(impliedTagToken("label", "StartTag"));
    // XXX Localization ...
    var prompt = token["data"]["prompt"];
    if (prompt == null) {
      prompt = "This is a searchable index. Enter search keywords: ";
    }
    processCharacters({"type":CharactersToken, "data":prompt});
    var attributes = new Map.from(token["data"]);
    attributes.remove('action');
    attributes.remove('prompt');
    attributes["name"] = "isindex";
    processStartTag(impliedTagToken("input", "StartTag",
                    attributes: attributes,
                    selfClosing: token["selfClosing"]));
    processEndTag(impliedTagToken("label"));
    processStartTag(impliedTagToken("hr", "StartTag"));
    processEndTag(impliedTagToken("form"));
  }

  void startTagTextarea(token) {
    tree.insertElement(token);
    parser.tokenizer.state = parser.tokenizer.rcdataState;
    processSpaceCharactersFunc = processSpaceCharactersDropNewline;
    parser.framesetOK = false;
  }

  void startTagIFrame(token) {
    parser.framesetOK = false;
    startTagRawtext(token);
  }

  /** iframe, noembed noframes, noscript(if scripting enabled). */
  void startTagRawtext(token) {
    parser.parseRCDataRawtext(token, "RAWTEXT");
  }

  void startTagOpt(token) {
    if (tree.openElements.last().name == "option") {
      parser.phase.processEndTag(impliedTagToken("option"));
    }
    tree.reconstructActiveFormattingElements();
    parser.tree.insertElement(token);
  }

  void startTagSelect(token) {
    tree.reconstructActiveFormattingElements();
    tree.insertElement(token);
    parser.framesetOK = false;

    var phases = parser.phases;
    if (phases["inTable"] == parser.phase ||
        phases["inCaption"] == parser.phase ||
        phases["inColumnGroup"] == parser.phase ||
        phases["inTableBody"] == parser.phase ||
        phases["inRow"] == parser.phase ||
        phases["inCell"] == parser.phase) {
      parser.phase = parser.phases["inSelectInTable"];
    } else {
      parser.phase = parser.phases["inSelect"];
    }
  }

  void startTagRpRt(token) {
    if (tree.elementInScope("ruby")) {
      tree.generateImpliedEndTags();
      if (tree.openElements.last().name != "ruby") {
        parser.parseError();
      }
    }
    tree.insertElement(token);
  }

  void startTagMath(token) {
    tree.reconstructActiveFormattingElements();
    parser.adjustMathMLAttributes(token);
    parser.adjustForeignAttributes(token);
    token["namespace"] = Namespaces.mathml;
    tree.insertElement(token);
    //Need to get the parse error right for the case where the token
    //has a namespace not equal to the xmlns attribute
    if (token["selfClosing"]) {
      tree.openElements.removeLast();
      token["selfClosingAcknowledged"] = true;
    }
  }

  void startTagSvg(token) {
    tree.reconstructActiveFormattingElements();
    parser.adjustSVGAttributes(token);
    parser.adjustForeignAttributes(token);
    token["namespace"] = Namespaces.svg;
    tree.insertElement(token);
    //Need to get the parse error right for the case where the token
    //has a namespace not equal to the xmlns attribute
    if (token["selfClosing"]) {
      tree.openElements.removeLast();
      token["selfClosingAcknowledged"] = true;
    }
  }

  /**
   * Elements that should be children of other elements that have a
   * different insertion mode; here they are ignored
   * "caption", "col", "colgroup", "frame", "frameset", "head",
   * "option", "optgroup", "tbody", "td", "tfoot", "th", "thead",
   * "tr", "noscript"
  */
  void startTagMisplaced(token) {
    parser.parseError("unexpected-start-tag-ignored",
        {"name": token["name"]});
  }

  Map startTagOther(token) {
    tree.reconstructActiveFormattingElements();
    tree.insertElement(token);
  }

  void endTagP(token) {
    if (!tree.elementInScope("p", variant: "button")) {
      startTagCloseP(impliedTagToken("p", "StartTag"));
      parser.parseError("unexpected-end-tag", {"name": "p"});
      endTagP(impliedTagToken("p", "EndTag"));
    } else {
      tree.generateImpliedEndTags("p");
      if (tree.openElements.last().name != "p") {
        parser.parseError("unexpected-end-tag", {"name": "p"});
      }
      popOpenElementsUntil("p");
    }
  }

  void endTagBody(token) {
    if (!tree.elementInScope("body")) {
      parser.parseError();
      return;
    } else if (tree.openElements.last().name != "body") {
      for (var node in slice(tree.openElements, 2)) {
        switch (node.name) {
          case "dd": case "dt": case "li": case "optgroup": case "option":
          case "p": case "rp": case "rt": case "tbody": case "td": case "tfoot":
          case "th": case "thead": case "tr": case "body": case "html":
            continue;
        }
        // Not sure this is the correct name for the parse error
        parser.parseError("expected-one-end-tag-but-got-another",
            {"expectedName": "body", "gotName": node.name});
        break;
      }
    }
    parser.phase = parser.phases["afterBody"];
  }

  Map endTagHtml(token) {
    //We repeat the test for the body end tag token being ignored here
    if (tree.elementInScope("body")) {
      endTagBody(impliedTagToken("body"));
      return token;
    }
  }

  void endTagBlock(token) {
    //Put us back in the right whitespace handling mode
    if (token["name"] == "pre") {
      processSpaceCharactersFunc = processSpaceCharactersNonPre;
    }
    var inScope = tree.elementInScope(token["name"]);
    if (inScope) {
      tree.generateImpliedEndTags();
    }
    if (tree.openElements.last().name != token["name"]) {
      parser.parseError("end-tag-too-early", {"name": token["name"]});
    }
    if (inScope) {
      popOpenElementsUntil(token["name"]);
    }
  }

  void endTagForm(token) {
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

  void endTagListItem(token) {
    var variant;
    if (token["name"] == "li") {
      variant = "list";
    } else {
      variant = null;
    }
    if (!tree.elementInScope(token["name"], variant: variant)) {
      parser.parseError("unexpected-end-tag", {"name": token["name"]});
    } else {
      tree.generateImpliedEndTags(exclude: token["name"]);
      if (tree.openElements.last().name != token["name"]) {
        parser.parseError("end-tag-too-early", {"name": token["name"]});
      }
      popOpenElementsUntil(token["name"]);
    }
  }

  void endTagHeading(token) {
    for (var item in headingElements) {
      if (tree.elementInScope(item)) {
        tree.generateImpliedEndTags();
        break;
      }
    }
    if (tree.openElements.last().name != token["name"]) {
      parser.parseError("end-tag-too-early", {"name": token["name"]});
    }

    for (var item in headingElements) {
      if (tree.elementInScope(item)) {
        item = tree.openElements.removeLast();
        while (headingElements.indexOf(item.name) == -1) {
          item = tree.openElements.removeLast();
        }
        break;
      }
    }
  }

  /** The much-feared adoption agency algorithm. */
  endTagFormatting(token) {
    // http://www.whatwg.org/specs/web-apps/current-work///adoptionAgency
    // XXX Better parseError messages appreciated.
    int outerLoopCounter = 0;
    while (outerLoopCounter < 8) {
      outerLoopCounter += 1;

      // Step 1 paragraph 1
      var formattingElement = tree.elementInActiveFormattingElements(
          token["name"]);
      if (formattingElement == null ||
          (tree.openElements.indexOf(formattingElement) >= 0 &&
           !tree.elementInScope(formattingElement.name))) {
        parser.parseError("adoption-agency-1.1", {"name": token["name"]});
        return;
      // Step 1 paragraph 2
      } else if (tree.openElements.indexOf(formattingElement) == -1) {
        parser.parseError("adoption-agency-1.2", {"name": token["name"]});
        removeFromList(tree.activeFormattingElements, formattingElement);
        return;
      }

      // Step 1 paragraph 3
      if (formattingElement != tree.openElements.last()) {
        parser.parseError("adoption-agency-1.3", {"name": token["name"]});
      }

      // Step 2
      // Start of the adoption agency algorithm proper
      var afeIndex = tree.openElements.indexOf(formattingElement);
      var furthestBlock = null;
      for (var element in slice(tree.openElements, afeIndex)) {
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

      // Step 4
      //if (furthestBlock.parent != null) {
      //  furthestBlock.parent.removeChild(furthestBlock)

      // Step 5
      // The bookmark is supposed to help us identify where to reinsert
      // nodes in step 12. We have to ensure that we reinsert nodes after
      // the node before the active formatting element. Note the bookmark
      // can move in step 7.4
      var bookmark = tree.activeFormattingElements.indexOf(formattingElement);

      // Step 6
      var lastNode = furthestBlock;
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
        var clone = node.cloneNode();
        // Replace node with clone
        tree.activeFormattingElements[
            tree.activeFormattingElements.indexOf(node)] = clone;
        tree.openElements[tree.openElements.indexOf(node)] = clone;
        node = clone;

        // Step 6.6
        // Remove lastNode from its parents, if any
        if (lastNode.parent != null) {
          lastNode.parent.removeChild(lastNode);
        }
        node.appendChild(lastNode);
        // Step 7.7
        lastNode = node;
        // End of inner loop
      }

      // Step 7
      // Foster parent lastNode if commonAncestor is a
      // table, tbody, tfoot, thead, or tr we need to foster parent the
      // lastNode
      if (lastNode.parent != null) {
        lastNode.parent.removeChild(lastNode);
      }

      if (const ["table", "tbody", "tfoot", "thead", "tr"].indexOf(
          commonAncestor.name) >= 0) {
        var nodePos = tree.getTableMisnestedNodePosition();
        nodePos[0].insertBefore(lastNode, nodePos[1]);
      } else {
        commonAncestor.appendChild(lastNode);
      }

      // Step 8
      var clone = formattingElement.cloneNode();

      // Step 9
      furthestBlock.reparentChildren(clone);

      // Step 10
      furthestBlock.appendChild(clone);

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

  void endTagAppletMarqueeObject(token) {
    if (tree.elementInScope(token["name"])) {
      tree.generateImpliedEndTags();
    }
    if (tree.openElements.last().name != token["name"]) {
      parser.parseError("end-tag-too-early", {"name": token["name"]});
    }
    if (tree.elementInScope(token["name"])) {
      popOpenElementsUntil(token["name"]);
      tree.clearActiveFormattingElements();
    }
  }

  void endTagBr(token) {
    parser.parseError("unexpected-end-tag-treated-as",
        {"originalName": "br", "newName": "br element"});
    tree.reconstructActiveFormattingElements();
    tree.insertElement(impliedTagToken("br", "StartTag"));
    tree.openElements.removeLast();
  }

  void endTagOther(token) {
    for (var node in reversed(tree.openElements)) {
      if (node.name == token["name"]) {
        tree.generateImpliedEndTags(exclude: token["name"]);
        if (tree.openElements.last().name != token["name"]) {
          parser.parseError("unexpected-end-tag", {"name": token["name"]});
        }
        while (tree.openElements.removeLast() != node);
        break;
      } else {
        if (specialElements.indexOf(node.nameTuple) >= 0) {
          parser.parseError("unexpected-end-tag", {"name": token["name"]});
          break;
        }
      }
    }
  }
}


class TextPhase extends Phase {
  TextPhase(parser) : super(parser);

  // "Tried to process start tag %s in RCDATA/RAWTEXT mode"%token['name']
  processStartTag(token) { assert(false); }

  processEndTag(token) {
    if (token['name'] == 'script') return endTagScript(token);
    return endTagOther(token);
  }

  Map processCharacters(token) {
    tree.insertText(token["data"]);
  }

  bool processEOF() {
    parser.parseError("expected-named-closing-tag-but-got-eof",
        {'name': tree.openElements.last().name});
    tree.openElements.removeLast();
    parser.phase = parser.originalPhase;
    return true;
  }

  void endTagScript(token) {
    var node = tree.openElements.removeLast();
    assert(node.name == "script");
    parser.phase = parser.originalPhase;
    //The rest of this method is all stuff that only happens if
    //document.write works
  }

  void endTagOther(token) {
    var node = tree.openElements.removeLast();
    parser.phase = parser.originalPhase;
  }
}

class InTablePhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-table
  InTablePhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
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

  processEndTag(token) {
    switch (token['name']) {
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
    while (tree.openElements.last().name != "table" &&
           tree.openElements.last().name != "html") {
      //parser.parseError("unexpected-implied-end-tag-in-table",
      //  {"name":  tree.openElements.last().name})
      tree.openElements.removeLast();
    }
    // When the current node is <html> it's an innerHTML case
  }

  // processing methods
  bool processEOF() {
    if (tree.openElements.last().name != "html") {
      parser.parseError("eof-in-table");
    } else {
      assert(parser.innerHTMLMode);
    }
    //Stop parsing
    return false;
  }

  Map processSpaceCharacters(token) {
    var originalPhase = parser.phase;
    parser.phase = parser.phases["inTableText"];
    (parser.phase as InTableTextPhase).originalPhase = originalPhase;
    parser.phase.processSpaceCharacters(token);
  }

  Map processCharacters(token) {
    var originalPhase = parser.phase;
    parser.phase = parser.phases["inTableText"];
    (parser.phase as InTableTextPhase).originalPhase = originalPhase;
    parser.phase.processCharacters(token);
  }

  void insertText(token) {
    // If we get here there must be at least one non-whitespace character
    // Do the table magic!
    tree.insertFromTable = true;
    parser.phases["inBody"].processCharacters(token);
    tree.insertFromTable = false;
  }

  void startTagCaption(token) {
    clearStackToTableContext();
    tree.activeFormattingElements.add(Marker);
    tree.insertElement(token);
    parser.phase = parser.phases["inCaption"];
  }

  void startTagColgroup(token) {
    clearStackToTableContext();
    tree.insertElement(token);
    parser.phase = parser.phases["inColumnGroup"];
  }

  Map startTagCol(token) {
    startTagColgroup(impliedTagToken("colgroup", "StartTag"));
    return token;
  }

  void startTagRowGroup(token) {
    clearStackToTableContext();
    tree.insertElement(token);
    parser.phase = parser.phases["inTableBody"];
  }

  Map startTagImplyTbody(token) {
    startTagRowGroup(impliedTagToken("tbody", "StartTag"));
    return token;
  }

  Map startTagTable(token) {
    parser.parseError("unexpected-start-tag-implies-end-tag",
        {"startName": "table", "endName": "table"});
    parser.phase.processEndTag(impliedTagToken("table"));
    if (!parser.innerHTMLMode) {
      return token;
    }
  }

  Map startTagStyleScript(token) {
    return parser.phases["inHead"].processStartTag(token);
  }

  void startTagInput(token) {
    if (asciiUpper2Lower(token["data"]["type"]) == "hidden") {
      parser.parseError("unexpected-hidden-input-in-table");
      tree.insertElement(token);
      // XXX associate with form
      tree.openElements.removeLast();
    } else {
      startTagOther(token);
    }
  }

  void startTagForm(token) {
    parser.parseError("unexpected-form-in-table");
    if (tree.formPointer === null) {
      tree.insertElement(token);
      tree.formPointer = tree.openElements.last();
      tree.openElements.removeLast();
    }
  }

  void startTagOther(token) {
    parser.parseError("unexpected-start-tag-implies-table-voodoo",
        {"name": token["name"]});
    // Do the table magic!
    tree.insertFromTable = true;
    parser.phases["inBody"].processStartTag(token);
    tree.insertFromTable = false;
  }

  void endTagTable(token) {
    if (tree.elementInScope("table", variant: "table")) {
      tree.generateImpliedEndTags();
      if (tree.openElements.last().name != "table") {
        parser.parseError("end-tag-too-early-named", {"gotName": "table",
            "expectedName": tree.openElements.last().name});
      }
      while (tree.openElements.last().name != "table") {
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

  void endTagIgnore(token) {
    parser.parseError("unexpected-end-tag", {"name": token["name"]});
  }

  void endTagOther(token) {
    parser.parseError("unexpected-end-tag-implies-table-voodoo",
        {"name": token["name"]});
    // Do the table magic!
    tree.insertFromTable = true;
    parser.phases["inBody"].processEndTag(token);
    tree.insertFromTable = false;
  }
}

class InTableTextPhase extends Phase {
  Phase originalPhase;
  List characterTokens;

  InTableTextPhase(parser) : super(parser), characterTokens = [];

  void flushCharacters() {
    var data = joinStr(characterTokens.map((t) => t["data"]));
    if (!allWhitespace(data)) {
      var token = {"type": CharactersToken, "data": data};
      (parser.phases["inTable"] as InTablePhase).insertText(token);
    } else if (data.length > 0) {
      tree.insertText(data);
    }
    characterTokens = [];
  }

  Map processComment(token) {
    flushCharacters();
    parser.phase = originalPhase;
    return token;
  }

  bool processEOF() {
    flushCharacters();
    parser.phase = originalPhase;
    return true;
  }

  Map processCharacters(token) {
    if (token["data"] == "\u0000") {
      return null;
    }
    characterTokens.add(token);
  }

  Map processSpaceCharacters(token) {
    //pretty sure we should never reach here
    characterTokens.add(token);
    // XXX assert(false);
  }

  Map processStartTag(token) {
    flushCharacters();
    parser.phase = originalPhase;
    return token;
  }

  Map processEndTag(token) {
    flushCharacters();
    parser.phase = originalPhase;
    return token;
  }
}


class InCaptionPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-caption
  InCaptionPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case "html": return startTagHtml(token);
      case "caption": case "col": case "colgroup": case "tbody": case "td":
      case "tfoot": case "th": case "thead": case "tr":
        return startTagTableElement(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(token) {
    switch (token['name']) {
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
    parser.phases["inBody"].processEOF();
    return false;
  }

  Map processCharacters(token) {
    return parser.phases["inBody"].processCharacters(token);
  }

  Map startTagTableElement(token) {
    parser.parseError();
    //XXX Have to duplicate logic here to find out if the tag is ignored
    var ignoreEndTag = ignoreEndTagCaption();
    parser.phase.processEndTag(impliedTagToken("caption"));
    if (!ignoreEndTag) {
      return token;
    }
    return null;
  }

  Map startTagOther(token) {
    return parser.phases["inBody"].processStartTag(token);
  }

  void endTagCaption(token) {
    if (!ignoreEndTagCaption()) {
      // AT this code is quite similar to endTagTable in "InTable"
      tree.generateImpliedEndTags();
      if (tree.openElements.last().name != "caption") {
        parser.parseError("expected-one-end-tag-but-got-another",
          {"gotName": "caption",
           "expectedName": tree.openElements.last().name});
      }
      while (tree.openElements.last().name != "caption") {
        tree.openElements.removeLast();
      }
      tree.openElements.removeLast();
      tree.clearActiveFormattingElements();
      parser.phase = parser.phases["inTable"];
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
  }

  Map endTagTable(token) {
    parser.parseError();
    var ignoreEndTag = ignoreEndTagCaption();
    parser.phase.processEndTag(impliedTagToken("caption"));
    if (!ignoreEndTag) {
      return token;
    }
    return null;
  }

  void endTagIgnore(token) {
    parser.parseError("unexpected-end-tag", {"name": token["name"]});
  }

  Map endTagOther(token) {
    return parser.phases["inBody"].processEndTag(token);
  }
}


class InColumnGroupPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-column
  InColumnGroupPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case "html": return startTagHtml(token);
      case "col": return startTagCol(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(token) {
    switch (token['name']) {
      case "colgroup": return endTagColgroup(token);
      case "col": return endTagCol(token);
      default: return endTagOther(token);
    }
  }

  bool ignoreEndTagColgroup() {
    return tree.openElements.last().name == "html";
  }

  bool processEOF() {
    var ignoreEndTag = ignoreEndTagColgroup();
    if (ignoreEndTag) {
      assert(parser.innerHTMLMode);
      return false;
    } else {
      endTagColgroup(impliedTagToken("colgroup"));
      return true;
    }
  }

  Map processCharacters(token) {
    var ignoreEndTag = ignoreEndTagColgroup();
    endTagColgroup(impliedTagToken("colgroup"));
    return ignoreEndTag ? null : token;
  }

  void startTagCol(token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
  }

  Map startTagOther(token) {
    var ignoreEndTag = ignoreEndTagColgroup();
    endTagColgroup(impliedTagToken("colgroup"));
    return ignoreEndTag ? null : token;
  }

  void endTagColgroup(token) {
    if (ignoreEndTagColgroup()) {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    } else {
      tree.openElements.removeLast();
      parser.phase = parser.phases["inTable"];
    }
  }

  void endTagCol(token) {
    parser.parseError("no-end-tag", {"name": "col"});
  }

  Map endTagOther(token) {
    var ignoreEndTag = ignoreEndTagColgroup();
    endTagColgroup(impliedTagToken("colgroup"));
    return ignoreEndTag ? null : token;
  }
}


class InTableBodyPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-table0
  InTableBodyPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case "html": return startTagHtml(token);
      case "tr": return startTagTr(token);
      case "td": case "th": return startTagTableCell(token);
      case "caption": case "col": case "colgroup": case "tbody": case "tfoot":
      case "thead":
        return startTagTableOther(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(token) {
    switch (token['name']) {
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
        tree.openElements.last().name) == -1) {
      //XXX parser.parseError("unexpected-implied-end-tag-in-table",
      //  {"name": tree.openElements.last().name})
      tree.openElements.removeLast();
    }
    if (tree.openElements.last().name == "html") {
      assert(parser.innerHTMLMode);
    }
  }

  // the rest
  bool processEOF() {
    parser.phases["inTable"].processEOF();
    return false;
  }

  Map processSpaceCharacters(token) {
    return parser.phases["inTable"].processSpaceCharacters(token);
  }

  Map processCharacters(token) {
    return parser.phases["inTable"].processCharacters(token);
  }

  void startTagTr(token) {
    clearStackToTableBodyContext();
    tree.insertElement(token);
    parser.phase = parser.phases["inRow"];
  }

  Map startTagTableCell(token) {
    parser.parseError("unexpected-cell-in-table-body",
        {"name": token["name"]});
    startTagTr(impliedTagToken("tr", "StartTag"));
    return token;
  }

  Map startTagTableOther(token) => endTagTable(token);

  Map startTagOther(token) {
    return parser.phases["inTable"].processStartTag(token);
  }

  void endTagTableRowGroup(token) {
    if (tree.elementInScope(token["name"], variant: "table")) {
      clearStackToTableBodyContext();
      tree.openElements.removeLast();
      parser.phase = parser.phases["inTable"];
    } else {
      parser.parseError("unexpected-end-tag-in-table-body",
          {"name": token["name"]});
    }
  }

  Map endTagTable(token) {
    // XXX AT Any ideas on how to share this with endTagTable?
    if (tree.elementInScope("tbody", variant: "table") ||
        tree.elementInScope("thead", variant: "table") ||
        tree.elementInScope("tfoot", variant: "table")) {
      clearStackToTableBodyContext();
      endTagTableRowGroup(
          impliedTagToken(tree.openElements.last().name));
      return token;
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
    return null;
  }

  void endTagIgnore(token) {
    parser.parseError("unexpected-end-tag-in-table-body",
        {"name": token["name"]});
  }

  Map endTagOther(token) {
    return parser.phases["inTable"].processEndTag(token);
  }
}


class InRowPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-row
  InRowPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case "html": return startTagHtml(token);
      case "td": case "th": return startTagTableCell(token);
      case "caption": case "col": case "colgroup": case "tbody": case "tfoot":
      case "thead": case "tr":
        return startTagTableOther(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(token) {
    switch (token['name']) {
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
    while (tree.openElements.last().name != "tr" &&
        tree.openElements.last().name != "html") {
      parser.parseError("unexpected-implied-end-tag-in-table-row",
        {"name": tree.openElements.last().name});
      tree.openElements.removeLast();
    }
  }

  bool ignoreEndTagTr() {
    return !tree.elementInScope("tr", variant: "table");
  }

  // the rest
  bool processEOF() {
    parser.phases["inTable"].processEOF();
    return false;
  }

  Map processSpaceCharacters(token) {
    return parser.phases["inTable"].processSpaceCharacters(token);
  }

  Map processCharacters(token) {
    return parser.phases["inTable"].processCharacters(token);
  }

  void startTagTableCell(token) {
    clearStackToTableRowContext();
    tree.insertElement(token);
    parser.phase = parser.phases["inCell"];
    tree.activeFormattingElements.add(Marker);
  }

  Map startTagTableOther(token) {
    bool ignoreEndTag = ignoreEndTagTr();
    endTagTr(impliedTagToken("tr"));
    // XXX how are we sure it's always ignored in the innerHTML case?
    return ignoreEndTag ? null : token;
  }

  Map startTagOther(token) {
    return parser.phases["inTable"].processStartTag(token);
  }

  void endTagTr(token) {
    if (!ignoreEndTagTr()) {
      clearStackToTableRowContext();
      tree.openElements.removeLast();
      parser.phase = parser.phases["inTableBody"];
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
  }

  Map endTagTable(token) {
    var ignoreEndTag = ignoreEndTagTr();
    endTagTr(impliedTagToken("tr"));
    // Reprocess the current tag if the tr end tag was not ignored
    // XXX how are we sure it's always ignored in the innerHTML case?
    return ignoreEndTag ? null : token;
  }

  Map endTagTableRowGroup(token) {
    if (tree.elementInScope(token["name"], variant: "table")) {
      endTagTr(impliedTagToken("tr"));
      return token;
    } else {
      parser.parseError();
      return null;
    }
  }

  void endTagIgnore(token) {
    parser.parseError("unexpected-end-tag-in-table-row",
        {"name": token["name"]});
  }

  Map endTagOther(token) {
    return parser.phases["inTable"].processEndTag(token);
  }
}

class InCellPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-cell
  InCellPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case "html": return startTagHtml(token);
      case "caption": case "col": case "colgroup": case "tbody": case "td":
      case "tfoot": case "th": case "thead": case "tr":
        return startTagTableOther(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(token) {
    switch (token['name']) {
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
      endTagTableCell(impliedTagToken("td"));
    } else if (tree.elementInScope("th", variant: "table")) {
      endTagTableCell(impliedTagToken("th"));
    }
  }

  // the rest
  bool processEOF() {
    parser.phases["inBody"].processEOF();
    return false;
  }

  Map processCharacters(token) {
    return parser.phases["inBody"].processCharacters(token);
  }

  Map startTagTableOther(token) {
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

  Map startTagOther(token) {
    return parser.phases["inBody"].processStartTag(token);
  }

  void endTagTableCell(token) {
    if (tree.elementInScope(token["name"], variant: "table")) {
      tree.generateImpliedEndTags(token["name"]);
      if (tree.openElements.last().name != token["name"]) {
        parser.parseError("unexpected-cell-end-tag", {"name": token["name"]});
        popOpenElementsUntil(token["name"]);
      } else {
        tree.openElements.removeLast();
      }
      tree.clearActiveFormattingElements();
      parser.phase = parser.phases["inRow"];
    } else {
      parser.parseError("unexpected-end-tag", {"name": token["name"]});
    }
  }

  void endTagIgnore(token) {
    parser.parseError("unexpected-end-tag", {"name": token["name"]});
  }

  Map endTagImply(token) {
    if (tree.elementInScope(token["name"], variant: "table")) {
      closeCell();
      return token;
    } else {
      // sometimes innerHTML case
      parser.parseError();
    }
  }

  Map endTagOther(token) {
    return parser.phases["inBody"].processEndTag(token);
  }
}

class InSelectPhase extends Phase {
  InSelectPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
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

  processEndTag(token) {
    switch (token['name']) {
      case "option": return endTagOption(token);
      case "optgroup": return endTagOptgroup(token);
      case "select": return endTagSelect(token);
      default: return endTagOther(token);
    }
  }

  // http://www.whatwg.org/specs/web-apps/current-work///in-select
  bool processEOF() {
    if (tree.openElements.last().name != "html") {
      parser.parseError("eof-in-select");
    } else {
      assert(parser.innerHTMLMode);
    }
    return false;
  }

  Map processCharacters(token) {
    if (token["data"] == "\u0000") {
      return null;
    }
    tree.insertText(token["data"]);
  }

  void startTagOption(token) {
    // We need to imply </option> if <option> is the current node.
    if (tree.openElements.last().name == "option") {
      tree.openElements.removeLast();
    }
    tree.insertElement(token);
  }

  void startTagOptgroup(token) {
    if (tree.openElements.last().name == "option") {
      tree.openElements.removeLast();
    }
    if (tree.openElements.last().name == "optgroup") {
      tree.openElements.removeLast();
    }
    tree.insertElement(token);
  }

  void startTagSelect(token) {
    parser.parseError("unexpected-select-in-select");
    endTagSelect(impliedTagToken("select"));
  }

  Map startTagInput(token) {
    parser.parseError("unexpected-input-in-select");
    if (tree.elementInScope("select", variant: "select")) {
      endTagSelect(impliedTagToken("select"));
      return token;
    } else {
      assert(parser.innerHTMLMode);
    }
  }

  Map startTagScript(token) {
    return parser.phases["inHead"].processStartTag(token);
  }

  Map startTagOther(token) {
    parser.parseError("unexpected-start-tag-in-select",
        {"name": token["name"]});
  }

  void endTagOption(token) {
    if (tree.openElements.last().name == "option") {
      tree.openElements.removeLast();
    } else {
      parser.parseError("unexpected-end-tag-in-select",
          {"name": "option"});
    }
  }

  void endTagOptgroup(token) {
    // </optgroup> implicitly closes <option>
    if (tree.openElements.last().name == "option" &&
      tree.openElements[tree.openElements.length - 2].name == "optgroup") {
      tree.openElements.removeLast();
    }
    // It also closes </optgroup>
    if (tree.openElements.last().name == "optgroup") {
      tree.openElements.removeLast();
    // But nothing else
    } else {
      parser.parseError("unexpected-end-tag-in-select",
        {"name": "optgroup"});
    }
  }

  void endTagSelect(token) {
    if (tree.elementInScope("select", variant: "select")) {
      popOpenElementsUntil("select");
      parser.resetInsertionMode();
    } else {
      // innerHTML case
      assert(parser.innerHTMLMode);
      parser.parseError();
    }
  }

  void endTagOther(token) {
    parser.parseError("unexpected-end-tag-in-select",
        {"name": token["name"]});
  }
}


class InSelectInTablePhase extends Phase {
  InSelectInTablePhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case "caption": case "table": case "tbody": case "tfoot": case "thead":
      case "tr": case "td": case "th":
        return startTagTable(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(token) {
    switch (token['name']) {
      case "caption": case "table": case "tbody": case "tfoot": case "thead":
      case "tr": case "td": case "th":
        return endTagTable(token);
      default: return endTagOther(token);
    }
  }

  bool processEOF() {
    parser.phases["inSelect"].processEOF();
    return false;
  }

  Map processCharacters(token) {
    return parser.phases["inSelect"].processCharacters(token);
  }

  Map startTagTable(token) {
    parser.parseError("unexpected-table-element-start-tag-in-select-in-table",
        {"name": token["name"]});
    endTagOther(impliedTagToken("select"));
    return token;
  }

  Map startTagOther(token) {
    return parser.phases["inSelect"].processStartTag(token);
  }

  Map endTagTable(token) {
    parser.parseError("unexpected-table-element-end-tag-in-select-in-table",
        {"name": token["name"]});
    if (tree.elementInScope(token["name"], variant: "table")) {
      endTagOther(impliedTagToken("select"));
      return token;
    }
  }

  Map endTagOther(token) {
    return parser.phases["inSelect"].processEndTag(token);
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

    var replace = replacements[token["name"]];
    if (replace != null) {
      token["name"] = replace;
    }
  }

  Map processCharacters(token) {
    if (token["data"] == "\u0000") {
      token["data"] = "\uFFFD";
    } else if (parser.framesetOK && !allWhitespace(token["data"])) {
      parser.framesetOK = false;
    }
    super.processCharacters(token);
  }

  Map processStartTag(token) {
    var currentNode = tree.openElements.last();
    if (breakoutElements.indexOf(token["name"]) >= 0 ||
        (token["name"] == "font" &&
         (token["data"].containsKey("color") ||
          token["data"].containsKey("face") ||
          token["data"].containsKey("size")))) {

      parser.parseError("unexpected-html-element-in-foreign-content",
          {'name': token["name"]});
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
      token["namespace"] = currentNode.namespace;
      tree.insertElement(token);
      if (token["selfClosing"]) {
        tree.openElements.removeLast();
        token["selfClosingAcknowledged"] = true;
      }
    }
  }

  Map processEndTag(token) {
    var nodeIndex = tree.openElements.length - 1;
    var node = tree.openElements.last();
    if (node.name != token["name"]) {
      parser.parseError("unexpected-end-tag", {"name": token["name"]});
    }

    var newToken = null;
    while (true) {
      if (asciiUpper2Lower(node.name) == token["name"]) {
        //XXX this isn't in the spec but it seems necessary
        if (parser.phase == parser.phases["inTableText"]) {
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

  processStartTag(token) {
    if (token['name'] == "html") return startTagHtml(token);
    return startTagOther(token);
  }

  processEndTag(token) {
    if (token['name'] == "html") return endTagHtml(token);
    return endTagOther(token);
  }

  //Stop parsing
  bool processEOF() => false;

  Map processComment(token) {
    // This is needed because data is to be appended to the <html> element
    // here and not to whatever is currently open.
    tree.insertComment(token, tree.openElements[0]);
  }

  Map processCharacters(token) {
    parser.parseError("unexpected-char-after-body");
    parser.phase = parser.phases["inBody"];
    return token;
  }

  Map startTagHtml(token) {
    return parser.phases["inBody"].processStartTag(token);
  }

  Map startTagOther(token) {
    parser.parseError("unexpected-start-tag-after-body",
        {"name": token["name"]});
    parser.phase = parser.phases["inBody"];
    return token;
  }

  void endTagHtml(name) {
    if (parser.innerHTMLMode) {
      parser.parseError("unexpected-end-tag-after-body-innerhtml");
    } else {
      parser.phase = parser.phases["afterAfterBody"];
    }
  }

  Map endTagOther(token) {
    parser.parseError("unexpected-end-tag-after-body",
        {"name": token["name"]});
    parser.phase = parser.phases["inBody"];
    return token;
  }
}

class InFramesetPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///in-frameset
  InFramesetPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case "html": return startTagHtml(token);
      case "frameset": return startTagFrameset(token);
      case "frame": return startTagFrame(token);
      case "noframes": return startTagNoframes(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(token) {
    switch (token['name']) {
      case "frameset": return endTagFrameset(token);
      default: return endTagOther(token);
    }
  }

  bool processEOF() {
    if (tree.openElements.last().name != "html") {
      parser.parseError("eof-in-frameset");
    } else {
      assert(parser.innerHTMLMode);
    }
    return false;
  }

  Map processCharacters(token) {
    parser.parseError("unexpected-char-in-frameset");
  }

  void startTagFrameset(token) {
    tree.insertElement(token);
  }

  void startTagFrame(token) {
    tree.insertElement(token);
    tree.openElements.removeLast();
  }

  Map startTagNoframes(token) {
    return parser.phases["inBody"].processStartTag(token);
  }

  Map startTagOther(token) {
    parser.parseError("unexpected-start-tag-in-frameset",
        {"name": token["name"]});
  }

  void endTagFrameset(token) {
    if (tree.openElements.last().name == "html") {
      // innerHTML case
      parser.parseError("unexpected-frameset-in-frameset-innerhtml");
    } else {
      tree.openElements.removeLast();
    }
    if (!parser.innerHTMLMode && tree.openElements.last().name != "frameset") {
      // If we're not in innerHTML mode and the the current node is not a
      // "frameset" element (anymore) then switch.
      parser.phase = parser.phases["afterFrameset"];
    }
  }

  void endTagOther(token) {
    parser.parseError("unexpected-end-tag-in-frameset",
        {"name": token["name"]});
  }
}


class AfterFramesetPhase extends Phase {
  // http://www.whatwg.org/specs/web-apps/current-work///after3
  AfterFramesetPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case "html": return startTagHtml(token);
      case "noframes": return startTagNoframes(token);
      default: return startTagOther(token);
    }
  }

  processEndTag(token) {
    switch (token['name']) {
      case "html": return endTagHtml(token);
      default: return endTagOther(token);
    }
  }

  //Stop parsing
  bool processEOF() => false;

  Map processCharacters(token) {
    parser.parseError("unexpected-char-after-frameset");
  }

  Map startTagNoframes(token) {
    return parser.phases["inHead"].processStartTag(token);
  }

  void startTagOther(token) {
    parser.parseError("unexpected-start-tag-after-frameset",
        {"name": token["name"]});
  }

  void endTagHtml(token) {
    parser.phase = parser.phases["afterAfterFrameset"];
  }

  void endTagOther(token) {
    parser.parseError("unexpected-end-tag-after-frameset",
        {"name": token["name"]});
  }
}


class AfterAfterBodyPhase extends Phase {
  AfterAfterBodyPhase(parser) : super(parser);

  processStartTag(token) {
    if (token['name'] == 'html') return startTagHtml(token);
    return startTagOther(token);
  }

  bool processEOF() => false;

  Map processComment(token) {
    tree.insertComment(token, tree.document);
  }

  Map processSpaceCharacters(token) {
    return parser.phases["inBody"].processSpaceCharacters(token);
  }

  Map processCharacters(token) {
    parser.parseError("expected-eof-but-got-char");
    parser.phase = parser.phases["inBody"];
    return token;
  }

  Map startTagHtml(token) {
    return parser.phases["inBody"].processStartTag(token);
  }

  Map startTagOther(token) {
    parser.parseError("expected-eof-but-got-start-tag",
      {"name": token["name"]});
    parser.phase = parser.phases["inBody"];
    return token;
  }

  Map processEndTag(token) {
    parser.parseError("expected-eof-but-got-end-tag",
      {"name": token["name"]});
    parser.phase = parser.phases["inBody"];
    return token;
  }
}

class AfterAfterFramesetPhase extends Phase {
  AfterAfterFramesetPhase(parser) : super(parser);

  processStartTag(token) {
    switch (token['name']) {
      case "html": return startTagHtml(token);
      case "noframes": return startTagNoFrames(token);
      default: return startTagOther(token);
    }
  }

  bool processEOF() => false;

  Map processComment(token) {
    tree.insertComment(token, tree.document);
  }

  Map processSpaceCharacters(token) {
    return parser.phases["inBody"].processSpaceCharacters(token);
  }

  Map processCharacters(token) {
    parser.parseError("expected-eof-but-got-char");
  }

  Map startTagHtml(token) {
    return parser.phases["inBody"].processStartTag(token);
  }

  Map startTagNoFrames(token) {
    return parser.phases["inHead"].processStartTag(token);
  }

  void startTagOther(token) {
    parser.parseError("expected-eof-but-got-start-tag",
        {"name": token["name"]});
  }

  Map processEndTag(token) {
    parser.parseError("expected-eof-but-got-end-tag",
        {"name": token["name"]});
  }
}


Map impliedTagToken(String name, [String type = "EndTag",
    Map attributes, bool selfClosing = false]) {
  if (attributes == null) attributes = {};
  return {"type": tokenTypes[type], "name": name, "data": attributes,
      "selfClosing": selfClosing};
}

/** Error in parsed document. */
class ParseError implements Exception {
  final String errorCode;
  final int line;
  final int column;
  final Map data;

  ParseError(this.errorCode, this.line, this.column, this.data);

  String get message => formatStr(errorMessages[errorCode], data);

  String toString() => "ParseError at line $line column $column: $message";
}
