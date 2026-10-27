// LabTrack - file download, phone build. See file_download.dart.

import 'dart:typed_data';

/// Saving a file is a web portal feature; the phone app reports that it
/// cannot, so the caller can say so.
bool downloadTextFile(String fileName, String text,
        {String mimeType = 'text/plain'}) =>
    false;

/// The same for a binary file (the .xlsx report, the QR-label PDF).
bool downloadBytes(String fileName, Uint8List bytes,
        {String mimeType = 'application/octet-stream'}) =>
    false;
