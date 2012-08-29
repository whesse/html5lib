#library('token');

class Token {
  // TODO(jmesserly): rename to "kind"
  abstract int get type;

  // TODO(jmesserly): remove this?
  abstract get data;
}

class TagToken {
  String name;

  // Note: this starts as a List, but becomes a Map of attributes...
  var data;

  bool selfClosing;

  TagToken(this.name, this.data, this.selfClosing);
}

class StartTagToken extends TagToken {
  bool selfClosingAcknowledged;

  /** The namespace. This is filled in later during tree building. */
  String namespace;

  StartTagToken([String name, data, bool selfClosing = false,
      this.selfClosingAcknowledged = false, this.namespace])
      : super(name, data, selfClosing);

  int get type => TokenKind.startTag;
}

class EndTagToken extends TagToken {

  EndTagToken([String name, data, bool selfClosing = false])
      : super(name, data, selfClosing);

  int get type => TokenKind.endTag;
}

class StringToken extends Token {
  String data;
  StringToken(this.data);
}

class ParseErrorToken extends StringToken {
  // TODO(jmesserly): rename this
  Map datavars;

  ParseErrorToken([String data, this.datavars]) : super(data);

  int get type => TokenKind.parseError;
}

class CharactersToken extends StringToken {
  CharactersToken([String data]) : super(data);

  int get type => TokenKind.characters;
}

class SpaceCharactersToken extends StringToken {
  SpaceCharactersToken([String data]) : super(data);

  int get type => TokenKind.spaceCharacters;
}

class CommentToken extends StringToken {
  CommentToken([String data]) : super(data);

  int get type => TokenKind.comment;
}

class DoctypeToken extends Token {
  String publicId;
  String systemId;
  bool correct;

  String get name => "";

  int get type => TokenKind.doctype;
}


class TokenKind {
  static const int spaceCharacters = 0;
  static const int characters = 1;
  static const int startTag = 2;
  static const int endTag = 3;
  static const int comment = 4;
  static const int doctype = 5;
  static const int parseError = 6;
}
