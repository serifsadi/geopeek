//
//  GeoRenderer.swift
//  Shared — compiled into both GeoPeek and GeoPeekExtension
//
//  Single source of truth for GeoJSON parsing and map HTML generation.
//  Changes here apply to the QL preview extension and the standalone app
//  simultaneously.
//

import Foundation

// MARK: - Data model

struct GeoBounds {
    let minLng: Double
    let maxLng: Double
    let minLat: Double
    let maxLat: Double
}

struct GeoJSONMeta {
    var featureCount: Int = 0
    var vertexCount:  Int = 0
    var geometryTypes: [String] = []
    var bounds: GeoBounds?
}

// MARK: - Parsing

private let _validGeoJSONTypes: Set<String> = [
    "FeatureCollection", "Feature",
    "Point", "MultiPoint",
    "LineString", "MultiLineString",
    "Polygon", "MultiPolygon",
    "GeometryCollection"
]

/// Parses `data` as GeoJSON.  Returns `nil` when the data is not valid GeoJSON.
/// Thread-safe — uses only local state.
func parseGeoJSON(_ data: Data) -> GeoJSONMeta? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = root["type"] as? String,
          _validGeoJSONTypes.contains(type) else { return nil }

    var meta      = GeoJSONMeta()
    var minLng    = Double.infinity,  maxLng = -Double.infinity
    var minLat    = Double.infinity,  maxLat = -Double.infinity
    var geomTypes = Set<String>()

    func walkCoords(_ coords: Any) {
        guard let arr = coords as? [Any] else { return }
        if !arr.isEmpty, !(arr[0] is [Any]), arr.count >= 2,
           let lng = (arr[0] as? NSNumber)?.doubleValue,
           let lat = (arr[1] as? NSNumber)?.doubleValue {
            meta.vertexCount += 1
            if lng < minLng { minLng = lng }; if lng > maxLng { maxLng = lng }
            if lat < minLat { minLat = lat }; if lat > maxLat { maxLat = lat }
        } else {
            arr.forEach { walkCoords($0) }
        }
    }

    func walkGeometry(_ geom: [String: Any]) {
        guard let gType = geom["type"] as? String else { return }
        if gType == "GeometryCollection" {
            (geom["geometries"] as? [[String: Any]])?.forEach { walkGeometry($0) }
        } else {
            geomTypes.insert(gType)
            if let coords = geom["coordinates"] { walkCoords(coords) }
        }
    }

    switch type {
    case "FeatureCollection":
        let features = (root["features"] as? [[String: Any]]) ?? []
        meta.featureCount = features.count
        features.forEach { if let g = $0["geometry"] as? [String: Any] { walkGeometry(g) } }
    case "Feature":
        meta.featureCount = 1
        if let g = root["geometry"] as? [String: Any] { walkGeometry(g) }
    default:
        meta.featureCount = 1
        walkGeometry(root)
    }

    meta.geometryTypes = Array(geomTypes)
    if minLng.isFinite { meta.bounds = GeoBounds(minLng: minLng, maxLng: maxLng,
                                                 minLat: minLat, maxLat: maxLat) }
    return meta
}

// MARK: - HTML generation

/// Error page shown when a file can't be parsed as GeoJSON.
func makeErrorHTML() -> String {
    return """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        :root {
          --bg:     #f2f2f7;
          --label:  rgba(0,0,0,0.847);
          --label2: rgba(60,60,67,0.60);
          --icon-c: rgba(142,142,147,0.80);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg:     #1c1c1e;
            --label:  rgba(255,255,255,0.847);
            --label2: rgba(235,235,245,0.60);
            --icon-c: rgba(174,174,178,0.70);
          }
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body {
          width: 100%; height: 100%;
          display: flex; align-items: center; justify-content: center;
          background: var(--bg);
          font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        .card { text-align: center; max-width: 220px; }
        .icon { color: var(--icon-c); margin-bottom: 12px; line-height: 0; }
        h1 {
          font-size: 13px; font-weight: 600;
          color: var(--label); letter-spacing: -0.008em; margin-bottom: 5px;
        }
        .sub { font-size: 11px; line-height: 1.55; color: var(--label2); }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="icon">
          <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor"
               stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
            <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
            <line x1="12" y1="9" x2="12" y2="13"/>
            <circle cx="12" cy="17" r="0.5" fill="currentColor" stroke="none"/>
          </svg>
        </div>
        <h1>Not Valid GeoJSON</h1>
        <p class="sub">This file doesn't contain recognisable GeoJSON data and cannot be previewed.</p>
      </div>
    </body>
    </html>
    """
}

/// Full map preview page.  The caller injects `window.__GEO__` (base64-encoded
/// GeoJSON) via `WKUserScript` at `.atDocumentStart`, then loads this HTML:
///
/// - **QL extension**: `loadHTMLString(html, baseURL: extensionBundle.resourceURL)`
///   — the extension sandbox allows direct `file://` access to its own bundle.
/// - **Standalone app**: `loadHTMLString(html, baseURL: URL(string:"geopeek://r/"))`
///   — a registered `WKURLSchemeHandler` ("geopeek") serves `maplibre-gl.js/.css`
///   from the app bundle, bypassing WKWebView's `file://` sandbox restrictions.
func makeMapHTML(meta: GeoJSONMeta) -> String {
    let boundsJS: String = {
        guard let b = meta.bounds else { return "null" }
        return "[[\(b.minLng),\(b.minLat)],[\(b.maxLng),\(b.maxLat)]]"
    }()
    let typesJS = "[" + meta.geometryTypes.map { "\"\($0)\"" }.joined(separator: ",") + "]"

    return """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <link rel="stylesheet" href="maplibre-gl.css"/>
      <style>
        /* ── Apple Design System tokens ──────────────────────────────── */
        :root {
          --bg:           #1c1c1e;
          --label:        rgba(255,255,255,0.847);
          --label2:       rgba(235,235,245,0.60);
          --label3:       rgba(235,235,245,0.30);
          --sep:          rgba(84,84,88,0.65);
          --panel-bg:     rgba(44,44,46,0.82);
          --panel-border: rgba(255,255,255,0.095);
          --panel-shadow: 0 2px 12px rgba(0,0,0,0.45), 0 0 0 0.5px rgba(255,255,255,0.06);
          --popup-bg:     #2c2c2e;
          --popup-tip:    #2c2c2e;
          --popup-shadow: 0 6px 24px rgba(0,0,0,0.55);
          --close-btn:    rgba(255,255,255,0.35);
          --close-hover:  rgba(255,255,255,0.75);
          --icon-filter:  invert(1) opacity(0.7);
          --accent:       #f97316;
        }
        @media (prefers-color-scheme: light) {
          :root {
            --bg:           #f2f2f7;
            --label:        rgba(0,0,0,0.847);
            --label2:       rgba(60,60,67,0.60);
            --label3:       rgba(60,60,67,0.30);
            --sep:          rgba(60,60,67,0.29);
            --panel-bg:     rgba(255,255,255,0.80);
            --panel-border: rgba(0,0,0,0.07);
            --panel-shadow: 0 2px 8px rgba(0,0,0,0.10), 0 0 0 0.5px rgba(0,0,0,0.06);
            --popup-bg:     #ffffff;
            --popup-tip:    #ffffff;
            --popup-shadow: 0 4px 20px rgba(0,0,0,0.14);
            --close-btn:    rgba(0,0,0,0.30);
            --close-hover:  rgba(0,0,0,0.70);
            --icon-filter:  opacity(0.55);
            --accent:       #c2410c;
          }
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body, #map { width: 100%; height: 100%; }
        body { background: var(--bg); -webkit-font-smoothing: antialiased; }

        .panel {
          position: absolute; z-index: 100;
          border-radius: 10px;
          background: var(--panel-bg);
          border: 0.5px solid var(--panel-border);
          box-shadow: var(--panel-shadow);
          backdrop-filter: blur(20px) saturate(180%);
          -webkit-backdrop-filter: blur(20px) saturate(180%);
          color: var(--label);
          pointer-events: none;
        }

        #stats {
          top: 10px; left: 10px;
          padding: 6px 10px 7px;
          font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
          font-size: 12px; line-height: 1;
        }
        .stats-count { font-weight: 600; font-size: 12px; color: var(--label); letter-spacing: -0.01em; }
        .stats-types { margin-top: 3px; font-size: 11px; color: var(--label2); }
        .stats-vertices { margin-top: 2px; font-size: 10.5px; color: var(--label3); }

        #coords {
          bottom: 10px; left: 10px;
          padding: 6px 10px 7px;
          font: 12px/1 ui-monospace, 'SF Mono', 'Menlo', monospace;
          color: var(--label2); letter-spacing: 0.01em;
          border-radius: 8px;
          white-space: nowrap;
          visibility: hidden;
        }

        .maplibregl-popup-content {
          background: var(--popup-bg) !important;
          border-radius: 10px !important; padding: 0 !important;
          overflow: hidden; min-width: 168px;
          box-shadow: var(--popup-shadow) !important;
          border: 0.5px solid var(--panel-border) !important;
        }
        .maplibregl-popup-tip { border-top-color: var(--popup-tip) !important; }
        .maplibregl-popup-close-button {
          color: var(--close-btn) !important; font-size: 18px !important;
          line-height: 1 !important; padding: 3px 7px !important;
          font-family: -apple-system, sans-serif !important;
          font-weight: 300 !important; background: transparent !important;
        }
        .maplibregl-popup-close-button:hover {
          color: var(--close-hover) !important; background: transparent !important;
        }

        .prop-table {
          width: 100%; border-collapse: collapse;
          display: block; max-height: 228px; overflow-y: auto;
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          font-size: 11.5px;
        }
        .prop-table tr { border-bottom: 0.5px solid var(--sep); }
        .prop-table tr:last-child { border-bottom: none; }
        .prop-key {
          font-weight: 600; color: var(--label2);
          padding: 5px 6px 5px 12px; vertical-align: top; white-space: nowrap;
        }
        .prop-val {
          font-family: ui-monospace, 'SF Mono', 'Menlo', monospace;
          font-size: 10.5px; color: var(--label);
          padding: 5px 12px 5px 0; vertical-align: top; word-break: break-all;
        }
        .no-props { padding: 10px 12px; font: 11px -apple-system, sans-serif; color: var(--label3); }

        .maplibregl-ctrl-group {
          border-radius: 8px !important;
          background: var(--panel-bg) !important;
          border: 0.5px solid var(--panel-border) !important;
          box-shadow: var(--panel-shadow) !important;
          backdrop-filter: blur(20px) saturate(180%) !important;
          -webkit-backdrop-filter: blur(20px) saturate(180%) !important;
          overflow: hidden;
        }
        .maplibregl-ctrl-group button {
          width: 30px !important; height: 30px !important;
          background-color: transparent !important; color: var(--label) !important;
        }
        .maplibregl-ctrl-group button:hover { background-color: var(--sep) !important; }
        .maplibregl-ctrl-group button + button { border-top: 0.5px solid var(--sep) !important; }
        .maplibregl-ctrl-zoom-in .maplibregl-ctrl-icon,
        .maplibregl-ctrl-zoom-out .maplibregl-ctrl-icon,
        .maplibregl-ctrl-compass .maplibregl-ctrl-icon { filter: var(--icon-filter); }
        .maplibregl-ctrl-bottom-left {
          top: 68px !important; bottom: auto !important;
          left: 10px !important; transform: none !important;
        }
        .maplibregl-ctrl-bottom-left > .maplibregl-ctrl { margin: 0 !important; }
        .maplibregl-ctrl-scale {
          background: var(--panel-bg) !important;
          border: 0.5px solid var(--label2) !important; border-top: none !important;
          color: var(--label2) !important; font: 10px -apple-system, sans-serif !important;
          backdrop-filter: blur(20px) saturate(180%) !important;
          -webkit-backdrop-filter: blur(20px) saturate(180%) !important;
          border-radius: 0 0 4px 4px !important; padding: 1px 4px !important;
        }
        .maplibregl-ctrl-attrib {
          background: var(--panel-bg) !important;
          border: 0.5px solid var(--panel-border) !important;
          box-shadow: var(--panel-shadow) !important;
          backdrop-filter: blur(20px) saturate(180%) !important;
          -webkit-backdrop-filter: blur(20px) saturate(180%) !important;
          border-radius: 8px !important;
        }
        .maplibregl-ctrl-attrib-inner,
        .maplibregl-ctrl-attrib-inner a {
          color: var(--label2) !important;
        }
        .maplibregl-ctrl-attrib-button {
          background-color: transparent !important;
          filter: var(--icon-filter) !important;
        }

        /* ── Table view ──────────────────────────────────────── */
        #table-view {
          position: absolute; top: 48px; left: 0; right: 0; bottom: 0;
          z-index: 200; display: none;
          background: var(--bg); overflow: auto;
        }
        .attr-table {
          width: 100%; border-collapse: collapse;
          font: 12px -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
        }
        .attr-table thead th {
          position: sticky; top: 0; z-index: 1;
          background: var(--panel-bg);
          backdrop-filter: blur(20px) saturate(180%);
          -webkit-backdrop-filter: blur(20px) saturate(180%);
          padding: 8px 12px;
          font-weight: 600; font-size: 11px;
          color: var(--label2);
          text-align: left; white-space: nowrap;
          border-bottom: 0.5px solid var(--sep);
        }
        .attr-table tbody tr {
          cursor: pointer; border-bottom: 0.5px solid var(--sep);
        }
        .attr-table tbody tr:hover { background: var(--panel-bg); }
        .attr-table tbody tr.selected {
          background: var(--panel-bg);
          box-shadow: inset 3px 0 0 var(--accent);
        }
        .attr-table td {
          padding: 6px 12px; color: var(--label);
          font-size: 12px; white-space: nowrap;
          max-width: 300px; overflow: hidden;
          text-overflow: ellipsis; vertical-align: top;
        }
        .attr-table td:first-child {
          color: var(--label3); font-size: 11px;
          font-variant-numeric: tabular-nums;
        }
        .attr-type {
          display: inline-block; font-size: 10px; font-weight: 500;
          color: var(--accent);
          background: var(--panel-bg);
          border: 0.5px solid var(--panel-border);
          border-radius: 4px; padding: 2px 6px;
        }
        .attr-val-mono {
          font-family: ui-monospace, 'SF Mono', 'Menlo', monospace;
          font-size: 11px; color: var(--label2);
        }
        #table-loading {
          position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
          text-align: center; color: var(--label3);
          font: 13px -apple-system, BlinkMacSystemFont, sans-serif;
        }
        #table-loading .spinner {
          width: 20px; height: 20px; margin: 0 auto 10px;
          border: 2px solid var(--sep); border-top-color: var(--accent);
          border-radius: 50%;
          animation: spin 0.8s linear infinite;
        }
        @keyframes spin { to { transform: rotate(360deg); } }

        /* ── View toggle ─────────────────────────────────────── */
        #view-toggle {
          position: absolute; z-index: 300;
          top: 10px; left: 50%; transform: translateX(-50%);
          display: flex; border-radius: 8px; overflow: hidden;
          background: var(--panel-bg);
          border: 0.5px solid var(--panel-border);
          box-shadow: var(--panel-shadow);
          backdrop-filter: blur(20px) saturate(180%);
          -webkit-backdrop-filter: blur(20px) saturate(180%);
        }
        #view-toggle button {
          width: 30px; height: 30px;
          border: none; background: transparent; cursor: pointer;
          display: flex; align-items: center; justify-content: center;
          color: var(--label);
        }
        #view-toggle button:hover { background: var(--sep); }
        #view-toggle button.active { background: var(--accent); color: #fff; }
        #view-toggle button + button { border-left: 0.5px solid var(--sep); }
      </style>
    </head>
    <body>
      <div id="stats" class="panel"></div>
      <div id="coords" class="panel"></div>
      <div id="map"></div>
      <div id="table-view"></div>
      <div id="view-toggle">
        <button id="btn-map" class="active" title="Map view" aria-label="Map view">
          <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M1 4l4.5-2.5 5 2.5L15 1.5v11L10.5 15l-5-2.5L1 15z"/><path d="M5.5 1.5v11M10.5 4v11"/></svg>
        </button>
        <button id="btn-table" title="Table view" aria-label="Table view">
          <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><rect x="1.5" y="2.5" width="13" height="11" rx="1.5"/><line x1="1.5" y1="6.5" x2="14.5" y2="6.5"/><line x1="1.5" y1="10.5" x2="14.5" y2="10.5"/><line x1="6" y1="6.5" x2="6" y2="13.5"/></svg>
        </button>
      </div>
      <script src="maplibre-gl.js"></script>
      <script>
        var META = {
          featureCount:  \(meta.featureCount),
          vertexCount:   \(meta.vertexCount),
          geometryTypes: \(typesJS),
          bounds:        \(boundsJS)
        };

        var typeLabels = {
          'Point':'Point',             'MultiPoint':'Multi\\u00b7Point',
          'LineString':'Line',          'MultiLineString':'Multi\\u00b7Line',
          'Polygon':'Polygon',          'MultiPolygon':'Multi\\u00b7Polygon',
          'GeometryCollection':'Collection'
        };
        var typeNames = META.geometryTypes.map(function(t) {
          return typeLabels[t] || t;
        }).join('  \\u00b7  ');

        document.getElementById('stats').innerHTML =
          '<div class="stats-count">'  + META.featureCount.toLocaleString() +
          '&#x2009;feature' + (META.featureCount !== 1 ? 's' : '') + '</div>' +
          (typeNames ? '<div class="stats-types">' + typeNames + '</div>' : '') +
          (META.vertexCount > 0 ? '<div class="stats-vertices">' +
            META.vertexCount.toLocaleString() + '&#x2009;vertices</div>' : '');

        var isDark     = window.matchMedia('(prefers-color-scheme: dark)').matches;
        var cartoTheme = isDark ? 'dark_all' : 'light_all';
        var bgColor    = isDark ? '#1c1c1e'  : '#f2f2f7';
        var tileUrls   = ['a','b','c','d'].map(function(s) {
          return 'https://' + s + '.basemaps.cartocdn.com/' + cartoTheme + '/{z}/{x}/{y}@2x.png';
        });
        var dataColor   = isDark ? '#f97316' : '#c2410c';
        var fillOpacity = isDark ? 0.25      : 0.15;
        var emptyFC     = { type: 'FeatureCollection', features: [] };

        var mapOptions = {
          container: 'map',
          style: {
            version: 8,
            sources: {
              carto: {
                type: 'raster', tiles: tileUrls, tileSize: 256,
                attribution: '\\u00a9 <a href="https://carto.com/attributions">CARTO</a> \\u00a9 <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>'
              }
            },
            layers: [
              { id: 'bg',    type: 'background', paint: { 'background-color': bgColor } },
              { id: 'carto', type: 'raster',     source: 'carto', paint: { 'raster-opacity': 0 } }
            ]
          }
        };

        if (META.bounds) {
          mapOptions.bounds           = META.bounds;
          mapOptions.fitBoundsOptions = { padding: 40, maxZoom: 16 };
        } else {
          mapOptions.center = [0, 20];
          mapOptions.zoom   = 1;
        }

        var map = new maplibregl.Map(mapOptions);

        map.addControl(new maplibregl.NavigationControl(), 'top-right');
        map.addControl({
          onAdd: function() {
            var div = document.createElement('div');
            div.className = 'maplibregl-ctrl maplibregl-ctrl-group';
            var btn = document.createElement('button');
            btn.title = 'Fit to data';
            btn.setAttribute('aria-label', 'Fit to data');
            btn.style.cssText = 'display:flex;align-items:center;justify-content:center;';
            btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" width="16" height="16" fill="currentColor"><path d="M2 2h4v1.5H3.5V5H2zm10 0h4v3h-1.5V3.5H12zM2 16v-4h1.5v2.5H6V16zm10 0v-1.5h2.5V12H16v4z"/></svg>';
            btn.onclick = fitToData;
            div.appendChild(btn);
            return div;
          },
          onRemove: function() {}
        }, 'top-right');
        map.addControl(new maplibregl.ScaleControl({ unit: 'metric' }), 'bottom-left');

        // Position scale bar below stats panel, match its width
        requestAnimationFrame(function() {
          var st = document.getElementById('stats');
          var sc = document.querySelector('.maplibregl-ctrl-bottom-left');
          if (st && sc) {
            var r = st.getBoundingClientRect();
            sc.style.top = (r.bottom + 4) + 'px';
            var bar = sc.querySelector('.maplibregl-ctrl-scale');
            if (bar) bar.style.maxWidth = r.width + 'px';
          }
        });

        function fitToData() {
          if (META.bounds) map.fitBounds(META.bounds, { padding: 40, maxZoom: 16 });
        }

        function esc(s) {
          return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        }

        var activePopup = null;
        var closingProgrammatically = false;

        function closeActivePopup() {
          if (!activePopup) return;
          closingProgrammatically = true;
          activePopup.remove();
          closingProgrammatically = false;
          activePopup = null;
        }

        // ── View toggle state ────────────────────────────────
        var currentView = 'map';
        var tableBuilt  = false;
        var features    = [];
        var selectedFeatureIndex = -1;

        function selectRow(idx) {
          if (tableBuilt) {
            var prev = document.querySelector('.attr-table tbody tr.selected');
            if (prev) prev.classList.remove('selected');
            if (idx >= 0) {
              var r = document.getElementById('row-' + idx);
              if (r) r.classList.add('selected');
            }
          }
          selectedFeatureIndex = idx;
        }

        function featureBounds(f) {
          if (!f.geometry || !f.geometry.coordinates) return null;
          var n = 0, b = new maplibregl.LngLatBounds();
          (function walk(c) {
            if (typeof c[0] === 'number') { b.extend([c[0], c[1]]); n++; }
            else c.forEach(walk);
          })(f.geometry.coordinates);
          return n ? b : null;
        }

        function buildTable() {
          var el = document.getElementById('table-view');
          if (!features.length) {
            el.innerHTML = '<p style="padding:40px;text-align:center;color:var(--label3);' +
              'font:13px -apple-system,sans-serif">No features</p>';
            tableBuilt = true; return;
          }
          // Show spinner, defer heavy work so the UI updates first
          el.innerHTML = '<div id="table-loading"><div class="spinner"></div>Loading ' +
            features.length.toLocaleString() + ' features\\u2026</div>';
          tableBuilt = true;
          setTimeout(function() {
            var allKeys = [], ks = {};
            features.forEach(function(f) {
              Object.keys(f.properties || {}).forEach(function(k) {
                if (k !== '__idx' && !ks[k]) { ks[k] = true; allKeys.push(k); }
              });
            });
            var h = '<table class="attr-table"><thead><tr><th>#</th><th>Type</th>';
            allKeys.forEach(function(k) { h += '<th>' + esc(k) + '</th>'; });
            h += '</tr></thead><tbody>';
            features.forEach(function(f, i) {
              var gt = (f.geometry && f.geometry.type) || '\\u2014';
              var p  = f.properties || {};
              h += '<tr id="row-' + i + '" data-idx="' + i + '"';
              if (i === selectedFeatureIndex) h += ' class="selected"';
              h += '><td>' + (i + 1) + '</td>';
              h += '<td><span class="attr-type">' + esc(typeLabels[gt] || gt) + '</span></td>';
              allKeys.forEach(function(k) {
                var v = p[k];
                if (v === undefined || v === null) {
                  h += '<td style="color:var(--label3)">\\u2014</td>';
                } else if (typeof v === 'object') {
                  h += '<td class="attr-val-mono">' + esc(JSON.stringify(v)) + '</td>';
                } else {
                  h += '<td>' + esc(String(v)) + '</td>';
                }
              });
              h += '</tr>';
            });
            h += '</tbody></table>';
            el.innerHTML = h;
            el.querySelectorAll('tbody tr').forEach(function(tr) {
              tr.addEventListener('click', function() {
                var idx = parseInt(this.dataset.idx);
                selectRow(idx);
                var f = features[idx];
                if (f) {
                  map.getSource('highlight').setData(f);
                  var fb = featureBounds(f);
                  if (fb) {
                    var sw = fb.getSouthWest(), ne = fb.getNorthEast();
                    if (sw.lng === ne.lng && sw.lat === ne.lat)
                      map.flyTo({ center: [sw.lng, sw.lat], zoom: 14 });
                    else
                      map.fitBounds(fb, { padding: 80, maxZoom: 16 });
                  }
                }
                toggleView('map');
              });
            });
            if (selectedFeatureIndex >= 0) {
              var sr = document.getElementById('row-' + selectedFeatureIndex);
              if (sr) { sr.classList.add('selected'); sr.scrollIntoView({ block: 'center' }); }
            }
          }, 16);
        }

        function toggleView(view) {
          if (view === currentView) return;
          currentView = view;
          var mapEl    = document.getElementById('map');
          var tableEl  = document.getElementById('table-view');
          var statsEl  = document.getElementById('stats');
          var coordsEl = document.getElementById('coords');
          if (view === 'table') {
            if (!tableBuilt) buildTable();
            closeActivePopup();
            mapEl.style.display    = 'none';
            tableEl.style.display  = 'block';
            statsEl.style.display  = 'none';
            coordsEl.style.display = 'none';
            document.getElementById('btn-map').classList.remove('active');
            document.getElementById('btn-table').classList.add('active');
            if (selectedFeatureIndex >= 0) {
              var sr = document.getElementById('row-' + selectedFeatureIndex);
              if (sr) sr.scrollIntoView({ block: 'center' });
            }
          } else {
            tableEl.style.display  = 'none';
            mapEl.style.display    = 'block';
            statsEl.style.display  = '';
            coordsEl.style.display = '';
            coordsEl.style.visibility = 'hidden';
            document.getElementById('btn-map').classList.add('active');
            document.getElementById('btn-table').classList.remove('active');
            setTimeout(function() { map.resize(); }, 0);
          }
        }

        document.getElementById('btn-map').onclick  = function() { toggleView('map'); };
        document.getElementById('btn-table').onclick = function() { toggleView('table'); };

        map.on('load', function() {

          // Tile fade-in on initial load
          map.on('idle', function checkTiles() {
            if (!map.areTilesLoaded()) return;
            map.off('idle', checkTiles);
            var t0 = null, dur = 600;
            function tick(ts) {
              if (!t0) t0 = ts;
              var p = Math.min(1, (ts - t0) / dur);
              map.setPaintProperty('carto', 'raster-opacity', p);
              if (p < 1) requestAnimationFrame(tick);
            }
            requestAnimationFrame(tick);
          });

          // Dynamic appearance change — CSS custom properties update automatically,
          // but MapLibre JS-set styles (tile URLs, layer colours) need explicit updates.
          window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(e) {
            var dark       = e.matches;
            var newBg      = dark ? '#1c1c1e'  : '#f2f2f7';
            var newColor   = dark ? '#f97316'  : '#c2410c';
            var newFill    = dark ? 0.25       : 0.15;
            var newHlFill  = dark ? 0.50       : 0.35;
            var newStroke  = dark ? '#000000'  : '#ffffff';
            var newTheme   = dark ? 'dark_all' : 'light_all';
            var newTiles   = ['a','b','c','d'].map(function(s) {
              return 'https://' + s + '.basemaps.cartocdn.com/' + newTheme + '/{z}/{x}/{y}@2x.png';
            });

            map.setPaintProperty('bg', 'background-color', newBg);
            map.getSource('carto').setTiles(newTiles);
            map.setPaintProperty('fill',   'fill-color',   newColor);
            map.setPaintProperty('fill',   'fill-opacity', newFill);
            map.setPaintProperty('line',   'line-color',   newColor);
            map.setPaintProperty('circle', 'circle-color', newColor);
            map.setPaintProperty('circle', 'circle-stroke-color', newStroke);
            map.setPaintProperty('hl-fill', 'fill-color',   newColor);
            map.setPaintProperty('hl-fill', 'fill-opacity', newHlFill);

            map.setPaintProperty('carto', 'raster-opacity', 0);
            map.once('idle', function fadeTiles() {
              if (!map.areTilesLoaded()) { map.once('idle', fadeTiles); return; }
              var t0 = null;
              function tick(ts) {
                if (!t0) t0 = ts;
                var p = Math.min(1, (ts - t0) / 400);
                map.setPaintProperty('carto', 'raster-opacity', p);
                if (p < 1) requestAnimationFrame(tick);
              }
              requestAnimationFrame(tick);
            });
          });

          // Parse GeoJSON injected by Swift as window.__GEO__ (base64)
          var geojson;
          try { geojson = JSON.parse(atob(window.__GEO__ || '')); }
          catch(e) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mapReady) {
              window.webkit.messageHandlers.mapReady.postMessage(null);
            }
            return;
          }

          // Normalise into a flat feature array with __idx for table↔map linking
          if (geojson.type === 'FeatureCollection') {
            features = geojson.features || [];
          } else if (geojson.type === 'Feature') {
            features = [geojson];
          } else {
            features = [{ type: 'Feature', geometry: geojson, properties: {} }];
          }
          features.forEach(function(f, i) {
            if (!f.properties) f.properties = {};
            f.properties.__idx = i;
          });

          map.addSource('data', { type: 'geojson', data: { type: 'FeatureCollection', features: features } });

          map.addLayer({
            id: 'fill', type: 'fill', source: 'data',
            filter: ['==', '$type', 'Polygon'],
            paint: { 'fill-color': dataColor, 'fill-opacity': fillOpacity }
          });
          map.addLayer({
            id: 'line', type: 'line', source: 'data',
            filter: ['in', '$type', 'Polygon', 'LineString'],
            paint: { 'line-color': dataColor, 'line-width': 2, 'line-opacity': 0.9 }
          });
          map.addLayer({
            id: 'circle', type: 'circle', source: 'data',
            filter: ['==', '$type', 'Point'],
            paint: {
              'circle-radius': 6, 'circle-color': dataColor, 'circle-opacity': 0.9,
              'circle-stroke-width': 1.5,
              'circle-stroke-color': isDark ? '#000000' : '#ffffff'
            }
          });

          map.addSource('highlight', { type: 'geojson', data: emptyFC });
          map.addLayer({
            id: 'hl-fill', type: 'fill', source: 'highlight',
            filter: ['==', '$type', 'Polygon'],
            paint: { 'fill-color': dataColor, 'fill-opacity': isDark ? 0.5 : 0.35 }
          });
          map.addLayer({
            id: 'hl-line', type: 'line', source: 'highlight',
            filter: ['in', '$type', 'Polygon', 'LineString'],
            paint: { 'line-color': '#ffffff', 'line-width': 2.5, 'line-opacity': 0.9 }
          });
          map.addLayer({
            id: 'hl-circle', type: 'circle', source: 'highlight',
            filter: ['==', '$type', 'Point'],
            paint: {
              'circle-radius': 8, 'circle-color': dataColor, 'circle-opacity': 1,
              'circle-stroke-width': 2.5, 'circle-stroke-color': '#ffffff'
            }
          });

          ['fill', 'line', 'circle'].forEach(function(id) {
            map.on('mouseenter', id, function() { map.getCanvas().style.cursor = 'pointer'; });
            map.on('mouseleave', id, function() { map.getCanvas().style.cursor = ''; });
          });

          map.on('click', function(e) {
            var hits = map.queryRenderedFeatures(e.point, { layers: ['fill', 'line', 'circle'] });
            if (!hits.length) {
              map.getSource('highlight').setData(emptyFC);
              closeActivePopup();
              selectRow(-1);
              return;
            }
            map.getSource('highlight').setData(hits[0]);
            closeActivePopup();

            var props   = hits[0].properties || {};
            if (props.__idx !== undefined) selectRow(props.__idx);
            var keys    = Object.keys(props).filter(function(k) { return k !== '__idx'; });
            var content = keys.length === 0
              ? '<p class="no-props">No properties</p>'
              : '<table class="prop-table">' + keys.map(function(k) {
                  var v = props[k];
                  return '<tr><td class="prop-key">' + esc(k) +
                         '</td><td class="prop-val">' + esc(v === null ? '\\u2014' : v) +
                         '</td></tr>';
                }).join('') + '</table>';

            activePopup = new maplibregl.Popup({
              closeButton: true, closeOnClick: false,
              maxWidth: '260px', offset: 8
            }).setLngLat(e.lngLat).setHTML(content).addTo(map);

            activePopup.on('close', function() {
              activePopup = null;
              if (!closingProgrammatically) {
                map.getSource('highlight').setData(emptyFC);
                selectRow(-1);
              }
            });
          });

          var coordsEl = document.getElementById('coords');
          var canvas   = map.getCanvas();
          canvas.addEventListener('mousemove', function(e) {
            var rect   = canvas.getBoundingClientRect();
            var lngLat = map.unproject([e.clientX - rect.left, e.clientY - rect.top]);
            coordsEl.textContent = lngLat.lng.toFixed(5) + ',  ' + lngLat.lat.toFixed(5);
            coordsEl.style.visibility = 'visible';
          });
          canvas.addEventListener('mouseleave', function() {
            coordsEl.style.visibility = 'hidden';
          });

          // Signal Swift: map is ready (spinner dismiss in QL extension, no-op in app)
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mapReady) {
            window.webkit.messageHandlers.mapReady.postMessage(null);
          }
        });
      </script>
    </body>
    </html>
    """
}
