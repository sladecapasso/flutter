// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:platform/platform.dart';
import 'package:process/process.dart';

import 'android/android_sdk.dart';
import 'android/android_studio.dart';
import 'artifacts.dart';
import 'base/config.dart';
import 'base/context.dart';
import 'base/error_handling_file_system.dart';
import 'base/file_system.dart';
import 'base/io.dart';
import 'base/logger.dart';
import 'base/os.dart';
import 'base/terminal.dart';
import 'base/user_messages.dart';
import 'cache.dart';
import 'ios/mac.dart';
import 'macos/xcode.dart';
import 'persistent_tool_state.dart';
import 'version.dart';

Artifacts get artifacts => context.get<Artifacts>();
Cache get cache => context.get<Cache>();
Config get config => context.get<Config>();
Logger get logger => context.get<Logger>();
OperatingSystemUtils get os => context.get<OperatingSystemUtils>();
PersistentToolState get persistentToolState => PersistentToolState.instance;

const FileSystem _kLocalFs = LocalFileSystem();

/// Currently active implementation of the file system.
///
/// By default it uses local disk-based implementation. Override this in tests
/// with [MemoryFileSystem].
FileSystem get fs => ErrorHandlingFileSystem(
  context.get<FileSystem>() ?? _kLocalFs,
);

final FileSystemUtils _defaultFileSystemUtils = FileSystemUtils(
  fileSystem: fs,
  platform: platform,
);

FileSystemUtils get fsUtils => context.get<FileSystemUtils>() ?? _defaultFileSystemUtils;

const ProcessManager _kLocalProcessManager = LocalProcessManager();

/// The active process manager.
ProcessManager get processManager => context.get<ProcessManager>() ?? _kLocalProcessManager;

const Platform _kLocalPlatform = LocalPlatform();

Platform get platform => context.get<Platform>() ?? _kLocalPlatform;

AndroidStudio get androidStudio => context.get<AndroidStudio>();
AndroidSdk get androidSdk => context.get<AndroidSdk>();
FlutterVersion get flutterVersion => context.get<FlutterVersion>();
IMobileDevice get iMobileDevice => context.get<IMobileDevice>();
UserMessages get userMessages => context.get<UserMessages>();
Xcode get xcode => context.get<Xcode>();

XCDevice get xcdevice => context.get<XCDevice>();

/// Display an error level message to the user. Commands should use this if they
/// fail in some way.
///
/// Set [emphasis] to true to make the output bold if it's supported.
/// Set [color] to a [TerminalColor] to color the output, if the logger
/// supports it. The [color] defaults to [TerminalColor.red].
void printError(
  String message, {
  StackTrace stackTrace,
  bool emphasis,
  TerminalColor color,
  int indent,
  int hangingIndent,
  bool wrap,
}) {
  logger.printError(
    message,
    stackTrace: stackTrace,
    emphasis: emphasis ?? false,
    color: color,
    indent: indent,
    hangingIndent: hangingIndent,
    wrap: wrap,
  );
}

/// Display normal output of the command. This should be used for things like
/// progress messages, success messages, or just normal command output.
///
/// Set `emphasis` to true to make the output bold if it's supported.
///
/// Set `newline` to false to skip the trailing linefeed.
///
/// If `indent` is provided, each line of the message will be prepended by the
/// specified number of whitespaces.
void printStatus(
  String message, {
  bool emphasis,
  bool newline,
  TerminalColor color,
  int indent,
  int hangingIndent,
  bool wrap,
}) {
  logger.printStatus(
    message,
    emphasis: emphasis ?? false,
    color: color,
    newline: newline ?? true,
    indent: indent,
    hangingIndent: hangingIndent,
    wrap: wrap,
  );
}

/// Use this for verbose tracing output. Users can turn this output on in order
/// to help diagnose issues with the toolchain or with their setup.
void printTrace(String message) => logger.printTrace(message);

AnsiTerminal get terminal {
  return context?.get<AnsiTerminal>() ?? _defaultAnsiTerminal;
}

final AnsiTerminal _defaultAnsiTerminal = AnsiTerminal(
  stdio: stdio,
  platform: platform,
);

/// The global Stdio wrapper.
Stdio get stdio => context.get<Stdio>() ?? const Stdio();
