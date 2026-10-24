import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// The download content guard: an empty body or a web page from the
// subscription endpoint must be refused before it can replace a good
// saved profile; real configs pass untouched.
void main() {
  Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

  group('qfSubscriptionContentIssue', () {
    test('empty body is refused', () {
      expect(qfSubscriptionContentIssue(Uint8List(0)), contains('没有返回内容'));
    });

    test('an HTML page is refused, even with BOM and leading blanks', () {
      expect(
        qfSubscriptionContentIssue(
          bytesOf('﻿ \n<!DOCTYPE html><html><body>login</body></html>'),
        ),
        contains('网页内容'),
      );
      expect(
        qfSubscriptionContentIssue(bytesOf('<html>blocked</html>')),
        contains('网页内容'),
      );
    });

    test('YAML configs, link lists and base64 bodies pass', () {
      expect(
        qfSubscriptionContentIssue(bytesOf('proxies:\n  - {name: a}\n')),
        isNull,
      );
      expect(
        qfSubscriptionContentIssue(
          bytesOf('ss://YWVzLTI1Ni1nY206cGFzcw@192.0.2.1:8388#node-a\n'),
        ),
        isNull,
      );
      expect(
        qfSubscriptionContentIssue(bytesOf('c3M6Ly9ZV1Z6TFRFeU9DMW5h')),
        isNull,
      );
      expect(qfSubscriptionContentIssue(bytesOf('  \nport: 7890\n')), isNull);
    });
  });
}
