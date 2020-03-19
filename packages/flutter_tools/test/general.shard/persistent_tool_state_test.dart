// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/persistent_tool_state.dart';
import 'package:mockito/mockito.dart';

import '../src/common.dart';

class MockLogger extends Mock implements Logger {}

void main() {
  testWithoutContext('state can be set and persists', () {
    final MemoryFileSystem fs = MemoryFileSystem();
    final Directory directory = fs.directory('state_dir');
    directory.createSync();
    final File stateFile = directory.childFile('.flutter_tool_state');
    final PersistentToolState state1 = PersistentToolState.test(
      directory: directory,
      logger: MockLogger(),
    );
    expect(state1.redisplayWelcomeMessage, null);
    state1.redisplayWelcomeMessage = true;
    expect(stateFile.existsSync(), true);
    expect(state1.redisplayWelcomeMessage, true);
    state1.redisplayWelcomeMessage = false;
    expect(state1.redisplayWelcomeMessage, false);

    final PersistentToolState state2 = PersistentToolState.test(
      directory: directory,
      logger: MockLogger(),
    );
    expect(state2.redisplayWelcomeMessage, false);
  });
}
