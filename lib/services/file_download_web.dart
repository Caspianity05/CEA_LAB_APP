// LabTrack - file download, web build. See file_download.dart.

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Hands [text] to the browser as a download named [fileName].
bool downloadTextFile(String fileName, String text,
        {String mimeType = 'text/plain'}) =>
    _download(
        fileName,
        web.Blob([text.toJS].toJS,
            web.BlobPropertyBag(type: '$mimeType;charset=utf-8')));

/// Hands [bytes] to the browser as a download named [fileName] (the .xlsx
/// report, the QR-label PDF; 2026-10-06).
bool downloadBytes(String fileName, Uint8List bytes,
        {String mimeType = 'application/octet-stream'}) =>
    _download(fileName,
        web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType)));

bool _download(String fileName, web.Blob blob) {
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  // Firefox only follows a link that is in the page.
  web.document.body?.append(link);
  link.click();
  link.remove();
  // Revoking at once can cancel the download in some browsers.
  Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
  return true;
}
