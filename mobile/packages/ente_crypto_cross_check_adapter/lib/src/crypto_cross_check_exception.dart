class CryptoCrossCheckException implements Exception {
  final String label;

  CryptoCrossCheckException(this.label);

  @override
  String toString() => 'CryptoCrossCheckException: $label';
}
