/**
 * This library adds `dart:io` support to the HTML5 parser. Call
 * [initDartIOSupport] before calling the [parse] methods and they will accept
 * a [RandomAccessFile] as input, in addition to the other input types.
 */
library parser_io;

import 'dart:io';
import 'parser.dart';
import 'src/inputstream.dart' as inputstream;

/**
 * Adds support to the [HtmlParser] to handle `dart:io`. In particular, it will
 * be able to handle [RandomAccessFile]s as input to the various [parse]
 * methods.
 */
void initDartIOSupport() {
  inputstream.ioSupport = new _IOSupport();
}

class _IOSupport extends inputstream.IOSupport {
  List<int> bytesFromFile(source) {
    if (source is! RandomAccessFile) return null;
    return readAllBytesFromFile(source);
  }
}

// TODO(jmesserly): this should be `RandomAccessFile.readAllBytes`.
/** Synchronously reads all bytes from the [file]. */
List<int> readAllBytesFromFile(RandomAccessFile file) {
  int length = file.lengthSync();
  var bytes = new List<int>(length);

  int bytesRead = 0;
  while (bytesRead < length) {
    int read = file.readListSync(bytes, bytesRead, length - bytesRead);
    if (read <= 0) {
      // This could happen if, for example, the file was resized while
      // we're reading. Just shrink the bytes array and move on.
      bytes = bytes.getRange(0, bytesRead);
      break;
    }
    bytesRead += read;
  }
  return bytes;
}
