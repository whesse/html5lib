library client_server_io;

/**
 * Library of IO methods that can be implemented either on the client or server.
 * Over time, this library is expected to grow.
 */
class DecoderException implements Exception {
  const DecoderException([String this.message]);
  String toString() => "DecoderException: $message";
  final String message;
}
