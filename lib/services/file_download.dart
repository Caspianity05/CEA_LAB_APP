// -----------------------------------------------------------------------------
// LabTrack - save a text file to the computer (staff web portal)
//
// Added 2026-10-05. In a browser the file goes to the browser's own Downloads
// (Reports → "Download for Excel"). The phone app has no such step: there the
// stub returns false and the caller says the download is web-only.
// -----------------------------------------------------------------------------

export 'file_download_stub.dart'
    if (dart.library.js_interop) 'file_download_web.dart';
