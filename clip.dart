import 'feature.dart';
import 'dart:math' as math;
import 'package:geojson_vi/geojson_vi.dart';
import 'classes.dart';


/*
class Slice {
  num start = 0;
  num end = 0;
  num size = 0;
  GeoJSONGeometry geometry;
  Slice({this.start=0, this.end=0, this.size=0, GeoJSONGeometry? geometry }) : geometry = geometry ?? [];

  @override String toString() {
    return "Slice: start=$start end=$end size=$size geometry=$geometry";
  }

  void add(val) => this.geometry.add(val);
  int get length => this.geometry.length;

}


 */

/* clip features between two vertical or horizontal axis-parallel lines:
 *     |        |
 *  ___|___     |     /
 * /   |   \____|____/
 *     |        |
 *
 * k1 and k2 are the line coordinates
 * axis: 0 for x, 1 for y
 * minAll and maxAll: minimum and maximum coordinate value for all features
 */



List clip(features, scale, k1, k2, axis, minAll, maxAll, options) {
  k1 /= scale;
  k2 /= scale;

  bool lineMetrics = options['lineMetrics'] != null ? options['lineMetrics'] : false;

  if (minAll >= k1 && maxAll < k2) return features; // trivial accept
  else if (maxAll < k1 || minAll >= k2) return []; // trivial reject

  var clipped = [];

  //print("FEATURE LEN IS ${features.length}");

  for (var feature in features) {
    var geometry = feature['geometry'];
    var type = feature['type'];
//print("TYPE IN clip is $type, feature is $feature");

    final min = axis == 0 ? feature['minX'] : feature['minY'];
    final max = axis == 0 ? feature['maxX'] : feature['maxY'];

    if (min >= k1 && max < k2) { // trivial accept
      clipped.add(feature);
      continue;
    } else if (max < k1 || min >= k2) { // trivial reject
      continue;
    }

    List newGeometry = [];

    if (type == 'Point' || type == 'MultiPoint') {
      clipPoints(geometry, newGeometry, k1, k2, axis);

    } else if (type == 'LineString') {
     // print("LINESTRINGCLIP");
      clipLine(geometry, newGeometry, k1, k2, axis, false, lineMetrics);

    } else if (type == 'MultiLineString') {
      clipLines(geometry, newGeometry, k1, k2, axis, false);

    } else if (type == 'Polygon') {
      clipLines(geometry, newGeometry, k1, k2, axis, true);

    } else if (type == 'MultiPolygon') {

      for (var polygon in geometry) {
        List newPolygon = [];

        clipLines(polygon, newPolygon, k1, k2, axis, true);

        if (newPolygon.length > 0) {
          newGeometry.add(newPolygon);
        }
      }
    } else {
      print("TYPE NOT HANDLED");
    }

    if (newGeometry.length > 0) {
      if (lineMetrics && type == 'LineString') {
        for (var line in newGeometry) {
          //print("CLIPPING ADD ");
          clipped.add(createFeature(feature['id'], type, line, feature['tags']));
        }
        continue;
      }

      if (type == 'LineString' || type == 'MultiLineString') {
        if (newGeometry.length == 1) {
          type = 'LineString';
          newGeometry = newGeometry[0];
        } else {
          type = 'MultiLineString';
        }
      }
      if (type == 'Point' || type == 'MultiPoint') {
        type = (newGeometry.length == 3) ? 'Point' : 'MultiPoint';
      }

      //print("IN CLIP ABOUT TO CREATE FEATURE $type $newGeometry ${newGeometry.size}");
      clipped.add(createFeature(feature['id'], type, newGeometry, feature['tags']));
      //print("IN CLIP FINISHED CREATE FEATURE");
    }
  }
  //print("FINISHED CLIP FUNC");
  return (clipped.length > 0) ? clipped : [];
}

void clipLines(geom, newGeom, k1, k2, axis, isPolygon) {
  for (var line in geom) {
    clipLine(line, newGeom, k1, k2, axis, isPolygon, false);
  }
}

void clipLine(List geom, newGeom, k1, k2, axis, isPolygon, trackMetrics) {

  //print("CLIPLINE");
  List slice = newSlice(geom);
  final intersect = axis == 0 ? intersectX : intersectY;
  num len = geom.start;
  var segLen, t;

  for (var i = 0; i < geom.length - 3; i += 3) {
    var ax = geom[i];
    var ay = geom[i + 1];
    var az = geom[i + 2];
    var bx = geom[i + 3];
    var by = geom[i + 4];
    var a = axis == 0 ? ax : ay;
    var b = axis == 0 ? bx : by;

    bool exited = false;

    if (trackMetrics) segLen = math.sqrt(math.pow(ax - bx, 2) + math.pow(ay - by, 2));

    if (a < k1) {
      // ---|-->  | (line enters the clip region from the left)
      if (b > k1) {
        t = intersect(slice, ax, ay, bx, by, k1);
        if (trackMetrics) slice.start = len + segLen * t;
      }
    } else if (a > k2) {
      // |  <--|--- (line enters the clip region from the right)
      if (b < k2) {
        t = intersect(slice, ax, ay, bx, by, k2);
        if (trackMetrics) slice.start = len + segLen * t;
      }
    } else {
      addPoint(slice, ax, ay, az);
    }

    if (b < k1 && a >= k1) {
      // <--|---  | or <--|-----|--- (line exits the clip region on the left)
      t = intersect(slice, ax, ay, bx, by, k1);
      exited = true;
    }
    if (b > k2 && a <= k2) {
      // |  ---|--> or ---|-----|--> (line exits the clip region on the right)
      t = intersect(slice, ax, ay, bx, by, k2);
      exited = true;
    }

    if (!isPolygon && exited) {
      if (trackMetrics) slice.end = len + segLen * t;
      newGeom.add(slice);
      slice = newSlice(geom);
    }

    if (trackMetrics) len += segLen;
  }

  int last = geom.length - 3;
  var ax = geom[last];
  var ay = geom[last + 1];
  var az = geom[last + 2];
  var a = axis == 0 ? ax : ay;
  if (a >= k1 && a <= k2) addPoint(slice, ax, ay, az);

  // close the polygon if its endpoints are not the same after clipping
  last = slice.length - 3;

  if (isPolygon && last >= 3 && (slice[last] != slice[0] || slice[last + 1] != slice[1])) {
    addPoint(slice, slice[0], slice[1], slice[2]);
  }

  // add the final slice
  if (slice.length > 0) {
    newGeom.add(slice);
  }

 // print("ENDCLIPLINE");
}

void clipPoints(geom, newGeom, k1, k2, axis) {
  for (var i = 0; i < geom.length; i += 3) {
    var a = geom[i + axis];

    if (a >= k1 && a <= k2) {
      addPoint(newGeom, geom[i], geom[i + 1], geom[i + 2]);
    }
  }
}

List newSlice(List line) {
  List slice = [];

  slice.size = line.size;
  slice.start = line.start;
  slice.end = line.end;
  return slice;
}

double intersectX(out, ax, ay, bx, by, x) {
  final t = (x - ax) / (bx - ax);
  addPoint(out, x, ay + (by - ay) * t, 1);
  return t;
}

double intersectY(out, ax, ay, bx, by, y) {
  final t = (y - ay) / (by - ay);
  addPoint(out, ax + (bx - ax) * t, y, 1);
  return t;
}

void addPoint(out, x, y, z) {
  out.addAll([x, y, z]);
}