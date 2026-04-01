let gSlides = [];
let gSlideIdx = 0;

// -----------------------------------------------------------------
//  Tabs
// -----------------------------------------------------------------

function f_setActiveTab(tabId) {
   document.querySelectorAll(".tab-button").forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.tab === tabId);
   });

   document.querySelectorAll(".tab-content").forEach((div) => {
      div.classList.toggle("active", div.id === tabId);
   });

   // Leaflet needs the container visible before init
   if (tabId === "tab2" && !gMapReady) {
      setTimeout(f_initMap, 50);
   }
}

// -----------------------------------------------------------------
//  Slides (Tab 1)
// -----------------------------------------------------------------

function f_updateSlide() {
   const img = document.getElementById("slideImage");
   const label = document.getElementById("slideLabel");

   if (!gSlides || gSlides.length === 0) {
      label.textContent = "Page 0 of 0";
      img.removeAttribute("src");
      img.alt = "No pages found";
      return;
   }

   if (gSlideIdx < 0) {
      gSlideIdx = gSlides.length - 1;
   }
   if (gSlideIdx >= gSlides.length) {
      gSlideIdx = 0;
   }

   const filename = gSlides[gSlideIdx];
   //
   img.src = "/slides/" + encodeURIComponent(filename);
   img.alt = filename;
   label.textContent = "Page " + (gSlideIdx + 1) + " of " + gSlides.length + ".";
}

async function f_loadSlides() {
   const resp = await fetch("/api/slides");
   const data = await resp.json();
   //
   gSlides = data.files || [];
   gSlideIdx = 0;
   f_updateSlide();
}

// -----------------------------------------------------------------
//  Map (Tab 2)
// -----------------------------------------------------------------

var gMapReady = false;
var gMap = null;
var gMarkerLayer = null; // layer group for markers + shapes (cleared on re-query)

// Query mode: "circle" | "box" | "polygon"
var gMode = "circle";

// Downtown Fort Collins
var gCenter = [40.5853, -105.0775];
var gRadiusMiles = 1;

// Polygon state
var gPolyVerts = []; // array of [lat, lng], max 6
var gPolyLayer = null; // layer group for vertex markers + outline during polygon building

function haversine(lat1, lon1, lat2, lon2) {
   var R = 3958.8;
   var dLat2 = ((lat2 - lat1) * Math.PI) / 360;
   var dLon2 = ((lon2 - lon1) * Math.PI) / 360;
   var a =
      Math.sin(dLat2) * Math.sin(dLat2) +
      Math.cos((lat1 * Math.PI) / 180) *
         Math.cos((lat2 * Math.PI) / 180) *
         Math.sin(dLon2) *
         Math.sin(dLon2);
   return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Ray-casting point-in-polygon test
function f_pointInPolygon(lat, lng, verts) {
   var inside = false;
   for (var i = 0, j = verts.length - 1; i < verts.length; j = i++) {
      var yi = verts[i][0],
         xi = verts[i][1];
      var yj = verts[j][0],
         xj = verts[j][1];
      if (
         yi > lat !== yj > lat &&
         lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi
      ) {
         inside = !inside;
      }
   }
   return inside;
}

function f_initMap() {
   gMapReady = true;

   gMap = L.map("map").setView(gCenter, 15);

   L.tileLayer(
      "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png",
      {
         maxZoom: 19,
         subdomains: "abcd",
         attribution:
            '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> &copy; <a href="https://carto.com/">CARTO</a>',
      },
   ).addTo(gMap);

   gMarkerLayer = L.layerGroup().addTo(gMap);
   gPolyLayer = L.layerGroup().addTo(gMap);

   // Map click handler — behavior depends on gMode
   gMap.on("click", function (e) {
      if (gMode === "circle") {
         gCenter = [e.latlng.lat, e.latlng.lng];
         f_queryCircle();
      } else if (gMode === "box") {
         gCenter = [e.latlng.lat, e.latlng.lng];
         f_queryBox();
      } else if (gMode === "polygon") {
         f_handlePolygonClick(e.latlng.lat, e.latlng.lng);
      }
   });

   // Radio button handlers
   document
      .querySelectorAll('input[name="queryMode"]')
      .forEach(function (radio) {
         radio.addEventListener("change", function () {
            gMode = this.value;
            f_resetPolygon();
            gMarkerLayer.clearLayers();
            document.getElementById("btnClearPins").style.display =
               gMode === "polygon" ? "inline-block" : "none";
            document.getElementById("count").textContent = "";
         });
      });

   // Clear Pins button
   document
      .getElementById("btnClearPins")
      .addEventListener("click", function () {
         f_resetPolygon();
         gMarkerLayer.clearLayers();
         document.getElementById("count").textContent =
            "Click 6 points to define polygon";
      });

   // Initial query
   f_queryCircle();
}

// -----------------------------------------------------------------
//  Circle query
// -----------------------------------------------------------------

function f_queryCircle() {
   gMarkerLayer.clearLayers();

   var radiusMeters = gRadiusMiles * 1609.34;
   L.circle(gCenter, {
      radius: radiusMeters,
      color: "#3388ff",
      fillColor: "#3388ff",
      fillOpacity: 0.05,
      weight: 2,
   }).addTo(gMarkerLayer);

   var dLat = gRadiusMiles / 69.0;
   var dLon = gRadiusMiles / 53.0;
   var bbox = [
      gCenter[1] - dLon,
      gCenter[0] - dLat,
      gCenter[1] + dLon,
      gCenter[0] + dLat,
   ];

   var filterFn = function (lat, lng) {
      return haversine(gCenter[0], gCenter[1], lat, lng) <= gRadiusMiles;
   };

   f_loadMapData(bbox, filterFn);
}

// -----------------------------------------------------------------
//  Box query
// -----------------------------------------------------------------

function f_queryBox() {
   gMarkerLayer.clearLayers();

   // 1 square mile = 0.5 mile each direction
   var halfMile = 0.5;
   var dLat = halfMile / 69.0;
   var dLon = halfMile / 53.0;

   var south = gCenter[0] - dLat;
   var north = gCenter[0] + dLat;
   var west = gCenter[1] - dLon;
   var east = gCenter[1] + dLon;

   L.rectangle(
      [
         [south, west],
         [north, east],
      ],
      {
         color: "#3388ff",
         fillColor: "#3388ff",
         fillOpacity: 0.05,
         weight: 2,
      },
   ).addTo(gMarkerLayer);

   var bbox = [west, south, east, north];

   var filterFn = function (lat, lng) {
      return lat >= south && lat <= north && lng >= west && lng <= east;
   };

   f_loadMapData(bbox, filterFn);
}

// -----------------------------------------------------------------
//  Polygon query
// -----------------------------------------------------------------

function f_handlePolygonClick(lat, lng) {
   if (gPolyVerts.length >= 6) return; // already complete

   gPolyVerts.push([lat, lng]);

   // Draw a small orange circle at the vertex
   L.circleMarker([lat, lng], {
      radius: 6,
      color: "#f05a28",
      fillColor: "#f05a28",
      fillOpacity: 0.8,
      weight: 2,
   }).addTo(gPolyLayer);

   document.getElementById("count").textContent =
      gPolyVerts.length + " of 6 points placed";

   if (gPolyVerts.length === 6) {
      f_queryPolygon();
   }
}

function f_queryPolygon() {
   gMarkerLayer.clearLayers();

   // Draw the polygon outline in yugabyteDB orange
   L.polygon(gPolyVerts, {
      color: "#f05a28",
      fillColor: "#f05a28",
      fillOpacity: 0.05,
      weight: 2,
   }).addTo(gMarkerLayer);

   // Compute bounding box from vertices
   var lats = gPolyVerts.map(function (v) {
      return v[0];
   });
   var lngs = gPolyVerts.map(function (v) {
      return v[1];
   });
   var bbox = [
      Math.min.apply(null, lngs),
      Math.min.apply(null, lats),
      Math.max.apply(null, lngs),
      Math.max.apply(null, lats),
   ];

   var verts = gPolyVerts;
   var filterFn = function (lat, lng) {
      return f_pointInPolygon(lat, lng, verts);
   };

   f_loadMapData(bbox, filterFn);
}

function f_resetPolygon() {
   gPolyVerts = [];
   gPolyLayer.clearLayers();
}

// -----------------------------------------------------------------
//  Data loading (shared by all modes)
// -----------------------------------------------------------------

async function f_loadMapData(bbox, filterFn) {
   var viewParams =
      "LON_MIN:" +
      bbox[0] +
      ";LAT_MIN:" +
      bbox[1] +
      ";LON_MAX:" +
      bbox[2] +
      ";LAT_MAX:" +
      bbox[3];

   var wfsUrl = "/api/geoserver?viewparams=" + encodeURIComponent(viewParams);

   // Populate RPC Calls tab (tab 3) with the actual GeoServer URL
   var fullGeoUrl =
      "http://localhost:8080/geoserver/yugabyte/wfs?service=WFS&version=1.0.0" +
      "&request=GetFeature&typeName=yugabyte:my_mapdata_fast" +
      "&outputFormat=application/json" +
      "&maxFeatures=5000" +
      "&viewparams=" +
      viewParams;

   var el = document.getElementById("rpc_wfs_url");
   if (el) el.textContent = fullGeoUrl;

   el = document.getElementById("rpc_lon_min");
   if (el) el.textContent = bbox[0].toFixed(6);
   el = document.getElementById("rpc_lat_min");
   if (el) el.textContent = bbox[1].toFixed(6);
   el = document.getElementById("rpc_lon_max");
   if (el) el.textContent = bbox[2].toFixed(6);
   el = document.getElementById("rpc_lat_max");
   if (el) el.textContent = bbox[3].toFixed(6);

   // Fetch via Flask proxy (avoids CORS)
   try {
      var resp = await fetch(wfsUrl);
      var data = await resp.json();
      f_renderMarkers(data, filterFn);
   } catch (err) {
      console.error("GeoServer fetch error:", err);
      document.getElementById("count").textContent = "Error loading data";
   }
}

function f_renderMarkers(data, filterFn) {
   var features = data.features || [];

   var filtered;
   if (filterFn) {
      filtered = features.filter(function (f) {
         var c = f.geometry.coordinates;
         return filterFn(c[1], c[0]);
      });
   } else {
      filtered = features;
   }

   document.getElementById("count").textContent =
      filtered.length + " locations found";

   filtered.forEach(function (f) {
      var c = f.geometry.coordinates;
      var dist = haversine(gCenter[0], gCenter[1], c[1], c[0]).toFixed(1);
      L.marker([c[1], c[0]])
         .bindTooltip(f.properties.md_name)
         .bindPopup(
            "<b>" +
               f.properties.md_name +
               "</b><br>" +
               f.properties.md_address +
               "<br>" +
               f.properties.md_city +
               ", " +
               f.properties.md_province +
               "<br><i>" +
               dist +
               " miles</i>",
         )
         .addTo(gMarkerLayer);
   });
}

// -----------------------------------------------------------------
//  Init
// -----------------------------------------------------------------

function f_init() {
   document.querySelectorAll(".tab-button").forEach((btn) => {
      btn.addEventListener("click", () => f_setActiveTab(btn.dataset.tab));
   });

   document.getElementById("btnSlideUp").addEventListener("click", () => {
      gSlideIdx -= 1;
      f_updateSlide();
   });

   document.getElementById("btnSlideDown").addEventListener("click", () => {
      gSlideIdx += 1;
      f_updateSlide();
   });

   f_loadSlides();
}

// -----------------------------------------------------------------
// -----------------------------------------------------------------

document.addEventListener("DOMContentLoaded", f_init);
