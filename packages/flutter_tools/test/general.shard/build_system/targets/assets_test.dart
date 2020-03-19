// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/targets/assets.dart';
import 'package:flutter_tools/src/globals.dart' as globals;

import '../../../src/common.dart';
import '../../../src/testbed.dart';

void main() {
  Environment environment;
  Testbed testbed;

  setUp(() {
    testbed = Testbed(setup: () {
      environment = Environment.test(
        globals.fs.currentDirectory,
      );
      globals.fs.file(environment.buildDir.childFile('app.dill')).createSync(recursive: true);
      globals.fs.file(globals.fs.path.join('packages', 'flutter_tools', 'lib', 'src',
          'build_system', 'targets', 'assets.dart'))
        ..createSync(recursive: true);
      globals.fs.file(globals.fs.path.join('assets', 'foo', 'bar.png'))
        ..createSync(recursive: true);
      globals.fs.file(globals.fs.path.join('assets', 'wildcard', '#bar.png'))
        ..createSync(recursive: true);
      globals.fs.file('.packages')
        ..createSync();
      globals.fs.file('pubspec.yaml')
        ..createSync()
        ..writeAsStringSync('''
name: example

flutter:
  assets:
    - assets/foo/bar.png
    - assets/wildcard/
''');
    });
  });

  test('Copies files to correct asset directory', () => testbed.run(() async {
    await const CopyAssets().build(environment);

    expect(globals.fs.file(globals.fs.path.join(environment.buildDir.path, 'flutter_assets', 'AssetManifest.json')).existsSync(), true);
    expect(globals.fs.file(globals.fs.path.join(environment.buildDir.path, 'flutter_assets', 'FontManifest.json')).existsSync(), true);
    expect(globals.fs.file(globals.fs.path.join(environment.buildDir.path, 'flutter_assets', 'LICENSE')).existsSync(), true);
    // See https://github.com/flutter/flutter/issues/35293
    expect(globals.fs.file(globals.fs.path.join(environment.buildDir.path, 'flutter_assets', 'assets/foo/bar.png')).existsSync(), true);
    // See https://github.com/flutter/flutter/issues/46163
    expect(globals.fs.file(globals.fs.path.join(environment.buildDir.path, 'flutter_assets', 'assets/wildcard/%23bar.png')).existsSync(), true);
  }));

  test('FlutterPlugins updates required files as needed', () => testbed.run(() async {
    globals.fs.file('pubspec.yaml')
      ..writeAsStringSync('name: foo\ndependencies:\n  foo: any\n');

    await const FlutterPlugins().build(Environment.test(
      globals.fs.currentDirectory,
    ));

    expect(globals.fs.file('.flutter-plugins').existsSync(), true);
  }));
}
