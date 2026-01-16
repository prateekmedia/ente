import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

enum AttachmentContentType { document, image, unknown }

class AttachmentContent {
  final AttachmentContentType type;
  final String? text;

  const AttachmentContent({
    required this.type,
    this.text,
  });

  bool get isDocument => type == AttachmentContentType.document;
  bool get isImage => type == AttachmentContentType.image;
}

class AttachmentTextExtractor {
  static Future<AttachmentContent> extractFromFile(
    File file, {
    String? fileName,
  }) async {
    final bytes = await file.readAsBytes();
    return extractFromBytes(Uint8List.fromList(bytes), fileName: fileName);
  }

  static Future<AttachmentContent> extractFromBytes(
    Uint8List bytes, {
    String? fileName,
  }) async {
    if (bytes.isEmpty) {
      return const AttachmentContent(type: AttachmentContentType.unknown);
    }

    final normalizedName = fileName?.toLowerCase();
    if (_looksLikeImage(bytes, normalizedName)) {
      return const AttachmentContent(type: AttachmentContentType.image);
    }

    if (_looksLikePdf(bytes, normalizedName)) {
      final pdfText = _extractPdfText(bytes);
      return _documentResult(pdfText);
    }

    final docxText = _extractDocxText(bytes, normalizedName);
    if (docxText != null) {
      return _documentResult(docxText);
    }

    final decoded = _decodeText(bytes);
    if (decoded == null) {
      return const AttachmentContent(type: AttachmentContentType.unknown);
    }

    return _documentResult(decoded);
  }

  static AttachmentContent _documentResult(String? text) {
    final cleaned = (text ?? '').trim();
    if (cleaned.isEmpty) {
      return const AttachmentContent(type: AttachmentContentType.unknown);
    }
    return AttachmentContent(type: AttachmentContentType.document, text: cleaned);
  }

  static String? detectExtension(
    Uint8List bytes, {
    String? fileName,
  }) {
    final normalizedName = fileName?.toLowerCase();
    final imageExtension = _detectImageExtension(bytes, normalizedName);
    if (imageExtension != null) return imageExtension;
    if (_looksLikePdf(bytes, normalizedName)) return '.pdf';
    if (_looksLikeDocx(bytes, normalizedName)) return '.docx';
    if (_decodeText(bytes) != null) return '.txt';
    return null;
  }

  static bool _looksLikePdf(Uint8List bytes, String? name) {
    if (name != null && name.endsWith('.pdf')) {
      return true;
    }
    if (bytes.length < 4) return false;
    return bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46;
  }

  static bool _looksLikeImage(Uint8List bytes, String? name) {
    return _detectImageExtension(bytes, name) != null;
  }

  static String? _detectImageExtension(Uint8List bytes, String? name) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return '.png';
    }

    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return '.jpg';
    }

    if (bytes.length >= 4 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return '.gif';
    }

    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }

    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
      return '.bmp';
    }

    if (bytes.length >= 12 &&
        bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      final brand = String.fromCharCodes(bytes.sublist(8, 12));
      if (brand.startsWith('heic') ||
          brand.startsWith('heif') ||
          brand.startsWith('heix') ||
          brand.startsWith('mif1')) {
        return '.heic';
      }
    }

    if (name != null) {
      if (name.endsWith('.png')) return '.png';
      if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return '.jpg';
      if (name.endsWith('.gif')) return '.gif';
      if (name.endsWith('.webp')) return '.webp';
      if (name.endsWith('.bmp')) return '.bmp';
      if (name.endsWith('.heic')) return '.heic';
      if (name.endsWith('.heif')) return '.heif';
    }

    return null;
  }

  static bool _looksLikeZip(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return bytes[0] == 0x50 && bytes[1] == 0x4b;
  }

  static Archive? _decodeZip(Uint8List bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  static bool _looksLikeDocx(Uint8List bytes, String? name) {
    if (name != null && name.endsWith('.docx')) {
      return true;
    }
    if (!_looksLikeZip(bytes)) return false;
    final archive = _decodeZip(bytes);
    if (archive == null) return false;
    return archive.files.any((file) => file.name == 'word/document.xml');
  }

  static String? _extractDocxText(Uint8List bytes, String? name) {
    final normalizedName = name?.toLowerCase();
    if (normalizedName != null &&
        !normalizedName.endsWith('.docx') &&
        !_looksLikeZip(bytes)) {
      return null;
    }

    final archive = _decodeZip(bytes);
    if (archive == null) return null;

    ArchiveFile? documentFile;
    for (final file in archive.files) {
      if (file.name == 'word/document.xml') {
        documentFile = file;
        break;
      }
    }
    if (documentFile == null) return null;

    final xmlString = utf8.decode(
      documentFile.content as List<int>,
      allowMalformed: true,
    );

    XmlDocument document;
    try {
      document = XmlDocument.parse(xmlString);
    } catch (_) {
      return null;
    }
    final buffer = StringBuffer();

    for (final paragraph in document.findAllElements('p')) {
      final paragraphBuffer = StringBuffer();
      for (final node in paragraph.descendants) {
        if (node is XmlElement) {
          final local = node.name.local;
          if (local == 't') {
            paragraphBuffer.write(node.innerText);
          } else if (local == 'tab') {
            paragraphBuffer.write('\t');
          } else if (local == 'br') {
            paragraphBuffer.write('\n');
          }
        }
      }
      final paragraphText = paragraphBuffer.toString().trimRight();
      if (paragraphText.isNotEmpty) {
        buffer.writeln(paragraphText);
      }
    }

    final result = buffer.toString().trim();
    return result.isEmpty ? null : result;
  }

  static String? _extractPdfText(Uint8List bytes) {
    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: bytes);
      final text = PdfTextExtractor(document).extractText();
      return text;
    } catch (_) {
      return null;
    } finally {
      document?.dispose();
    }
  }

  static String? _decodeText(Uint8List bytes) {
    final decoded = utf8.decode(bytes, allowMalformed: true);
    final cleaned = decoded.replaceAll('\u0000', '').trim();
    if (cleaned.isEmpty) return null;
    if (!_looksLikeText(cleaned)) return null;
    return cleaned;
  }

  static bool _looksLikeText(String value) {
    if (value.isEmpty) return false;
    final sample = value.runes.take(1024);
    int total = 0;
    int control = 0;
    for (final rune in sample) {
      total += 1;
      if (rune == 0x00) {
        control += 1;
        continue;
      }
      if (rune < 0x09 || (rune > 0x0d && rune < 0x20)) {
        control += 1;
      }
    }
    if (total == 0) return false;
    return control / total < 0.12;
  }
}
