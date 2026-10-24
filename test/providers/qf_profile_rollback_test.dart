import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:flutter_test/flutter_test.dart';

// G-2/G-5 helpers: a profile the core cannot build must not stay current,
// and a share-link subscription file must be recognised as converted
// content rather than as a YAML config.
void main() {
  group('qfRollbackCandidate', () {
    final a = Profile.normal(label: 'a');
    final b = Profile.normal(label: 'b');
    final c = Profile.normal(label: 'c');
    final profiles = [a, b, c];

    test('skips the failed profile and picks the next one', () {
      expect(qfRollbackCandidate(profiles, {a.id})?.id, b.id);
    });

    test('skips every profile that already failed this session', () {
      expect(qfRollbackCandidate(profiles, {a.id, b.id})?.id, c.id);
    });

    test('returns null when nothing usable is left', () {
      expect(qfRollbackCandidate(profiles, {a.id, b.id, c.id}), isNull);
      expect(qfRollbackCandidate(const [], <int>{}), isNull);
    });
  });

  group('qfIsLinkListContent', () {
    test('a YAML mapping is a native config', () {
      expect(
        qfIsLinkListContent('proxies:\n  - {name: a, type: ss}\n'),
        isFalse,
      );
    });

    test('a plain share-link list is converted content', () {
      expect(
        qfIsLinkListContent(
          'ss://YWVzLTI1Ni1nY206cGFzcw@192.0.2.1:8388#node-a\n'
          'trojan://password@192.0.2.2:443#node-b\n',
        ),
        isTrue,
      );
    });

    test('a base64-wrapped body is converted content', () {
      // base64 of a one-line share-link list, as panels deliver it.
      expect(
        qfIsLinkListContent(
          'c3M6Ly9ZV1Z6TFRFeU9DMW5ZMjA2Y0dGemMzZHZjbVE9QDE5Mi4wLjIuMTo4Mzg4I25vZGUtYQo=',
        ),
        isTrue,
      );
    });
  });
}
