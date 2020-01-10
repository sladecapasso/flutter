// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:core' hide print;
import 'dart:io' hide exit;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;

import 'run_command.dart';
import 'utils.dart';

final String flutterRoot = path.dirname(path.dirname(path.dirname(path.fromUri(Platform.script))));
final String flutter = path.join(flutterRoot, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');
final String dart = path.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', Platform.isWindows ? 'dart.exe' : 'dart');
final String pub = path.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', Platform.isWindows ? 'pub.bat' : 'pub');
final String pubCache = path.join(flutterRoot, '.pub-cache');

/// When you call this, you can pass additional arguments to pass custom
/// arguments to flutter analyze. For example, you might want to call this
/// script with the parameter --dart-sdk to use custom dart sdk.
///
/// For example:
/// bin/cache/dart-sdk/bin/dart dev/bots/analyze.dart --dart-sdk=/tmp/dart-sdk
Future<void> main(List<String> arguments) async {
  print('$clock STARTING ANALYSIS');
  try {
    await run(arguments);
  } on ExitException catch (error) {
    error.apply();
  }
  print('$clock ${bold}Analysis successful.$reset');
}

Future<void> run(List<String> arguments) async {
  bool assertsEnabled = false;
  assert(() { assertsEnabled = true; return true; }());
  if (!assertsEnabled) {
    exitWithError(<String>['The analyze.dart script must be run with --enable-asserts.']);
  }

  print('$clock Unexpected binaries...');
  await verifyNoBinaries(flutterRoot);

  print('$clock Trailing spaces...');
  await verifyNoTrailingSpaces(flutterRoot); // assumes no unexpected binaries, so should be after verifyNoBinaries

  print('$clock Deprecations...');
  await verifyDeprecations(flutterRoot);

  print('$clock Licenses...');
  await verifyNoMissingLicense(flutterRoot);

  print('$clock Test imports...');
  await verifyNoTestImports(flutterRoot);

  print('$clock Test package imports...');
  await verifyNoTestPackageImports(flutterRoot);

  print('$clock Generated plugin registrants...');
  await verifyGeneratedPluginRegistrants(flutterRoot);

  print('$clock Bad imports (framework)...');
  await verifyNoBadImportsInFlutter(flutterRoot);

  print('$clock Bad imports (tools)...');
  await verifyNoBadImportsInFlutterTools(flutterRoot);

  print('$clock Internationalization...');
  await verifyInternationalizations();

  // Ensure that all package dependencies are in sync.
  print('$clock Package dependencies...');
  await runCommand(flutter, <String>['update-packages', '--verify-only'],
    workingDirectory: flutterRoot,
  );

  // Analyze all the Dart code in the repo.
  print('$clock Dart analysis...');
  await _runFlutterAnalyze(flutterRoot, options: <String>[
    '--flutter-repo',
    ...arguments,
  ]);

  // Try with the --watch analyzer, to make sure it returns success also.
  // The --benchmark argument exits after one run.
  print('$clock Dart analysis (with --watch)...');
  await _runFlutterAnalyze(flutterRoot, options: <String>[
    '--flutter-repo',
    '--watch',
    '--benchmark',
    ...arguments,
  ]);

  // Analyze all the sample code in the repo
  print('$clock Sample code...');
  await runCommand(dart,
    <String>[path.join(flutterRoot, 'dev', 'bots', 'analyze-sample-code.dart')],
    workingDirectory: flutterRoot,
  );

  // Try analysis against a big version of the gallery; generate into a temporary directory.
  print('$clock Dart analysis (mega gallery)...');
  final Directory outDir = Directory.systemTemp.createTempSync('flutter_mega_gallery.');
  try {
    await runCommand(dart,
      <String>[
        path.join(flutterRoot, 'dev', 'tools', 'mega_gallery.dart'),
        '--out',
        outDir.path,
      ],
      workingDirectory: flutterRoot,
    );
    await _runFlutterAnalyze(outDir.path, options: <String>[
      '--watch',
      '--benchmark',
      ...arguments,
    ]);
  } finally {
    outDir.deleteSync(recursive: true);
  }
}


// TESTS

final RegExp _findDeprecationPattern = RegExp(r'@[Dd]eprecated');
final RegExp _deprecationPattern1 = RegExp(r'^( *)@Deprecated\($'); // ignore: flutter_deprecation_syntax (see analyze.dart)
final RegExp _deprecationPattern2 = RegExp(r"^ *'(.+) '$");
final RegExp _deprecationPattern3 = RegExp(r"^ *'This feature was deprecated after v([0-9]+)\.([0-9]+)\.([0-9]+)\.'$");
final RegExp _deprecationPattern4 = RegExp(r'^ *\)$');

/// Some deprecation notices are special, for example they're used to annotate members that
/// will never go away and were never allowed but which we are trying to show messages for.
/// (One example would be a library that intentionally conflicts with a member in another
/// library to indicate that it is incompatible with that other library. Another would be
/// the regexp just above...)
const String _ignoreDeprecation = ' // ignore: flutter_deprecation_syntax (see analyze.dart)';

/// Some deprecation notices are grand-fathered in for now. They must have an issue listed.
final RegExp _grandfatheredDeprecation = RegExp(r' // ignore: flutter_deprecation_syntax, https://github.com/flutter/flutter/issues/[0-9]+$');

Future<void> verifyDeprecations(String workingDirectory, { int minimumMatches = 2000 }) async {
  final List<String> errors = <String>[];
  for (final File file in _allFiles(workingDirectory, 'dart', minimumMatches: minimumMatches)) {
    int lineNumber = 0;
    final List<String> lines = file.readAsLinesSync();
    final List<int> linesWithDeprecations = <int>[];
    for (final String line in lines) {
      if (line.contains(_findDeprecationPattern) &&
          !line.endsWith(_ignoreDeprecation) &&
          !line.contains(_grandfatheredDeprecation)) {
        linesWithDeprecations.add(lineNumber);
      }
      lineNumber += 1;
    }
    for (int lineNumber in linesWithDeprecations) {
      try {
        final Match match1 = _deprecationPattern1.firstMatch(lines[lineNumber]);
        if (match1 == null)
          throw 'Deprecation notice does not match required pattern.';
        final String indent = match1[1];
        lineNumber += 1;
        if (lineNumber >= lines.length)
          throw 'Incomplete deprecation notice.';
        Match match3;
        String message;
        do {
          final Match match2 = _deprecationPattern2.firstMatch(lines[lineNumber]);
          if (match2 == null)
            throw 'Deprecation notice does not match required pattern.';
          if (!lines[lineNumber].startsWith("$indent  '"))
            throw 'Unexpected deprecation notice indent.';
          if (message == null) {
            final String firstChar = String.fromCharCode(match2[1].runes.first);
            if (firstChar.toUpperCase() != firstChar)
              throw 'Deprecation notice should be a grammatically correct sentence and start with a capital letter; see style guide.';
          }
          message = match2[1];
          lineNumber += 1;
          if (lineNumber >= lines.length)
            throw 'Incomplete deprecation notice.';
          match3 = _deprecationPattern3.firstMatch(lines[lineNumber]);
        } while (match3 == null);
        if (!message.endsWith('.') && !message.endsWith('!') && !message.endsWith('?'))
          throw 'Deprecation notice should be a grammatically correct sentence and end with a period.';
        if (!lines[lineNumber].startsWith("$indent  '"))
          throw 'Unexpected deprecation notice indent.';
        lineNumber += 1;
        if (lineNumber >= lines.length)
          throw 'Incomplete deprecation notice.';
        if (!lines[lineNumber].contains(_deprecationPattern4))
          throw 'End of deprecation notice does not match required pattern.';
        if (!lines[lineNumber].startsWith('$indent)'))
          throw 'Unexpected deprecation notice indent.';
      } catch (error) {
        errors.add('${file.path}:${lineNumber + 1}: $error');
      }
    }
  }
  // Fail if any errors
  if (errors.isNotEmpty) {
    exitWithError(<String>[
      ...errors,
      '${bold}See: https://github.com/flutter/flutter/wiki/Tree-hygiene#handling-breaking-changes$reset',
    ]);
  }
}

String _generateLicense(String prefix) {
  assert(prefix != null);
  return '${prefix}Copyright 2014 The Flutter Authors. All rights reserved.\n'
         '${prefix}Use of this source code is governed by a BSD-style license that can be\n'
         '${prefix}found in the LICENSE file.';
}

Future<void> verifyNoMissingLicense(String workingDirectory, { bool checkMinimums = true }) async {
  final int overrideMinimumMatches = checkMinimums ? null : 0;
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'dart', overrideMinimumMatches ?? 2000, _generateLicense('// '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'java', overrideMinimumMatches ?? 40, _generateLicense('// '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'h', overrideMinimumMatches ?? 30, _generateLicense('// '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'm', overrideMinimumMatches ?? 30, _generateLicense('// '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'swift', overrideMinimumMatches ?? 10, _generateLicense('// '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'gradle', overrideMinimumMatches ?? 100, _generateLicense('// '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'gn', overrideMinimumMatches ?? 0, _generateLicense('# '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'sh', overrideMinimumMatches ?? 1, '#!/usr/bin/env bash\n' + _generateLicense('# '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'bat', overrideMinimumMatches ?? 1, '@ECHO off\n' + _generateLicense('REM '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'ps1', overrideMinimumMatches ?? 1, _generateLicense('# '));
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'html', overrideMinimumMatches ?? 1, '<!DOCTYPE HTML>\n<!-- ${_generateLicense('')} -->', trailingBlank: false);
  await _verifyNoMissingLicenseForExtension(workingDirectory, 'xml', overrideMinimumMatches ?? 1, '<!-- ${_generateLicense('')} -->');
}

Future<void> _verifyNoMissingLicenseForExtension(String workingDirectory, String extension, int minimumMatches, String license, { bool trailingBlank = true }) async {
  assert(!license.endsWith('\n'));
  final String licensePattern = license + '\n' + (trailingBlank ? '\n' : '');
  final List<String> errors = <String>[];
  for (final File file in _allFiles(workingDirectory, extension, minimumMatches: minimumMatches)) {
    final String contents = file.readAsStringSync().replaceAll('\r\n', '\n');
    if (contents.isEmpty)
      continue; // let's not go down the /bin/true rabbit hole
    if (!contents.startsWith(licensePattern))
      errors.add(file.path);
  }
  // Fail if any errors
  if (errors.isNotEmpty) {
    final String s = errors.length == 1 ? ' does' : 's do';
    exitWithError(<String>[
      '${bold}The following ${errors.length} file$s not have the right license header:$reset',
      ...errors,
      'The expected license header is:',
      license,
      if (trailingBlank) '...followed by a blank line.',
    ]);
  }
}

final RegExp _testImportPattern = RegExp(r'''import (['"])([^'"]+_test\.dart)\1''');
const Set<String> _exemptTestImports = <String>{
  'package:flutter_test/flutter_test.dart',
  'hit_test.dart',
  'package:test_api/src/backend/live_test.dart',
};

Future<void> verifyNoTestImports(String workingDirectory) async {
  final List<String> errors = <String>[];
  assert("// foo\nimport 'binding_test.dart' as binding;\n'".contains(_testImportPattern));
  final List<File> dartFiles = _allFiles(path.join(workingDirectory, 'packages'), 'dart', minimumMatches: 1500).toList();
  for (final File file in dartFiles) {
    for (final String line in file.readAsLinesSync()) {
      final Match match = _testImportPattern.firstMatch(line);
      if (match != null && !_exemptTestImports.contains(match.group(2)))
        errors.add(file.path);
    }
  }
  // Fail if any errors
  if (errors.isNotEmpty) {
    final String s = errors.length == 1 ? '' : 's';
    exitWithError(<String>[
      '${bold}The following file$s import a test directly. Test utilities should be in their own file.$reset',
      ...errors,
    ]);
  }
}

Future<void> verifyNoTestPackageImports(String workingDirectory) async {
  // TODO(ianh): Remove this whole test once https://github.com/dart-lang/matcher/issues/98 is fixed.
  final List<String> shims = <String>[];
  final List<String> errors = _allFiles(workingDirectory, 'dart', minimumMatches: 2000)
    .map<String>((File file) {
      final String name = Uri.file(path.relative(file.path,
          from: workingDirectory)).toFilePath(windows: false);
      if (name.startsWith('bin/cache') ||
          name == 'dev/bots/test.dart' ||
          name.startsWith('.pub-cache'))
        return null;
      final String data = file.readAsStringSync();
      if (data.contains("import 'package:test/test.dart'")) {
        if (data.contains("// Defines a 'package:test' shim.")) {
          shims.add('  $name');
          if (!data.contains('https://github.com/dart-lang/matcher/issues/98'))
            return '  $name: Shims must link to the isInstanceOf issue.';
          if (data.contains("import 'package:test/test.dart' hide TypeMatcher, isInstanceOf;") &&
              data.contains("export 'package:test/test.dart' hide TypeMatcher, isInstanceOf;"))
            return null;
          return '  $name: Shim seems to be missing the expected import/export lines.';
        }
        final int count = 'package:test'.allMatches(data).length;
        if (path.split(file.path).contains('test_driver') ||
            name.startsWith('dev/missing_dependency_tests/') ||
            name.startsWith('dev/automated_tests/') ||
            name.startsWith('dev/snippets/') ||
            name.startsWith('packages/flutter/test/engine/') ||
            name.startsWith('examples/layers/test/smoketests/raw/') ||
            name.startsWith('examples/layers/test/smoketests/rendering/') ||
            name.startsWith('examples/flutter_gallery/test/calculator')) {
          // We only exempt driver tests, some of our special trivial tests.
          // Driver tests aren't typically expected to use TypeMatcher and company.
          // The trivial tests don't typically do anything at all and it would be
          // a pain to have to give them a shim.
          if (!data.contains("import 'package:test/test.dart' hide TypeMatcher, isInstanceOf;"))
            return '  $name: test does not hide TypeMatcher and isInstanceOf from package:test; consider using a shim instead.';
          assert(count > 0);
          if (count == 1)
            return null;
          return '  $name: uses \'package:test\' $count times.';
        }
        if (name.startsWith('packages/flutter_test/')) {
          // flutter_test has deep ties to package:test
          return null;
        }
        if (data.contains("import 'package:test/test.dart' as test_package;") ||
            data.contains("import 'package:test/test.dart' as test_package show ")) {
          if (count == 1)
            return null;
        }
        return '  $name: uses \'package:test\' directly';
      }
      return null;
    })
    .where((String line) => line != null)
    .toList()
    ..sort();

  // Fail if any errors
  if (errors.isNotEmpty) {
    final String s1 = errors.length == 1 ? 's' : '';
    final String s2 = errors.length == 1 ? '' : 's';
    exitWithError(<String>[
      '${bold}The following file$s2 use$s1 \'package:test\' incorrectly:$reset',
      ...errors,
      'Rather than depending on \'package:test\' directly, use one of the shims:',
      ...shims,
      'This insulates us from breaking changes in \'package:test\'.'
    ]);
  }
}

Future<void> verifyGeneratedPluginRegistrants(String flutterRoot) async {
  final Directory flutterRootDir = Directory(flutterRoot);

  final Map<String, List<File>> packageToRegistrants = <String, List<File>>{};

  for (final File file in flutterRootDir.listSync(recursive: true).whereType<File>().where(_isGeneratedPluginRegistrant)) {
    final String package = _getPackageFor(file, flutterRootDir);
    final List<File> registrants = packageToRegistrants.putIfAbsent(package, () => <File>[]);
    registrants.add(file);
  }

  final Set<String> outOfDate = <String>{};

  for (final String package in packageToRegistrants.keys) {
    final Map<File, String> fileToContent = <File, String>{};
    for (final File f in packageToRegistrants[package]) {
      fileToContent[f] = f.readAsStringSync();
    }
    await runCommand(flutter, <String>['inject-plugins'],
      workingDirectory: package,
      outputMode: OutputMode.discard,
    );
    for (final File registrant in fileToContent.keys) {
      if (registrant.readAsStringSync() != fileToContent[registrant]) {
        outOfDate.add(registrant.path);
      }
    }
  }

  if (outOfDate.isNotEmpty) {
    exitWithError(<String>[
      '${bold}The following GeneratedPluginRegistrants are out of date:$reset',
      for (String registrant in outOfDate) ' - $registrant',
      '\nRun "flutter inject-plugins" in the package that\'s out of date.',
    ]);
  }
}

Future<void> verifyNoBadImportsInFlutter(String workingDirectory) async {
  final List<String> errors = <String>[];
  final String libPath = path.join(workingDirectory, 'packages', 'flutter', 'lib');
  final String srcPath = path.join(workingDirectory, 'packages', 'flutter', 'lib', 'src');
  // Verify there's one libPath/*.dart for each srcPath/*/.
  final List<String> packages = Directory(libPath).listSync()
    .where((FileSystemEntity entity) => entity is File && path.extension(entity.path) == '.dart')
    .map<String>((FileSystemEntity entity) => path.basenameWithoutExtension(entity.path))
    .toList()..sort();
  final List<String> directories = Directory(srcPath).listSync()
    .whereType<Directory>()
    .map<String>((Directory entity) => path.basename(entity.path))
    .toList()..sort();
  if (!_listEquals<String>(packages, directories)) {
    errors.add(
      'flutter/lib/*.dart does not match flutter/lib/src/*/:\n'
      'These are the exported packages:\n' +
      packages.map<String>((String path) => '  lib/$path.dart').join('\n') +
      'These are the directories:\n' +
      directories.map<String>((String path) => '  lib/src/$path/').join('\n')
    );
  }
  // Verify that the imports are well-ordered.
  final Map<String, Set<String>> dependencyMap = <String, Set<String>>{};
  for (final String directory in directories) {
    dependencyMap[directory] = _findFlutterDependencies(path.join(srcPath, directory), errors, checkForMeta: directory != 'foundation');
  }
  assert(dependencyMap['material'].contains('widgets') &&
         dependencyMap['widgets'].contains('rendering') &&
         dependencyMap['rendering'].contains('painting')); // to make sure we're convinced _findFlutterDependencies is finding some
  for (final String package in dependencyMap.keys) {
    if (dependencyMap[package].contains(package)) {
      errors.add(
        'One of the files in the $yellow$package$reset package imports that package recursively.'
      );
    }
  }

  for (final String key in dependencyMap.keys) {
    for (final String dependency in dependencyMap[key]) {
      if (dependencyMap[dependency] != null)
        continue;
      // Sanity check before performing _deepSearch, to ensure there's no rogue
      // dependencies.
      final String validFilenames = dependencyMap.keys.map((String name) => name + '.dart').join(', ');
      errors.add(
        '$key imported package:flutter/$dependency.dart '
        'which is not one of the valid exports { $validFilenames }.\n'
        'Consider changing $dependency.dart to one of them.'
      );
    }
  }

  for (final String package in dependencyMap.keys) {
    final List<String> loop = _deepSearch<String>(dependencyMap, package);
    if (loop != null) {
      errors.add(
        '${yellow}Dependency loop:$reset ' +
        loop.join(' depends on ')
      );
    }
  }
  // Fail if any errors
  if (errors.isNotEmpty) {
    exitWithError(<String>[
      if (errors.length == 1)
        '${bold}An error was detected when looking at import dependencies within the Flutter package:$reset'
      else
        '${bold}Multiple errors were detected when looking at import dependencies within the Flutter package:$reset',
      ...errors,
    ]);
  }
}

Future<void> verifyNoBadImportsInFlutterTools(String workingDirectory) async {
  final List<String> errors = <String>[];
  final List<File> files = _allFiles(path.join(workingDirectory, 'packages', 'flutter_tools', 'lib'), 'dart', minimumMatches: 200).toList();
  for (final File file in files) {
    if (file.readAsStringSync().contains('package:flutter_tools/')) {
      errors.add('$yellow${file.path}$reset imports flutter_tools.');
    }
  }
  // Fail if any errors
  if (errors.isNotEmpty) {
    exitWithError(<String>[
      if (errors.length == 1)
        '${bold}An error was detected when looking at import dependencies within the flutter_tools package:$reset'
      else
        '${bold}Multiple errors were detected when looking at import dependencies within the flutter_tools package:$reset',
      ...errors.map((String paragraph) => '$paragraph\n'),
    ]);
  }
}

Future<void> verifyInternationalizations() async {
  final EvalResult materialGenResult = await _evalCommand(
    dart,
    <String>[
      path.join('dev', 'tools', 'localization', 'bin', 'gen_localizations.dart'),
      '--material',
    ],
    workingDirectory: flutterRoot,
  );
  final EvalResult cupertinoGenResult = await _evalCommand(
    dart,
    <String>[
      path.join('dev', 'tools', 'localization', 'bin', 'gen_localizations.dart'),
      '--cupertino',
    ],
    workingDirectory: flutterRoot,
  );

  final String materialLocalizationsFile = path.join('packages', 'flutter_localizations', 'lib', 'src', 'l10n', 'generated_material_localizations.dart');
  final String cupertinoLocalizationsFile = path.join('packages', 'flutter_localizations', 'lib', 'src', 'l10n', 'generated_cupertino_localizations.dart');
  final String expectedMaterialResult = await File(materialLocalizationsFile).readAsString();
  final String expectedCupertinoResult = await File(cupertinoLocalizationsFile).readAsString();

  if (materialGenResult.stdout.trim() != expectedMaterialResult.trim()) {
    exitWithError(<String>[
      '<<<<<<< $materialLocalizationsFile',
      expectedMaterialResult.trim(),
      '=======',
      materialGenResult.stdout.trim(),
      '>>>>>>> gen_localizations',
      'The contents of $materialLocalizationsFile are different from that produced by gen_localizations.',
      '',
      'Did you forget to run gen_localizations.dart after updating a .arb file?',
    ]);
  }
  if (cupertinoGenResult.stdout.trim() != expectedCupertinoResult.trim()) {
    exitWithError(<String>[
      '<<<<<<< $cupertinoLocalizationsFile',
      expectedCupertinoResult.trim(),
      '=======',
      cupertinoGenResult.stdout.trim(),
      '>>>>>>> gen_localizations',
      'The contents of $cupertinoLocalizationsFile are different from that produced by gen_localizations.',
      '',
      'Did you forget to run gen_localizations.dart after updating a .arb file?',
    ]);
  }
}

Future<void> verifyNoTrailingSpaces(String workingDirectory, { int minimumMatches = 4000 }) async {
  final List<File> files = _allFiles(workingDirectory, null, minimumMatches: minimumMatches)
    .where((File file) => path.basename(file.path) != 'serviceaccount.enc')
    .where((File file) => path.basename(file.path) != 'Ahem.ttf')
    .where((File file) => path.extension(file.path) != '.snapshot')
    .where((File file) => path.extension(file.path) != '.png')
    .where((File file) => path.extension(file.path) != '.jpg')
    .where((File file) => path.extension(file.path) != '.jar')
    .toList();
  final List<String> problems = <String>[];
  for (final File file in files) {
    final List<String> lines = file.readAsLinesSync();
    for (int index = 0; index < lines.length; index += 1) {
      if (lines[index].endsWith(' ')) {
        problems.add('${file.path}:${index + 1}: trailing U+0020 space character');
      } else if (lines[index].endsWith('\t')) {
        problems.add('${file.path}:${index + 1}: trailing U+0009 tab character');
      }
    }
    if (lines.isNotEmpty && lines.last == '')
      problems.add('${file.path}:${lines.length}: trailing blank line');
  }
  if (problems.isNotEmpty)
    exitWithError(problems);
}

class Hash256 {
  Hash256(this.a, this.b, this.c, this.d);

  factory Hash256.fromDigest(Digest digest) {
    assert(digest.bytes.length == 32);
    return Hash256(
      digest.bytes[ 0] << 56 |
      digest.bytes[ 1] << 48 |
      digest.bytes[ 2] << 40 |
      digest.bytes[ 3] << 32 |
      digest.bytes[ 4] << 24 |
      digest.bytes[ 5] << 16 |
      digest.bytes[ 6] <<  8 |
      digest.bytes[ 7] <<  0,
      digest.bytes[ 8] << 56 |
      digest.bytes[ 9] << 48 |
      digest.bytes[10] << 40 |
      digest.bytes[11] << 32 |
      digest.bytes[12] << 24 |
      digest.bytes[13] << 16 |
      digest.bytes[14] <<  8 |
      digest.bytes[15] <<  0,
      digest.bytes[16] << 56 |
      digest.bytes[17] << 48 |
      digest.bytes[18] << 40 |
      digest.bytes[19] << 32 |
      digest.bytes[20] << 24 |
      digest.bytes[21] << 16 |
      digest.bytes[22] <<  8 |
      digest.bytes[23] <<  0,
      digest.bytes[24] << 56 |
      digest.bytes[25] << 48 |
      digest.bytes[26] << 40 |
      digest.bytes[27] << 32 |
      digest.bytes[28] << 24 |
      digest.bytes[29] << 16 |
      digest.bytes[30] <<  8 |
      digest.bytes[31] <<  0,
    );
  }

  final int a;
  final int b;
  final int c;
  final int d;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType)
      return false;
    return other is Hash256
        && other.a == a
        && other.b == b
        && other.c == c
        && other.d == d;
  }

  @override
  int get hashCode => a ^ b ^ c ^ d;
}

// DO NOT ADD ANY ENTRIES TO THIS LIST.
// We have a policy of not checking in binaries into this repository.
// If you have binaries to add, please consult Hixie for advice.
final Set<Hash256> _grandfatheredBinaries = <Hash256>{
  // DEFAULT ICON IMAGES

  // packages/flutter_tools/templates/app/android.tmpl/app/src/main/res/mipmap-hdpi/ic_launcher.png
  // packages/flutter_tools/templates/module/android/host_app_common/app.tmpl/src/main/res/mipmap-hdpi/ic_launcher.png
  // (also used by many examples)
  Hash256(0x6A7C8F0D703E3682, 0x108F9662F8133022, 0x36240D3F8F638BB3, 0x91E32BFB96055FEF),

  // packages/flutter_tools/templates/app/android.tmpl/app/src/main/res/mipmap-mdpi/ic_launcher.png
  // (also used by many examples)
  Hash256(0xC7C0C0189145E4E3, 0x2A401C61C9BDC615, 0x754B0264E7AFAE24, 0xE834BB81049EAF81),

  // packages/flutter_tools/templates/app/android.tmpl/app/src/main/res/mipmap-xhdpi/ic_launcher.png
  // (also used by many examples)
  Hash256(0xE14AA40904929BF3, 0x13FDED22CF7E7FFC, 0xBF1D1AAC4263B5EF, 0x1BE8BFCE650397AA),

  // packages/flutter_tools/templates/app/android.tmpl/app/src/main/res/mipmap-xxhdpi/ic_launcher.png
  // (also used by many examples)
  Hash256(0x4D470BF22D5C17D8, 0x4EDC5F82516D1BA8, 0xA1C09559CD761CEF, 0xB792F86D9F52B540),

  // packages/flutter_tools/templates/app/android.tmpl/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png
  // (also used by many examples)
  Hash256(0x3C34E1F298D0C9EA, 0x3455D46DB6B7759C, 0x8211A49E9EC6E44B, 0x635FC5C87DFB4180),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png
  // (also used by a few examples)
  Hash256(0x7770183009E91411, 0x2DE7D8EF1D235A6A, 0x30C5834424858E0D, 0x2F8253F6B8D31926),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png
  // (also used by many examples)
  Hash256(0x5925DAB509451F9E, 0xCBB12CE8A625F9D4, 0xC104718EE20CAFF8, 0xB1B51032D1CD8946),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png
  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png
  // (also used by many examples)
  Hash256(0xC4D9A284C12301D0, 0xF50E248EC53ED51A, 0x19A10147B774B233, 0x08399250B0D44C55),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png
  // (also used by many examples)
  Hash256(0xBF97F9D3233F33E1, 0x389B09F7B8ADD537, 0x41300CB834D6C7A5, 0xCA32CBED363A4FB2),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png
  // (also used by many examples)
  Hash256(0x285442F69A06B45D, 0x9D79DF80321815B5, 0x46473548A37B7881, 0x9B68959C7B8ED237),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png
  // (also used by many examples)
  Hash256(0x2AB64AF8AC727EA9, 0x9C6AB9EAFF847F46, 0xFBF2A9A0A78A0ABC, 0xBF3180F3851645B4),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png
  // (also used by many examples)
  Hash256(0x9DCA09F4E5ED5684, 0xD3C4DFF41F4E8B7C, 0xB864B438172D72BE, 0x069315FA362930F9),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png
  // (also used by many examples)
  Hash256(0xD5AD04DE321EF37C, 0xACC5A7B960AFCCE7, 0x1BDCB96FA020C482, 0x49C1545DD1A0F497),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png
  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png
  // (also used by many examples)
  Hash256(0x809ABFE75C440770, 0xC13C4E2E46D09603, 0xC22053E9D4E0E227, 0x5DCB9C1DCFBB2C75),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png
  // (also used by many examples)
  Hash256(0x3DB08CB79E7B01B9, 0xE81F956E3A0AE101, 0x48D0FAFDE3EA7AA7, 0x0048DF905AA52CFD),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png
  // (also used by many examples)
  Hash256(0x23C13D463F5DCA5C, 0x1F14A14934003601, 0xC29F1218FD461016, 0xD8A22CEF579A665F),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png
  // (also used by many examples)
  Hash256(0x6DB7726530D71D3F, 0x52CB59793EB69131, 0x3BAA04796E129E1E, 0x043C0A58A1BFFD2F),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png
  // (also used by many examples)
  Hash256(0xCEE565F5E6211656, 0x9B64980B209FD5CA, 0x4B3D3739011F5343, 0x250B33A1A2C6EB65),

  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png
  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png
  // packages/flutter_tools/templates/app/ios.tmpl/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/LaunchImage.imageset/LaunchImage.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png
  // packages/flutter_tools/templates/module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png
  // (also used by many examples)
  Hash256(0x93AE7D494FAD0FB3, 0x0CBF3AE746A39C4B, 0xC7A0F8BBF87FBB58, 0x7A3F3C01F3C5CE20),

  // packages/flutter_tools/templates/app/macos.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png
  // (also used by a few examples)
  Hash256(0xB18BEBAAD1AD6724, 0xE48BCDF699BA3927, 0xDF3F258FEBE646A3, 0xAB5C62767C6BAB40),

  // packages/flutter_tools/templates/app/macos.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png
  // (also used by a few examples)
  Hash256(0xF90D839A289ECADB, 0xF2B0B3400DA43EB8, 0x08B84908335AE4A0, 0x07457C4D5A56A57C),

  // packages/flutter_tools/templates/app/macos.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png
  // (also used by a few examples)
  Hash256(0x592C2ABF84ADB2D3, 0x91AED8B634D3233E, 0x2C65369F06018DCD, 0x8A4B27BA755EDCBE),

  // packages/flutter_tools/templates/app/macos.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png
  // (also used by a few examples)
  Hash256(0x75D9A0C034113CA8, 0xA1EC11C24B81F208, 0x6630A5A5C65C7D26, 0xA5DC03A1C0A4478C),

  // packages/flutter_tools/templates/app/macos.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png
  // (also used by a few examples)
  Hash256(0xA896E65745557732, 0xC72BD4EE3A10782F, 0xE2AA95590B5AF659, 0x869E5808DB9C01C1),

  // packages/flutter_tools/templates/app/macos.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png
  // (also used by a few examples)
  Hash256(0x3A69A8A1AAC5D9A8, 0x374492AF4B6D07A4, 0xCE637659EB24A784, 0x9C4DFB261D75C6A3),

  // packages/flutter_tools/templates/app/macos.tmpl/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png
  // (also used by a few examples)
  Hash256(0xD29D4E0AF9256DC9, 0x2D0A8F8810608A5E, 0x64A132AD8B397CA2, 0xC4DDC0B1C26A68C3),

  // packages/flutter_tools/templates/app/web/icons/Icon-192.png.copy.tmpl
  // examples/flutter_gallery/web/icons/Icon-192.png
  Hash256(0x3DCE99077602F704, 0x21C1C6B2A240BC9B, 0x83D64D86681D45F2, 0x154143310C980BE3),

  // packages/flutter_tools/templates/app/web/icons/Icon-512.png.copy.tmpl
  // examples/flutter_gallery/web/icons/Icon-512.png
  Hash256(0xBACCB205AE45f0B4, 0x21BE1657259B4943, 0xAC40C95094AB877F, 0x3BCBE12CD544DCBE),

  // GALLERY ICONS

  // examples/flutter_gallery/android/app/src/main/res/mipmap-hdpi/ic_background.png
  Hash256(0x03CFDE53C249475C, 0x277E8B8E90AC8A13, 0xE5FC13C358A94CCB, 0x67CA866C9862A0DD),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-hdpi/ic_foreground.png
  Hash256(0x86A83E23A505EFCC, 0x39C358B699EDE12F, 0xC088EE516A1D0C73, 0xF3B5D74DDAD164B1),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-hdpi/ic_launcher.png
  Hash256(0xD813B1A77320355E, 0xB68C485CD47D0F0F, 0x3C7E1910DCD46F08, 0x60A6401B8DC13647),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-xhdpi/ic_background.png
  Hash256(0x35AFA76BD5D6053F, 0xEE927436C78A8794, 0xA8BA5F5D9FC9653B, 0xE5B96567BB7215ED),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-xhdpi/ic_foreground.png
  Hash256(0x263CE9B4F1F69B43, 0xEBB08AE9FE8F80E7, 0x95647A59EF2C040B, 0xA8AEB246861A7DFF),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png
  Hash256(0x5E1A93C3653BAAFF, 0x1AAC6BCEB8DCBC2F, 0x2AE7D68ECB07E507, 0xCB1FA8354B28313A),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-xxhdpi/ic_background.png
  Hash256(0xA5C77499151DDEC6, 0xDB40D0AC7321FD74, 0x0646C0C0F786743F, 0x8F3C3C408CAC5E8C),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-xxhdpi/ic_foreground.png
  Hash256(0x33DE450980A2A16B, 0x1982AC7CDC1E7B01, 0x919E07E0289C2139, 0x65F85BCED8895FEF),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png
  Hash256(0xC3B8577F4A89BA03, 0x830944FB06C3566B, 0x4C99140A2CA52958, 0x089BFDC3079C59B7),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-xxxhdpi/ic_background.png
  Hash256(0xDEBC241D6F9C5767, 0x8980FDD46FA7ED0C, 0x5B8ACD26BCC5E1BC, 0x473C89B432D467AD),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-xxxhdpi/ic_foreground.png
  Hash256(0xBEFE5F7E82BF8B64, 0x148D869E3742004B, 0xF821A9F5A1BCDC00, 0x357D246DCC659DC2),

  // examples/flutter_gallery/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png
  Hash256(0xC385404341FF9EDD, 0x30FBE76F0EC99155, 0x8EA4F4AFE8CC0C60, 0x1CA3EDEF177E1DA8),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-1024.png
  Hash256(0x6BE5751A29F57A80, 0x36A4B31CC542C749, 0x984E49B22BD65CAA, 0x75AE8B2440848719),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-120.png
  Hash256(0x9972A2264BFA8F8D, 0x964AFE799EADC1FA, 0x2247FB31097F994A, 0x1495DC32DF071793),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-152.png
  Hash256(0x4C7CC9B09BEEDA24, 0x45F57D6967753910, 0x57D68E1A6B883D2C, 0x8C52701A74F1400F),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-167.png
  Hash256(0x66DACAC1CFE4D349, 0xDBE994CB9125FFD7, 0x2D795CFC9CF9F739, 0xEDBB06CE25082E9C),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-180.png
  Hash256(0x5188621015EBC327, 0xC9EF63AD76E60ECE, 0xE82BDC3E4ABF09E2, 0xEE0139FA7C0A2BE5),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-20.png
  Hash256(0x27D2752D04EE9A6B, 0x78410E208F74A6CD, 0xC90D9E03B73B8C60, 0xD05F7D623E790487),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-29.png
  Hash256(0xBB20556B2826CF85, 0xD5BAC73AA69C2AC3, 0x8E71DAD64F15B855, 0xB30CB73E0AF89307),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-40.png
  Hash256(0x623820FA45CDB0AC, 0x808403E34AD6A53E, 0xA3E9FDAE83EE0931, 0xB020A3A4EF2CDDE7),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-58.png
  Hash256(0xC6D631D1E107215E, 0xD4A58FEC5F3AA4B5, 0x0AE9724E07114C0C, 0x453E5D87C2CAD3B3),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-60.png
  Hash256(0x4B6F58D1EB8723C6, 0xE717A0D09FEC8806, 0x90C6D1EF4F71836E, 0x618672827979B1A2),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-76.png
  Hash256(0x0A1744CC7634D508, 0xE85DD793331F0C8A, 0x0B7C6DDFE0975D8F, 0x29E91C905BBB1BED),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-80.png
  Hash256(0x24032FBD1E6519D6, 0x0BA93C0D5C189554, 0xF50EAE23756518A2, 0x3FABACF4BD5DAF08),

  // examples/flutter_gallery/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-87.png
  Hash256(0xC17BAE6DF6BB234A, 0xE0AF4BEB0B805F12, 0x14E74EB7AA9A30F1, 0x5763689165DA7DDF),


  // STOCKS ICONS

  // examples/stocks/android/app/src/main/res/mipmap-hdpi/ic_launcher.png
  Hash256(0x74052AB5241D4418, 0x7085180608BC3114, 0xD12493C50CD8BBC7, 0x56DED186C37ACE84),

  // examples/stocks/android/app/src/main/res/mipmap-mdpi/ic_launcher.png
  Hash256(0xE37947332E3491CB, 0x82920EE86A086FEA, 0xE1E0A70B3700A7DA, 0xDCAFBDD8F40E2E19),

  // examples/stocks/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png
  Hash256(0xE608CDFC0C8579FB, 0xE38873BAAF7BC944, 0x9C9D2EE3685A4FAE, 0x671EF0C8BC41D17C),

  // examples/stocks/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png
  Hash256(0xBD53D86977DF9C54, 0xF605743C5ABA114C, 0x9D51D1A8BB917E1A, 0x14CAA26C335CAEBD),

  // examples/stocks/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png
  Hash256(0x64E4D02262C4F3D0, 0xBB4FDC21CD0A816C, 0x4CD2A0194E00FB0F, 0x1C3AE4142FAC0D15),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-60@2x.png
  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-Small-40@3x.png
  Hash256(0x5BA3283A76918FC0, 0xEE127D0F22D7A0B6, 0xDF03DAED61669427, 0x93D89DDD87A08117),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-60@3x.png
  Hash256(0xCD7F26ED31DEA42A, 0x535D155EC6261499, 0x34E6738255FDB2C4, 0xBD8D4BDDE9A99B05),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-76.png
  Hash256(0x3FA1225FC9A96A7E, 0xCD071BC42881AB0E, 0x7747EB72FFB72459, 0xA37971BBAD27EE24),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-76@2x.png
  Hash256(0xCD867001ACD7BBDB, 0x25CDFD452AE89FA2, 0x8C2DC980CAF55F48, 0x0B16C246CFB389BC),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-83.5@2x.png
  Hash256(0x848E9736E5C4915A, 0x7945BCF6B32FD56B, 0x1F1E7CDDD914352E, 0xC9681D38EF2A70DA),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-Notification.png
  Hash256(0x654BA7D6C4E05CA0, 0x7799878884EF8F11, 0xA383E1F24CEF5568, 0x3C47604A966983C8),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-Notification@2x.png
  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-Small-40.png
  Hash256(0x743056FE7D83FE42, 0xA2990825B6AD0415, 0x1AF73D0D43B227AA, 0x07EBEA9B767381D9),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-Notification@3x.png
  Hash256(0xA7E1570812D119CF, 0xEF4B602EF28DD0A4, 0x100D066E66F5B9B9, 0x881765DC9303343B),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-Small-40@2x.png
  Hash256(0xB4102839A1E41671, 0x62DACBDEFA471953, 0xB1EE89A0AB7594BE, 0x1D9AC1E67DC2B2CE),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-Small.png
  Hash256(0x70AC6571B593A967, 0xF1CBAEC9BC02D02D, 0x93AD766D8290ADE6, 0x840139BF9F219019),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-Small@2x.png
  Hash256(0x5D87A78386DA2C43, 0xDDA8FEF2CA51438C, 0xE5A276FE28C6CF0A, 0xEBE89085B56665B6),

  // examples/stocks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-Small@3x.png
  Hash256(0x4D9F5E81F668DA44, 0xB20A77F8BF7BA2E1, 0xF384533B5AD58F07, 0xB3A2F93F8635CD96),


  // LEGACY ICONS

  // dev/benchmarks/complex_layout/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@3x.png
  // dev/benchmarks/microbenchmarks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@3x.png
  // examples/flutter_view/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@3x.png
  // (not really sure where this came from, or why neither the template nor most examples use them)
  Hash256(0x6E645DC9ED913AAD, 0xB50ED29EEB16830D, 0xB32CA12F39121DB9, 0xB7BC1449DDDBF8B8),

  // dev/benchmarks/macrobenchmarks/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png
  // dev/integration_tests/codegen/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png
  // dev/integration_tests/ios_add2app/ios_add2app/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png
  // dev/integration_tests/release_smoke_test/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png
  Hash256(0xDEFAC77E08EC71EC, 0xA04CCA3C95D1FC33, 0xB9F26E1CB15CB051, 0x47DEFC79CDD7C158),

  // examples/flutter_view/ios/Runner/ic_add.png
  // examples/platform_view/ios/Runner/ic_add.png
  Hash256(0x3CCE7450334675E2, 0xE3AABCA20B028993, 0x127BE82FE0EB3DFF, 0x8B027B3BAF052F2F),

  // examples/image_list/images/coast.jpg
  Hash256(0xDA957FD30C51B8D2, 0x7D74C2C918692DC4, 0xD3C5C99BB00F0D6B, 0x5EBB30395A6EDE82),

  // examples/image_list/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png
  Hash256(0xB5792CA06F48A431, 0xD4379ABA2160BD5D, 0xE92339FC64C6A0D3, 0x417AA359634CD905),


  // TEST ASSETS

  // dev/benchmarks/macrobenchmarks/assets/999x1000.png
  Hash256(0x553E9C36DFF3E610, 0x6A608BDE822A0019, 0xDE4F1769B6FBDB97, 0xBC3C20E26B839F59),

  // dev/bots/test/analyze-test-input/root/packages/foo/serviceaccount.enc
  Hash256(0xA8100AE6AA1940D0, 0xB663BB31CD466142, 0xEBBDBD5187131B92, 0xD93818987832EB89),

  // dev/automated_tests/icon/test.png
  Hash256(0xE214B4A0FEEEC6FA, 0x8E7AA8CC9BFBEC40, 0xBCDAC2F2DEBC950F, 0x75AF8EBF02BCE459),

  // dev/integration_tests/android_splash_screens/splash_screen_kitchen_sink/android/app/src/main/res/drawable-land-xxhdpi/flutter_splash_screen.png
  // dev/integration_tests/android_splash_screens/splash_screen_kitchen_sink/android/app/src/main/res/mipmap-land-xxhdpi/flutter_splash_screen.png
  Hash256(0x2D4F8D7A3DFEF9D3, 0xA0C66938E169AB58, 0x8C6BBBBD1973E34E, 0x03C428416D010182),

  // dev/integration_tests/android_splash_screens/splash_screen_kitchen_sink/android/app/src/main/res/drawable-xxhdpi/flutter_splash_screen.png
  // dev/integration_tests/android_splash_screens/splash_screen_kitchen_sink/android/app/src/main/res/mipmap-xxhdpi/flutter_splash_screen.png
  Hash256(0xCD46C01BAFA3B243, 0xA6AA1645EEDDE481, 0x143AC8ABAB1A0996, 0x22CAA9D41F74649A),

  // dev/integration_tests/flutter_driver_screenshot_test/assets/red_square.png
  Hash256(0x40054377E1E084F4, 0x4F4410CE8F44C210, 0xABA945DFC55ED0EF, 0x23BDF9469E32F8D3),

  // dev/integration_tests/flutter_driver_screenshot_test/test_driver/goldens/red_square_image/iPhone7,2.png
  Hash256(0x7F9D27C7BC418284, 0x01214E21CA886B2F, 0x40D9DA2B31AE7754, 0x71D68375F9C8A824),

  // examples/flutter_view/assets/flutter-mark-square-64.png
  // examples/platform_view/assets/flutter-mark-square-64.png
  Hash256(0xF416B0D8AC552EC8, 0x819D1F492D1AB5E6, 0xD4F20CF45DB47C22, 0x7BB431FEFB5B67B2),

  // packages/flutter_tools/test/data/intellij/plugins/Dart/lib/Dart.jar
  Hash256(0x576E489D788A13DB, 0xBF40E4A39A3DAB37, 0x15CCF0002032E79C, 0xD260C69B29E06646),

  // packages/flutter_tools/test/data/intellij/plugins/flutter-intellij.jar
  Hash256(0x4C67221E25626CB2, 0x3F94E1F49D34E4CF, 0x3A9787A514924FC5, 0x9EF1E143E5BC5690),


  // HISTORICAL DEVICE LAB IMAGES

  // dev/devicelab/images/agent-statuses.png
  Hash256(0x0A43016C84095771, 0x1C610E1C01B1C3B2, 0x681DA0B2062C02AA, 0x31CC7FB3FDC298FD),

  // dev/devicelab/images/broken-test.png
  Hash256(0x319459F42967A888, 0x90B20063544D6707, 0x849E1E3447CC56A5, 0xE226C47DE34F13AD),

  // dev/devicelab/images/legend.png
  Hash256(0x92A98975AF5F076C, 0xE7BFAB86B0DD7A3D, 0xC45287B706D10456, 0x4E512BA3C41B2749),


  // MISCELLANEOUS

  // dev/bots/serviceaccount.enc
  Hash256(0x1F19ADB4D80AFE8C, 0xE61899BA776B1A8D, 0xCA398C75F5F7050D, 0xFB0E72D7FBBBA69B),

  // dev/docs/favicon.ico
  Hash256(0x67368CA1733E933A, 0xCA3BC56EF0695012, 0xE862C371AD4412F0, 0x3EC396039C609965),

  // dev/snippets/assets/code_sample.png
  Hash256(0xAB2211A47BDA001D, 0x173A52FD9C75EBC7, 0xE158942FFA8243AD, 0x2A148871990D4297),

  // dev/snippets/assets/code_snippet.png
  Hash256(0xDEC70574DA46DFBB, 0xFA657A771F3E1FBD, 0xB265CFC6B2AA5FE3, 0x93BA4F325D1520BA),

  // packages/flutter_tools/static/Ahem.ttf
  Hash256(0x63D2ABD0041C3E3B, 0x4B52AD8D382353B5, 0x3C51C6785E76CE56, 0xED9DACAD2D2E31C4),
};

Future<void> verifyNoBinaries(String workingDirectory, { Set<Hash256> grandfatheredBinaries }) async {
  // Please do not add anything to the _grandfatheredBinaries set above.
  // We have a policy of not checking in binaries into this repository.
  // If you have binaries to add, please consult Hixie for advice.
  assert(
    _grandfatheredBinaries
      .expand<int>((Hash256 hash) => <int>[hash.a, hash.b, hash.c, hash.d])
      .reduce((int value, int element) => value ^ element) == 0xBFC18DE113B5AE8E // Please do not modify this line.
  );
  grandfatheredBinaries ??= _grandfatheredBinaries;
  if (!Platform.isWindows) { // TODO(ianh): Port this to Windows
    final EvalResult evalResult = await _evalCommand(
      'git', <String>['ls-files', '-z'],
      workingDirectory: workingDirectory,
    );
    if (evalResult.exitCode != 0) {
      exitWithError(<String>[
        'git ls-filese failed with exit code ${evalResult.exitCode}',
        '${bold}stdout:$reset',
        evalResult.stdout,
        '${bold}stderr:$reset',
        evalResult.stderr,
      ]);
    }
    final List<String> filenames = evalResult
      .stdout
      .split('\x00');
    assert(filenames.last.isEmpty); // git ls-files gives a trailing blank 0x00
    filenames.removeLast();
    final List<File> files = filenames
      .map<File>((String filename) => File(path.join(workingDirectory, filename)))
      .toList();
    final List<String> problems = <String>[];
    for (final File file in files) {
      final Uint8List bytes = file.readAsBytesSync();
      try {
        utf8.decode(bytes);
      } on FormatException catch (error) {
        if (error.message.startsWith('Bad UTF-8 encoding ')) {
          final Digest digest = sha256.convert(bytes);
          if (!grandfatheredBinaries.contains(Hash256.fromDigest(digest)))
            problems.add('${file.path}:${error.offset}: file is not valid UTF-8');
        } else {
          rethrow;
        }
      }
    }
    if (problems.isNotEmpty) {
      exitWithError(<String>[
        ...problems,
        'All files in this repository must be UTF-8. In particular, images and other binaries',
        'must not be checked into this repository. This is because we are very sensitive to the',
        'size of the repository as it is distributed to all our developers. If you have a binary',
        'to which you need access, you should consider how to fetch it from another repository;',
        'for example, the "assets-for-api-docs" repository is used for images in API docs.',
      ]);
    }
  }
}


// UTILITY FUNCTIONS

bool _listEquals<T>(List<T> a, List<T> b) {
  assert(a != null);
  assert(b != null);
  if (a.length != b.length)
    return false;
  for (int index = 0; index < a.length; index += 1) {
    if (a[index] != b[index])
      return false;
  }
  return true;
}

Iterable<File> _allFiles(String workingDirectory, String extension, { @required int minimumMatches }) sync* {
  assert(extension == null || !extension.startsWith('.'), 'Extension argument should not start with a period.');
  final Set<FileSystemEntity> pending = <FileSystemEntity>{ Directory(workingDirectory) };
  int matches = 0;
  while (pending.isNotEmpty) {
    final FileSystemEntity entity = pending.first;
    pending.remove(entity);
    if (path.extension(entity.path) == '.tmpl')
      continue;
    if (entity is File) {
      if (_isGeneratedPluginRegistrant(entity))
        continue;
      if (path.basename(entity.path) == 'flutter_export_environment.sh')
        continue;
      if (path.basename(entity.path) == 'gradlew.bat')
        continue;
      if (extension == null || path.extension(entity.path) == '.$extension') {
        matches += 1;
        yield entity;
      }
    } else if (entity is Directory) {
      if (File(path.join(entity.path, '.dartignore')).existsSync())
        continue;
      if (path.basename(entity.path) == '.git')
        continue;
      if (path.basename(entity.path) == '.gradle')
        continue;
      if (path.basename(entity.path) == '.dart_tool')
        continue;
      if (path.basename(entity.path) == 'build')
        continue;
      pending.addAll(entity.listSync());
    }
  }
  assert(matches >= minimumMatches, 'Expected to find at least $minimumMatches files with extension ".$extension" in "$workingDirectory", but only found $matches.');
}

class EvalResult {
  EvalResult({
    this.stdout,
    this.stderr,
    this.exitCode = 0,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
}

// TODO(ianh): Refactor this to reuse the code in run_command.dart
Future<EvalResult> _evalCommand(String executable, List<String> arguments, {
  @required String workingDirectory,
  Map<String, String> environment,
  bool skip = false,
  bool allowNonZeroExit = false,
}) async {
  final String commandDescription = '${path.relative(executable, from: workingDirectory)} ${arguments.join(' ')}';
  final String relativeWorkingDir = path.relative(workingDirectory);
  if (skip) {
    printProgress('SKIPPING', relativeWorkingDir, commandDescription);
    return null;
  }
  printProgress('RUNNING', relativeWorkingDir, commandDescription);

  final Stopwatch time = Stopwatch()..start();
  final Process process = await Process.start(executable, arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  final Future<List<List<int>>> savedStdout = process.stdout.toList();
  final Future<List<List<int>>> savedStderr = process.stderr.toList();
  final int exitCode = await process.exitCode;
  final EvalResult result = EvalResult(
    stdout: utf8.decode((await savedStdout).expand<int>((List<int> ints) => ints).toList()),
    stderr: utf8.decode((await savedStderr).expand<int>((List<int> ints) => ints).toList()),
    exitCode: exitCode,
  );

  print('$clock ELAPSED TIME: $bold${prettyPrintDuration(time.elapsed)}$reset for $commandDescription in $relativeWorkingDir');

  if (exitCode != 0 && !allowNonZeroExit) {
    stderr.write(result.stderr);
    exitWithError(<String>[
      '${bold}ERROR:$red Last command exited with $exitCode.$reset',
      '${bold}Command:$red $commandDescription$reset',
      '${bold}Relative working directory:$red $relativeWorkingDir$reset',
    ]);
  }

  return result;
}

Future<void> _runFlutterAnalyze(String workingDirectory, {
  List<String> options = const <String>[],
}) async {
  return await runCommand(
    flutter,
    <String>['analyze', '--dartdocs', ...options],
    workingDirectory: workingDirectory,
  );
}

final RegExp _importPattern = RegExp(r'''^\s*import (['"])package:flutter/([^.]+)\.dart\1''');
final RegExp _importMetaPattern = RegExp(r'''^\s*import (['"])package:meta/meta\.dart\1''');

Set<String> _findFlutterDependencies(String srcPath, List<String> errors, { bool checkForMeta = false }) {
  return _allFiles(srcPath, 'dart', minimumMatches: 1)
    .map<Set<String>>((File file) {
      final Set<String> result = <String>{};
      for (final String line in file.readAsLinesSync()) {
        Match match = _importPattern.firstMatch(line);
        if (match != null)
          result.add(match.group(2));
        if (checkForMeta) {
          match = _importMetaPattern.firstMatch(line);
          if (match != null) {
            errors.add(
              '${file.path}\nThis package imports the ${yellow}meta$reset package.\n'
              'You should instead import the "foundation.dart" library.'
            );
          }
        }
      }
      return result;
    })
    .reduce((Set<String> value, Set<String> element) {
      value ??= <String>{};
      value.addAll(element);
      return value;
    });
}

List<T> _deepSearch<T>(Map<T, Set<T>> map, T start, [ Set<T> seen ]) {
  if (map[start] == null)
    return null; // We catch these separately.

  for (final T key in map[start]) {
    if (key == start)
      continue; // we catch these separately
    if (seen != null && seen.contains(key))
      return <T>[start, key];
    final List<T> result = _deepSearch<T>(
      map,
      key,
      <T>{
        if (seen == null) start else ...seen,
        key,
      },
    );
    if (result != null) {
      result.insert(0, start);
      // Only report the shortest chains.
      // For example a->b->a, rather than c->a->b->a.
      // Since we visit every node, we know the shortest chains are those
      // that start and end on the loop.
      if (result.first == result.last)
        return result;
    }
  }
  return null;
}

String _getPackageFor(File entity, Directory flutterRootDir) {
  for (Directory dir = entity.parent; dir != flutterRootDir; dir = dir.parent) {
    if (File(path.join(dir.path, 'pubspec.yaml')).existsSync()) {
      return dir.path;
    }
  }
  throw ArgumentError('$entity is not within a dart package.');
}

bool _isGeneratedPluginRegistrant(File file) {
  final String filename = path.basename(file.path);
  return !file.path.contains('.pub-cache')
      && (filename == 'GeneratedPluginRegistrant.java' ||
          filename == 'GeneratedPluginRegistrant.h' ||
          filename == 'GeneratedPluginRegistrant.m');
}
