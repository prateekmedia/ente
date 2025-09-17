import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';

final _logger = Logger("WidgetImageOperations");

class WidgetImageOperations {
  static const int kDefaultMaxSize = 2048;
  static const int kDefaultQuality = 100;

  /// Process widget image with proper EXIF handling and sizing
  /// Runs in isolate via Computer.shared() to avoid blocking UI
  static Future<Uint8List?> processWidgetImage(
    Map<String, dynamic> params,
  ) async {
    final String? imagePath = params['imagePath'];
    final Uint8List? imageBytes = params['imageBytes'];
    final int maxSize = params['maxSize'] ?? kDefaultMaxSize;
    final int quality = params['quality'] ?? kDefaultQuality;

    if (imagePath == null && imageBytes == null) {
      _logger.warning("No image path or bytes provided");
      return null;
    }

    _logger.info(
        "Starting image processing: path=${imagePath != null}, bytes=${imageBytes?.length}, maxSize=$maxSize, quality=$quality");

    try {
      final result = await _processImageWithExif(
        imagePath,
        imageBytes,
        maxSize,
        quality,
      );

      if (result != null) {
        _logger.info(
            "Image processing successful, output size: ${result.length} bytes");
      } else {
        _logger.warning("Image processing returned null");
      }

      return result;
    } catch (e, stackTrace) {
      _logger.severe("Failed to process widget image", e, stackTrace);
      return null;
    }
  }

  static Future<Uint8List?> _processImageWithExif(
    String? imagePath,
    Uint8List? imageBytes,
    int maxSize,
    int quality,
  ) async {
    // Use image package directly for proper max size control
    // flutter_image_compress only has minWidth/minHeight which doesn't limit size properly
    if (imageBytes != null || imagePath != null) {
      try {
        _logger.info(
            "Decoding image: ${imagePath != null ? 'from file $imagePath' : 'from bytes (${imageBytes!.length} bytes)'}");

        final img.Image? image;
        if (imagePath != null) {
          // Read file if we have a path
          image = await img.decodeImageFile(imagePath);
          if (image == null) {
            _logger.warning("Failed to decode image from path: $imagePath");
            // Try reading as bytes if file decoding fails (common with HEIC)
            try {
              final file = File(imagePath);
              if (await file.exists()) {
                final bytes = await file.readAsBytes();
                _logger.info(
                    "Fallback: trying to decode ${bytes.length} bytes from file");
                final fallbackImage = img.decodeImage(bytes);
                if (fallbackImage != null) {
                  _logger.info("Successfully decoded image via bytes fallback");
                  return _processDecodedImage(fallbackImage, maxSize, quality);
                }
              }
            } catch (fallbackError) {
              _logger.warning("Fallback decoding also failed: $fallbackError");
            }
            return null;
          }
        } else {
          // Use bytes directly
          image = img.decodeImage(imageBytes!);
          if (image == null) {
            _logger.warning(
                "Failed to decode image from bytes (${imageBytes.length} bytes)");
            return null;
          }
        }

        return _processDecodedImage(image, maxSize, quality);
      } catch (e, stackTrace) {
        _logger.severe("Image package processing failed", e, stackTrace);
      }
    }

    return null;
  }

  static Uint8List _processDecodedImage(
      img.Image image, int maxSize, int quality) {
    _logger.info("Processing decoded image: ${image.width}x${image.height}");

    // bakeOrientation() reads and applies EXIF rotation
    final orientedImage = img.bakeOrientation(image);
    _logger.info(
        "Applied EXIF orientation: ${orientedImage.width}x${orientedImage.height}");

    // Resize if needed
    final resized = _resizeImage(orientedImage, maxSize);
    _logger.info("Resized image: ${resized.width}x${resized.height}");

    // Encode to JPEG
    final data = img.encodeJpg(resized, quality: quality);
    _logger.info("Encoded to JPEG: ${data.length} bytes");

    return Uint8List.fromList(data);
  }

  static img.Image _resizeImage(img.Image image, int maxSize) {
    if (image.width <= maxSize && image.height <= maxSize) {
      return image;
    }

    // Calculate new dimensions maintaining aspect ratio
    final double aspectRatio = image.width / image.height;
    int newWidth, newHeight;

    if (image.width > image.height) {
      newWidth = maxSize;
      newHeight = (maxSize / aspectRatio).round();
    } else {
      newHeight = maxSize;
      newWidth = (maxSize * aspectRatio).round();
    }

    return img.copyResize(
      image,
      width: newWidth,
      height: newHeight,
      interpolation: img.Interpolation.cubic,
    );
  }
}
