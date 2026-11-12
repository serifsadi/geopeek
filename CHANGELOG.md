# Changelog

## 0.4.0

- Clear Recents keeps the same space under the divider and has more space above the window's bottom edge, so the label clears the rounded corner.
- Remove from Recents removes that file only. The other recent files stay in the same order, with the same open times, in File > Open Recent and on the welcome screen. Clear Recents still clears the whole list.
- The welcome hint about pressing Space on a file in Finder wraps, so the whole sentence is visible.
- GeoPeek requires macOS 15.0 or later.
- Windows are not restored. Opening GeoPeek shows the welcome window. Opening a file from Finder shows that file. Windows left open by Quit or a crash stay closed, including state saved by an older build.
- A KML or KMZ file that only contains network links or image overlays shows Nothing to Preview in the app and in Quick Look, and opening it is added to Recents. An empty or broken file still shows Not Valid and is left out of Recents.
- A KMZ file whose only KML document is inside a folder is opened. A KML file at the root of the archive is still preferred, and `doc.kml` is preferred over other root KML files.
- KML, KMZ, and GPX open in the app and in Quick Look. Each file is converted to GeoJSON and drawn with the existing map, table, and stats. Finder thumbnails use the same GeoPeek icon. File > Open, drag and drop, Finder, and Recents accept the new types. GeoPeek is an alternate handler, so it does not become the default app.
- MapLibre GL JS is 6.18.0. The attribution control starts as the info button. Clicking it shows the MapLibre, OpenFreeMap, OpenMapTiles, and OpenStreetMap credits.
- Opening a file from Finder opens that file in its own window. Other windows keep their files.
- Recently opened files are listed in File > Open Recent and on the left of the welcome screen. Each row shows the name, the path with ~ for the home directory, and when it was opened. Hovering a row shows Remove from Recents and Show in Finder, and the path line names the one under the pointer. Clear Recents sits under the list. A file the app can no longer read returns to the welcome screen.

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

## 0.2.0

- Paste GeoJSON text directly with ⌘V or the welcome screen button. GeoPeek validates the content and displays it on the map.
- The published 0.2.0 disk image actually contained the 0.1.1 app and was removed. 0.3.0 is the first build that ships this feature.

## 0.1.1

- Turkish, CJK, and other non-ASCII characters display correctly in the table view.
- Auto-zoom on row click is replaced with a dedicated "Show on Map" button, so text can be selected and copied.
- Features zoom to center correctly when navigating from the table view.
- The disk image uses a drag-to-Applications layout and a custom background.

## 0.1.0

- Initial release of GeoPeek, a macOS GeoJSON viewer and Quick Look extension.
- The map renders interactively with MapLibre GL, in dark or light mode.
- Map view and table view can be switched, with feature selection.
- Quick Look generates a preview and a thumbnail for `.geojson` files.
- The stats panel shows feature count, geometry types, and bounding box.
- Files open by drag and drop or with ⌘O.
- Invalid GeoJSON files show an error.
