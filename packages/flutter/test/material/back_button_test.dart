// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('BackButton control test', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Material(child: Text('Home')),
        routes: <String, WidgetBuilder>{
          '/next': (BuildContext context) {
            return const Material(
              child: Center(
                child: BackButton(),
              ),
            );
          },
        },
      ),
    );

    tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/next');

    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));

    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('BackButton onPressed overrides default pop behavior', (WidgetTester tester) async {
    bool backPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: const Material(child: Text('Home')),
        routes: <String, WidgetBuilder>{
          '/next': (BuildContext context) {
            return Material(
              child: Center(
                child: BackButton(onPressed: () => backPressed = true),
              ),
            );
          },
        },
      ),
    );

    tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/next');

    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));

    await tester.pumpAndSettle();

    // We're still on the second page.
    expect(find.text('Home'), findsNothing);
    // But the custom callback is called.
    expect(backPressed, true);
  });

  testWidgets('BackButton icon', (WidgetTester tester) async {
    final Key androidKey = UniqueKey();
    final Key iOSKey = UniqueKey();
    final Key macOSKey = UniqueKey();

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            Theme(
              data: ThemeData(platform: TargetPlatform.android),
              child: BackButtonIcon(key: androidKey),
            ),
            Theme(
              data: ThemeData(platform: TargetPlatform.iOS),
              child: BackButtonIcon(key: iOSKey),
            ),
            Theme(
              data: ThemeData(platform: TargetPlatform.macOS),
              child: BackButtonIcon(key: macOSKey),
            ),
          ],
        ),
      ),
    );

    final Icon androidIcon = tester.widget(find.descendant(of: find.byKey(androidKey), matching: find.byType(Icon)));
    final Icon iOSIcon = tester.widget(find.descendant(of: find.byKey(iOSKey), matching: find.byType(Icon)));
    final Icon macOSIcon = tester.widget(find.descendant(of: find.byKey(macOSKey), matching: find.byType(Icon)));
    expect(iOSIcon.icon == androidIcon.icon, isFalse);
    expect(macOSIcon.icon == androidIcon.icon, isFalse);
    expect(macOSIcon.icon == iOSIcon.icon, isTrue);
  });

  testWidgets('BackButton color', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(
          child: BackButton(
            color: Colors.blue,
          ),
        ),
      ),
    );

    final RichText iconText = tester.firstWidget(find.descendant(
        of: find.byType(BackButton),
        matching: find.byType(RichText)
    ));
    expect(iconText.text.style.color, Colors.blue);
  });

  testWidgets('BackButton semantics', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: const Material(child: Text('Home')),
        routes: <String, WidgetBuilder>{
          '/next': (BuildContext context) {
            return const Material(
              child: Center(
                child: BackButton(),
              ),
            );
          },
        },
      ),
    );

    tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/next');

    await tester.pumpAndSettle();

    expect(tester.getSemantics(find.byType(BackButton)), matchesSemantics(
      label: 'Back',
      isButton: true,
      hasEnabledState: true,
      isEnabled: true,
      hasTapAction: true,
      isFocusable: true,
    ));
    handle.dispose();
  });

  testWidgets('CloseButton color', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(
          child: CloseButton(
            color: Colors.red,
          ),
        ),
      ),
    );

    final RichText iconText = tester.firstWidget(find.descendant(
        of: find.byType(CloseButton),
        matching: find.byType(RichText)
    ));
    expect(iconText.text.style.color, Colors.red);
  });
}
