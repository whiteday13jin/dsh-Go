// #316: a new chat has no session id until its first message, so
// `skills/list` and `commands/list` have nothing to read and the slash palette
// showed no skills. It borrows the newest real conversation's catalog instead.

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/commands_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// One host per test: the providers cache their last catalog per host, so a
/// shared host would leak rows between tests.
const _borrowHost = HostRef.ssh('new-chat-borrow-host');
const _openHost = HostRef.ssh('open-chat-host');
const _failedHost = HostRef.ssh('new-chat-failed-host');

const _donorId = 'donor-conversation';
const _olderId = 'older-conversation';
const _openId = 'open-conversation';

final _t0 = DateTime.utc(2026, 3, 1, 9);

SessionSummary _session(String id, {required DateTime updatedAt, bool blank = false, bool subagent = false}) =>
    SessionSummary(
      sessionId: id,
      updatedAt: updatedAt,
      running: false,
      blank: blank,
      agentAvailable: true,
      origin: subagent ? 'subagent' : null,
    );

/// Answers `commands/list` and `skills/list` from fields and records the
/// session ids it was asked for.
class _ScriptedCarrier extends DshCarrier {
  final calls = <(String, Map<String, Object?>)>[];
  List<Map<String, Object?>> commands = const [];
  List<Map<String, Object?>> skills = const [];
  bool failSkills = false;

  @override
  String get kind => 'test';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    switch (endpoint) {
      case 'commands/list':
        return RpcOk(commands);
      case 'skills/list':
        if (failSkills) return const RpcError(DshRemoteException('gateway/not-found', 'controlled failure'));
        return RpcOk({'skills': skills});
    }
    return RpcError(DshRemoteException('gateway/not-found', 'unexpected $endpoint'));
  }

  List<String?> get commandAgentIds => [
    for (final (endpoint, args) in calls)
      if (endpoint == 'commands/list') args['agentId'] as String?,
  ];

  List<String?> get skillSessionIds => [
    for (final (endpoint, args) in calls)
      if (endpoint == 'skills/list') ((args['request'] as Map)['sessionId']) as String?,
  ];

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams in this test');

  @override
  Future<void> close() async {}
}

class _Client extends DshClient {
  _Client(this.script) : super.withCarrier(script);

  final _ScriptedCarrier script;

  /// The palette only subscribes to refresh events; no mux in these tests.
  @override
  Stream<HostEvent> get hostEvents => const Stream.empty();
}

class _FakeActiveHost extends ActiveHostController {
  _FakeActiveHost(this.host);

  final HostRef host;

  @override
  HostRef build() => host;
}

ProviderContainer _container(_ScriptedCarrier script, HostRef host, Map<String, SessionSummary> sessions) {
  final container = ProviderContainer(
    // One failed read is the state under test; the app's automatic retry
    // would keep a failed `skills/list` pending for tens of seconds.
    retry: (_, _) => null,
    overrides: [
      activeHostProvider.overrideWith(() => _FakeActiveHost(host)),
      activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: _Client(script), isLocal: false))),
      hostSessionsProvider.overrideWithValue(sessions),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('newChatCatalogDonor', () {
    test('picks the most recently updated conversation', () {
      expect(
        newChatCatalogDonor([
          _session(_olderId, updatedAt: _t0),
          _session(_donorId, updatedAt: _t0.add(const Duration(hours: 2))),
        ]),
        _donorId,
      );
    });

    test('skips subagent children and conversations without a turn', () {
      expect(
        newChatCatalogDonor([
          _session('newest-but-blank', updatedAt: _t0.add(const Duration(hours: 3)), blank: true),
          _session('newest-but-subagent', updatedAt: _t0.add(const Duration(hours: 2)), subagent: true),
          _session(_donorId, updatedAt: _t0),
        ]),
        _donorId,
      );
    });

    test('returns null when the host has no usable conversation', () {
      expect(newChatCatalogDonor(const []), isNull);
      expect(newChatCatalogDonor([_session('blank', updatedAt: _t0, blank: true)]), isNull);
    });
  });

  test('a new chat borrows the newest conversation commands and skills', () async {
    final script = _ScriptedCarrier()
      ..skills = [
        {'name': 'wiki', 'description': 'the team wiki'},
      ]
      ..commands = [
        {'name': 'deploy', 'description': 'ship it'},
      ];
    final container = _container(script, _borrowHost, {
      _donorId: _session(_donorId, updatedAt: _t0.add(const Duration(hours: 2))),
      _olderId: _session(_olderId, updatedAt: _t0),
    });
    final keep = container.listen(slashCommandsProvider(null), (_, _) {});
    addTearDown(keep.close);

    await container.read(skillsProvider(_donorId).future);
    await container.read(hostCommandsProvider(null).future);

    expect(container.read(newChatCatalogDonorProvider), _donorId);
    expect(container.read(skillCommandsProvider(null)).map((c) => c.name), ['wiki']);
    expect(container.read(slashCommandsProvider(null)).map((c) => c.name), containsAll(['new', 'wiki', 'deploy']));
    expect(container.read(newChatCatalogNoticeProvider), NewChatCatalogNotice.borrowed);
    // The Host was asked about the borrowed conversation, not about nothing.
    expect(script.skillSessionIds, contains(_donorId));
    expect(script.commandAgentIds, contains(_donorId));
  });

  test('an open conversation still reads its own catalog', () async {
    final script = _ScriptedCarrier()
      ..skills = [
        {'name': 'wiki', 'description': 'the team wiki'},
      ];
    final container = _container(script, _openHost, {
      _donorId: _session(_donorId, updatedAt: _t0.add(const Duration(hours: 2))),
      _openId: _session(_openId, updatedAt: _t0),
    });
    final keep = container.listen(slashCommandsProvider(_openId), (_, _) {});
    addTearDown(keep.close);

    await container.read(skillsProvider(_openId).future);
    await container.read(hostCommandsProvider(_openId).future);

    expect(container.read(skillCommandsProvider(_openId)).map((c) => c.name), ['wiki']);
    expect(script.skillSessionIds, [_openId]);
    expect(script.commandAgentIds, [_openId]);
  });

  test('a failed borrowed catalog offers a retry and does not break the palette', () async {
    final script = _ScriptedCarrier()..failSkills = true;
    final container = _container(script, _failedHost, {_donorId: _session(_donorId, updatedAt: _t0)});
    final keep = container.listen(skillCommandsProvider(null), (_, _) {});
    addTearDown(keep.close);

    await expectLater(container.read(skillsProvider(_donorId).future), throwsA(isA<DshRemoteException>()));

    expect(container.read(skillCommandsProvider(null)), isEmpty);
    expect(container.read(newChatCatalogNoticeProvider), NewChatCatalogNotice.retry);
  });
}
