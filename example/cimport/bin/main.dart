import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:cimport/cimport.dart' show CImportKind, CImportPoint;
import 'package:cimport/ffi.g.dart';
import 'package:ffi/ffi.dart';

Future<void> main() async {
  stdout.writeln('=== cImport Stress Demo ===');
  stdout.writeln('');

  var packet = cimport_make_packet(CImportKind.packet, 7, 11);
  stdout.writeln(
    'kind name       = ${cimport_kind_name(packet.kind).cast<Utf8>().toDartString()}',
  );
  stdout.writeln('packet checksum = ${cimport_packet_checksum(packet)}');

  var points = calloc<CImportPoint>(2);
  try {
    points[0] = cimport_point_make(1, 1);
    points[1] = cimport_point_make(2, 3);
    stdout.writeln('sum points      = ${cimport_sum_points(points, 2)}');

    var foldCallback = NativeCallable<FoldCallback>.isolateGroupBound(
      (CImportPoint point, Pointer<Void> _) => point.x + point.y,
      exceptionalReturn: 0,
    );
    try {
      stdout.writeln(
        'fold points     = ${cimport_fold_points(points, 2, foldCallback.nativeFunction, nullptr)}',
      );
    } finally {
      foldCallback.close();
    }

    var visitClosed = false;
    var visitCompleter = Completer<int>();
    late NativeCallable<VisitCallback> visitCallback;
    visitCallback = NativeCallable<VisitCallback>.listener((
      Pointer<CImportPoint> point,
      Pointer<Void> _,
    ) {
      if (!visitCompleter.isCompleted) {
        visitCompleter.complete(point.ref.x + point.ref.y);
      }
      if (!visitClosed) {
        visitClosed = true;
        visitCallback.close();
      }
    });

    try {
      cimport_visit_points(points, 2, visitCallback.nativeFunction, nullptr);
      stdout.writeln('visit points    = ${await visitCompleter.future}');
    } finally {
      if (!visitClosed) {
        visitCallback.close();
      }
    }
  } finally {
    calloc.free(points);
  }

  var nativeLabel = 'hello'.toNativeUtf8();
  try {
    var stringValue = cimport_value_from_string(nativeLabel.cast<Uint8>());
    var node1 = cimport_node_create(
      1,
      CImportKind.point,
      cimport_point_make(1, 1),
      cimport_value_from_int(11),
    );
    var node2 = cimport_node_create(
      2,
      CImportKind.blob,
      cimport_point_make(2, 2),
      cimport_value_from_double(2.5),
    );
    var node3 = cimport_node_create(
      3,
      CImportKind.packet,
      cimport_point_make(3, 3),
      stringValue,
    );

    var head = cimport_node_append(cimport_node_append(node1, node2), node3);
    stdout.writeln('node count      = ${cimport_node_count(head)}');
    stdout.writeln('node sum        = ${cimport_node_sum(head)}');
    cimport_node_destroy(head);
  } finally {
    calloc.free(nativeLabel);
  }
}
