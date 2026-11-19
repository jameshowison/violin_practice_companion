import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/keep_awake.dart';

void main() {
  final calls = <bool>[];
  const almost = Duration(minutes: 4, seconds: 59);
  const tick = Duration(seconds: 2);

  setUp(() {
    KeepAwake.reset();
    calls.clear();
    KeepAwake.platform = (on) async => calls.add(on);
  });
  tearDown(KeepAwake.reset);

  testWidgets('sleeps five minutes after the last touch, wakes on the next',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    KeepAwake.enable();
    expect(KeepAwake.isLocked, isTrue);

    await tester.pump(almost);
    await tester.tapAt(const Offset(10, 10)); // restarts the countdown
    await tester.pump(almost);
    expect(KeepAwake.isLocked, isTrue);
    await tester.pump(tick);
    expect(KeepAwake.isLocked, isFalse);

    await tester.tapAt(const Offset(10, 10));
    expect(KeepAwake.isLocked, isTrue);
    expect(calls, [true, false, true]);

    KeepAwake.disable();
    expect(KeepAwake.isLocked, isFalse);
  });

  testWidgets('never sleeps while playing; countdown restarts when it stops',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    KeepAwake.enable();
    KeepAwake.busy = true;
    await tester.pump(const Duration(minutes: 20));
    expect(KeepAwake.isLocked, isTrue);

    KeepAwake.busy = false;
    await tester.pump(almost);
    expect(KeepAwake.isLocked, isTrue);
    await tester.pump(tick);
    expect(KeepAwake.isLocked, isFalse);
    KeepAwake.disable();
  });

  testWidgets('holders are counted: an inner screen leaving keeps the lock',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    KeepAwake.enable(); // piece
    KeepAwake.enable(); // tuner over it
    KeepAwake.disable(); // tuner popped
    expect(KeepAwake.isLocked, isTrue);
    KeepAwake.disable();
    expect(KeepAwake.isLocked, isFalse);
    KeepAwake.disable(); // extra disable is harmless
    expect(calls, [true, false]);
  });
}
