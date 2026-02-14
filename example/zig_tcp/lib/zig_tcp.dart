/// TCP sockets.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io' hide SocketException;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/ffi.dart';

part 'src/address.dart';
part 'src/connection.dart';
part 'src/exception.dart';
part 'src/io_service.dart';
part 'src/listener.dart';
