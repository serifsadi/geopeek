# Changelog

## 0.3.0

- The published GeoPeek-0.2.0.dmg contains the 0.1.1 app. A second GeoPeek.app, built from the 0.2.0 source, sits beside `Contents` and outside the outer code signature, so installing that disk image runs 0.1.1. `scripts/release.sh` stages the app in a new temporary directory and stops if the sealed bundle has an app outside `Contents`.
- Paste from Clipboard (⌘V) is in this build. It was added in the 0.2.0 source and was missing from the disk image people installed.
- File-controlled GeoJSON text stays inside the map page in the app and in Quick Look (#1).
- The basemap is OpenFreeMap, dark or positron to match the appearance. Geometry keeps drawing on a plain background when the style host is unreachable (#2).
- When the basemap cannot load, a small "Basemap unavailable" chip appears and the reason is logged (subsystem `dev.serifsadi.GeoPeek`, category `basemap`) (#6).
- Quick Look renders JSON that is not GeoJSON as a read-only colored page, and other text as a size-capped dump (#3).
- Finder thumbnails are a static GeoPeek icon. `.geojson` returns the icon without reading the file. `.json` is sniffed for a GeoJSON root type, and anything else keeps the system thumbnail (#4).
- Release builds enable the hardened runtime and are signed with a Developer ID Application certificate. The release script notarizes the app and the disk image.
- GeoPeek is back in Finder's Open With menu as a viewer for `.geojson`. The handler rank is Alternate, so it does not become the default app.
- Upgrading from 0.1.x or 0.2.0 replaces an ad-hoc signature with a Developer ID signature. macOS shows the prompt that GeoPeekExtension differs from previously opened versions, once.
