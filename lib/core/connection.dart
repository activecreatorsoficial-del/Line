import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'transfer.dart';
import 'local_room_server.dart';
import 'room_invitation.dart';
import 'host_connector.dart';
import 'android_session.dart';
import 'router_access.dart';
import 'internet_route.dart';
import 'exchange_invite.dart';

import 'dart:math';

enum LinkPhase { idle, connecting, waiting, negotiating, connected, error }

class LineSettings {
  LineSettings({
    this.listenPort = 8790,
    this.publicAddress = '',
    this.stun = '',
    this.turn = '',
    this.turnUser = '',
    this.turnPassword = '',
    this.internetHosting = false,
  });
  int listenPort;
  String publicAddress;
  String stun;
  String turn;
  String turnUser;
  String turnPassword;
  bool internetHosting;

  String? validate() {
    if (internetHosting && (stun.isNotEmpty || turn.isNotEmpty)) {
      return 'Internet invitations use built-in free STUN with no relay. Clear these custom settings or use Nearby.';
    }
    if (listenPort < 1024 || listenPort > 65535) {
      return 'Choose a listening port from 1024 to 65535.';
    }
    try {
      if (!internetHosting) {
        RoomInvitation.publicEndpoint(publicAddress, listenPort);
      }
    } on FormatException catch (e) {
      return e.message.toString();
    }
    if (stun.isNotEmpty && !stun.startsWith('stun:')) {
      return 'The STUN address must start with stun:.';
    }
    if (turn.isNotEmpty &&
        (!RegExp(r'^turns?:').hasMatch(turn) ||
            turnUser.isEmpty ||
            turnPassword.isEmpty)) {
      return 'Enter the TURN address, username and password.';
    }
    return null;
  }
}

class _RtcWire implements TransferWire {
  _RtcWire(this.channel) {
    channel.onMessage = (message) => _messages.add(
      message.isBinary
          ? WireMessage.binary(message.binary)
          : WireMessage.text(message.text),
    );
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed &&
          !_messages.isClosed) {
        _messages.close();
      }
    };
  }
  final RTCDataChannel channel;
  final _messages = StreamController<WireMessage>();
  @override
  Stream<WireMessage> get messages => _messages.stream;
  @override
  Future<void> send(WireMessage message) async {
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Connection closed.');
    }
    await channel.send(
      message.bytes == null
          ? RTCDataChannelMessage(message.text!)
          : RTCDataChannelMessage.fromBinary(message.bytes!),
    );
  }

  Future<void> close() async {
    await channel.close();
    if (!_messages.isClosed) await _messages.close();
  }
}

class LineConnection extends ChangeNotifier {
  static const Map<String, dynamic> _dataOnly = {
    'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
    'optional': <dynamic>[],
  };
  LineConnection({
    Future<RouterRoute> Function()? discoverRouter,
    Future<bool> Function()? receiverHasIpv6,
  }) : _discoverRouter = discoverRouter ?? discoverInternetRoute,
       _receiverHasIpv6 = receiverHasIpv6 ?? hasUsableIpv6;
  final Future<RouterRoute> Function() _discoverRouter;
  final Future<bool> Function() _receiverHasIpv6;
  bool _ipv6Only = false;
  bool get usesIpv6 => _ipv6Only;
  int localIpv6Candidates = 0;
  RouterRoute? _router;
  Uri? internetEndpoint;
  int _routerCandidatesPending = 0;
  int mappedUdpCandidates = 0;
  bool get _inactive => _closing || phase == LinkPhase.error;
  LinkPhase phase = LinkPhase.idle;
  String? error;
  String? room;
  String? invitation;
  List<Uri> hostedAddresses = const [];
  int? hostedPort;
  LocalRoomServer? _localServer;
  HttpClient? _httpClient;
  HostConnector? _connector;
  List<HostAttempt> connectionAttempts = const [];
  bool get isRoomServerRunning =>
      _localServer != null && !_localServer!.isClosed;
  String? code;
  DateTime? expires;
  String? safetyCode;
  TransferEngine? transfer;
  bool isSender = true;
  WebSocket? _socket;
  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  _RtcWire? _wire;
  Timer? _deadline;
  bool _gathered = false;
  bool _readySent = false;
  bool _remoteSet = false;
  bool _closing = false;
  Future<void>? _closeFuture;
  bool isExchange = false;
  bool processingResponse = false;
  int reflexiveCandidates = 0;
  int relayCandidates = 0;
  final _iceComplete = Completer<void>();
  ExchangeInvite? _exchangeOffer;
  final List<RTCIceCandidate> _candidates = [];
  Future<void> _signals = Future.value();
  List<TransferFile> _selected = [];

  Future<String> _gatherSdp() async {
    await _iceComplete.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {},
    );
    if (_inactive) throw StateError('Sharing cancelled.');
    final sdp = (await _peer!.getLocalDescription())?.sdp;
    if (sdp == null || !sdp.contains('a=candidate:')) {
      throw const FormatException(
        'No direct connection addresses were found. Check the network and create a new room.',
      );
    }
    validateExchangeSdp(sdp);
    return sdp;
  }

  void _expireExchange() {
    _deadline?.cancel();
    _deadline = Timer(expires!.difference(DateTime.now()), () {
      if (phase != LinkPhase.connected) {
        _fail('This invitation has expired. Create a new room.');
      }
    });
  }

  Future<void> _hostExchange(
    LineSettings settings,
    List<TransferFile> selected,
  ) async {
    isExchange = true;
    isSender = true;
    _selected = selected;
    phase = LinkPhase.connecting;
    notifyListeners();
    try {
      await AndroidSession.acquire(
        this,
        hosting: true,
        onStop: () => _fail('Sharing stopped from the Android notification.'),
      );
      if (_inactive) return;
      await _createPeer(settings, exchange: true);
      if (_inactive) return;
      _bindChannel(
        await _peer!.createDataChannel(
          'line-files-v1',
          RTCDataChannelInit()..ordered = true,
        ),
      );
      await _peer!.setLocalDescription(await _peer!.createOffer(_dataOnly));
      final offer = ExchangeInvite.offer(await _gatherSdp());
      _exchangeOffer = offer;
      room = offer.room;
      expires = offer.expires;
      final random = Random.secure();
      code = List.generate(12, (_) => random.nextInt(10)).join();
      invitation = await offer.encode(code!);
      if (_inactive) return;
      phase = LinkPhase.waiting;
      _expireExchange();
      notifyListeners();
    } on FormatException catch (e) {
      if (!_inactive) _fail(e.message.toString());
    } catch (_) {
      if (!_inactive) {
        _fail(
          'Unable to prepare the Internet invitation. Check the connection and try again.',
        );
      }
    }
  }

  Future<void> _joinExchange(
    LineSettings settings,
    String token,
    String password,
  ) async {
    isExchange = true;
    phase = LinkPhase.connecting;
    notifyListeners();
    final offer = await ExchangeInvite.decode(token, password.trim());
    if (offer.isAnswer) {
      throw const FormatException(
        'Open the sender invitation in Receive. Return responses to the sender.',
      );
    }
    if (_inactive) return;
    _exchangeOffer = offer;
    room = offer.room;
    expires = offer.expires;
    code = password.trim();
    try {
      await AndroidSession.acquire(
        this,
        hosting: false,
        onStop: () => _fail('Sharing stopped from the Android notification.'),
      );
      if (_inactive) return;
      await _createPeer(settings, exchange: true);
      if (_inactive) return;
      await _peer!.setRemoteDescription(
        RTCSessionDescription(offer.sdp, 'offer'),
      );
      _remoteSet = true;
      await _peer!.setLocalDescription(await _peer!.createAnswer(_dataOnly));
      invitation = await offer.answer(await _gatherSdp()).encode(code!);
      if (_inactive || phase == LinkPhase.connected) return;
      phase = LinkPhase.waiting;
      _expireExchange();
      notifyListeners();
    } on FormatException {
      rethrow;
    } catch (_) {
      if (!_inactive) {
        _fail(
          'Unable to prepare a response. Open a fresh sender invitation and try again.',
        );
      }
    }
  }

  Future<void> applyAnswer(String token) async {
    if (!isExchange ||
        !isSender ||
        _exchangeOffer == null ||
        _inactive ||
        processingResponse ||
        phase != LinkPhase.waiting) {
      throw const FormatException(
        'Create a new Internet room before opening a response.',
      );
    }
    processingResponse = true;
    notifyListeners();
    try {
      final answer = await ExchangeInvite.decode(token, code!);
      answer.checkAnswerFor(_exchangeOffer!);
      if (_inactive || phase != LinkPhase.waiting) return;
      _startNegotiation();
      await _peer!.setRemoteDescription(
        RTCSessionDescription(answer.sdp, 'answer'),
      );
      _remoteSet = true;
      await _updateSafetyCode();
    } on FormatException {
      rethrow;
    } catch (_) {
      if (!_inactive) {
        _fail(
          'This response could not establish a direct connection. Create a new room and exchange fresh invitations.',
        );
      }
    } finally {
      processingResponse = false;
      if (!_inactive) notifyListeners();
    }
  }

  Future<void> host(LineSettings settings, List<TransferFile> selected) =>
      settings.internetHosting
      ? _hostExchange(settings, selected)
      : hostDirect(settings, selected);

  Future<void> hostDirect(
    LineSettings settings,
    List<TransferFile> selected,
  ) async {
    _selected = selected;
    isSender = true;
    final invalid = settings.validate();
    if (invalid != null) {
      _fail(invalid);
      return;
    }
    phase = LinkPhase.connecting;
    error = null;
    notifyListeners();
    try {
      await AndroidSession.acquire(
        this,
        hosting: true,
        onStop: () => _fail('Sharing stopped from the Android notification.'),
      );
      if (_inactive) {
        await AndroidSession.release(this);
        return;
      }
      final host = await LocalRoomServer.start(port: settings.listenPort);
      if (_inactive) {
        await host.close();
        return;
      }
      _localServer = host;
      hostedPort = host.port;
      if (!settings.internetHosting &&
          settings.publicAddress.isNotEmpty &&
          host.port != settings.listenPort) {
        _fail(
          'The listening port is in use. Choose another port in Connection settings.',
        );
        return;
      }
      if (settings.internetHosting) {
        final router = await _discoverRouter();
        _router = router;
        if (_inactive) {
          await router.close();
          return;
        }
        router.onFailure = _fail;
        _ipv6Only = router is DirectIpv6Route;
        if (_ipv6Only && !host.supportsIpv6) {
          throw RouterAccessException(
            'This device could not start an IPv6 listener. Choose another listening port and create a new room.',
          );
        }
        internetEndpoint = await router.openRoom(host.port);
        if (_inactive) {
          await router.close();
          return;
        }
      }
      final target = await _hostInvitation(host, settings);
      hostedAddresses = target.addresses;
      invitation = target.encode();
      if (_inactive) {
        await host.close();
        return;
      }
      await _open(
        settings,
        {'type': 'create', 'owner': host.ownerToken},
        [host.loopback],
        target.fingerprint,
      );
    } on RouterAccessException catch (e) {
      if (!_closing) _fail(e.message);
    } catch (_) {
      if (!_closing) {
        _fail(
          'Unable to start a temporary room on this device. Check network access and try again.',
        );
      }
    }
  }

  Future<void> join(
    LineSettings settings,
    String roomInvitation,
    String password,
  ) async {
    isSender = false;
    try {
      if (ExchangeInvite.recognizes(roomInvitation)) {
        await _joinExchange(settings, roomInvitation, password);
        return;
      }
      final target = RoomInvitation.parse(roomInvitation);
      _ipv6Only = isIpv6OnlyInvitation(target.addresses);
      if (_ipv6Only && !await _receiverHasIpv6()) {
        _fail(
          'This invitation requires IPv6. This device has no usable IPv6 connection. Try a network with IPv6 or ask the host to use reachable public IPv4.',
        );
        return;
      }
      if (_inactive) return;
      await AndroidSession.acquire(
        this,
        hosting: false,
        onStop: () => _fail('Sharing stopped from the Android notification.'),
      );
      if (_inactive) {
        await AndroidSession.release(this);
        return;
      }
      room = target.room;
      invitation = target.encode();
      await _open(
        settings,
        {'type': 'join', 'room': room, 'code': password.trim()},
        target.addresses,
        target.fingerprint,
      );
    } on FormatException catch (e) {
      _fail(e.message.toString());
    } on PlatformException {
      _fail(
        'Android could not keep the sharing session active. Reopen Line and try again.',
      );
    }
  }

  Future<void> _open(
    LineSettings settings,
    Map<String, Object?> message,
    List<Uri> addresses,
    String fingerprint,
  ) async {
    final invalid = settings.validate();
    if (invalid != null) {
      _fail(invalid);
      return;
    }
    phase = LinkPhase.connecting;
    error = null;
    notifyListeners();
    var peerReady = false;
    try {
      await _createPeer(settings);
      peerReady = true;
      final connector = HostConnector();
      _connector = connector;
      final connected = await connector.connect(addresses, fingerprint);
      _socket = connected.socket;
      _httpClient = connected.client;
      connectionAttempts = List.of(connector.attempts);
      if (_inactive) {
        await _socket?.close();
        return;
      }
      _socket!.pingInterval = const Duration(seconds: 20);
      _socket!.listen(
        (raw) {
          _signals = _signals
              .then((_) async {
                if (_inactive) return;
                if (raw is! String || utf8.encode(raw).length > 64 * 1024) {
                  throw const FormatException();
                }
                await _handleSignal(jsonDecode(raw) as Map<String, dynamic>);
              })
              .catchError((Object e) {
                _fail('Connection negotiation failed.');
              });
        },
        onError: (Object e) => _fail('The hosting device disconnected.'),
        onDone: () {
          unawaited(_router?.closeRoomPort().catchError((Object _) {}));
          if (!_closing &&
              phase != LinkPhase.connected &&
              phase != LinkPhase.error) {
            _fail('The hosting device closed the room.');
          }
        },
      );
      _socket!.add(jsonEncode(message));
      _deadline = Timer(const Duration(seconds: 20), () {
        if (phase == LinkPhase.connecting) {
          _fail('The hosting device did not respond.');
        }
      });
    } catch (e) {
      if (!_closing) {
        if (e is HostDialException) connectionAttempts = e.attempts;
        _fail(
          peerReady
              ? e is HostDialException
                    ? e.message
                    : 'Unable to open the room on the hosting device. Copy a fresh invitation and try again.'
              : 'Unable to initialize WebRTC on this device. Reinstall the complete Line package and try again.',
        );
      }
    }
  }

  Future<void> _createPeer(
    LineSettings settings, {
    bool exchange = false,
  }) async {
    var exchangeStun = <String>[freeStunServer];
    if (exchange) {
      try {
        // Keep an explicit IPv4 route when the native resolver prefers AAAA.
        final ipv4 = await InternetAddress.lookup(
          'stun.cloudflare.com',
          type: InternetAddressType.IPv4,
        ).timeout(const Duration(seconds: 3));
        exchangeStun.addAll(
          ipv4.where(isPublicV4).take(2).map((ip) => 'stun:${ip.address}:3478'),
        );
      } on SocketException {
        // The native resolver can still try the hostname.
      } on TimeoutException {
        // Keep discovery bounded if the system resolver does not answer.
      }
    }
    final ice = <Map<String, dynamic>>[
      if (exchange)
        ...exchangeStun.map((url) => <String, dynamic>{'urls': url})
      else if (settings.stun.isNotEmpty)
        {'urls': settings.stun},
      if (!exchange && settings.turn.isNotEmpty)
        {
          'urls': settings.turn,
          'username': settings.turnUser,
          'credential': settings.turnPassword,
        },
    ];
    if (Platform.isWindows) {
      // This SDK reuses eight native slots; clear stale STUN/TURN on mode changes.
      while (ice.length < 8) {
        ice.add({'urls': '', 'username': '', 'credential': ''});
      }
    }
    _peer = await createPeerConnection({
      'iceServers': ice,
      'iceTransportPolicy': 'all',
      'sdpSemantics': 'unified-plan',
    });
    if (_inactive) {
      await _disposePeer(_peer);
      throw StateError('Sharing cancelled.');
    }
    _peer!.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty == true) {
        if (isIpv6Candidate(candidate.candidate!)) localIpv6Candidates++;
        if (RegExp(r'\btyp srflx\b').hasMatch(candidate.candidate!)) {
          reflexiveCandidates++;
        }
        if (RegExp(r'\btyp relay\b').hasMatch(candidate.candidate!)) {
          relayCandidates++;
        }
        _signal({'type': 'candidate', ...candidate.toMap()});
        final router = _router;
        if (router != null && !_inactive) {
          _routerCandidatesPending++;
          unawaited(() async {
            try {
              final mapped = await router.mapCandidate(candidate.candidate!);
              if (mapped != null && !_inactive) {
                mappedUdpCandidates++;
                _signal({
                  'type': 'candidate',
                  ...candidate.toMap(),
                  'candidate': mapped,
                });
              }
            } catch (_) {
              _fail(
                'The router could not open a temporary file-transfer route. Create a new room or use Nearby.',
              );
            } finally {
              _routerCandidatesPending--;
              _releaseSignaling();
            }
          }());
        }
      }
    };
    _peer!.onIceGatheringState = (state) {
      _gathered = state == RTCIceGatheringState.RTCIceGatheringStateComplete;
      if (_gathered && !_iceComplete.isCompleted) _iceComplete.complete();
      _releaseSignaling();
    };
    _peer!.onConnectionState = (state) {
      if (!_closing &&
          (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateClosed)) {
        _fail(
          'Unable to maintain the connection. Keep both networks connected and check the host network restrictions.',
        );
      }
    };
    _peer!.onDataChannel = _bindChannel;
  }

  Future<RoomInvitation> _hostInvitation(
    LocalRoomServer host,
    LineSettings settings,
  ) async {
    final route = _router;
    if (route is DirectIpv6Route) {
      return RoomInvitation(
        room: host.room,
        fingerprint: host.fingerprint,
        addresses: route.endpoints(host.port),
        expires: host.expires,
      );
    }
    return host.invitation(
      publicAddress: internetEndpoint?.toString() ?? settings.publicAddress,
    );
  }

  Future<String?> refreshInvitation(LineSettings settings) async {
    if (isExchange) return _inactive ? null : invitation;
    final host = _localServer;
    if (_closing ||
        host == null ||
        host.isClosed ||
        phase != LinkPhase.waiting) {
      return null;
    }
    final target = await _hostInvitation(host, settings);
    if (_closing || host.isClosed) return null;
    hostedAddresses = target.addresses;
    invitation = target.encode();
    notifyListeners();
    return invitation;
  }

  void _signal(Map<String, dynamic> data) {
    if (_ipv6Only) {
      if (data['type'] == 'candidate' &&
          !isIpv6Candidate(data['candidate'] as String)) {
        return;
      }
      if ((data['type'] == 'offer' || data['type'] == 'answer') &&
          data['sdp'] is String) {
        data = {...data, 'sdp': ipv6OnlySdp(data['sdp'] as String)};
      }
    }
    if (_socket?.readyState == WebSocket.open && !_readySent) {
      _socket!.add(jsonEncode({'type': 'signal', 'data': data}));
    }
  }

  Future<void> _handleSignal(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'created':
        room = message['room'];
        code = message['code'];
        expires = DateTime.fromMillisecondsSinceEpoch(message['expires']);
        phase = LinkPhase.waiting;
        _deadline?.cancel();
        notifyListeners();
      case 'joined':
        _startNegotiation();
      case 'peer-joined':
        _startNegotiation();
        final init = RTCDataChannelInit()..ordered = true;
        _bindChannel(await _peer!.createDataChannel('line-files-v1', init));
        final offer = await _peer!.createOffer();
        await _peer!.setLocalDescription(offer);
        _signal({'type': 'offer', 'sdp': offer.sdp});
      case 'signal':
        final data = message['data'] as Map<String, dynamic>;
        if (data['type'] == 'candidate') {
          if (_ipv6Only && !isIpv6Candidate(data['candidate'] as String)) {
            return;
          }
          final candidate = RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          );
          if (_remoteSet) {
            await _peer!.addCandidate(candidate);
          } else {
            _candidates.add(candidate);
          }
        } else if (data['type'] == 'offer' || data['type'] == 'answer') {
          await _peer!.setRemoteDescription(
            RTCSessionDescription(
              _ipv6Only ? ipv6OnlySdp(data['sdp'] as String) : data['sdp'],
              data['type'],
            ),
          );
          _remoteSet = true;
          for (final candidate in _candidates) {
            await _peer!.addCandidate(candidate);
          }
          _candidates.clear();
          if (data['type'] == 'offer') {
            final answer = await _peer!.createAnswer();
            await _peer!.setLocalDescription(answer);
            _signal({'type': 'answer', 'sdp': answer.sdp});
          }
          await _updateSafetyCode();
        }
      case 'error':
        _fail(message['message'] as String? ?? 'Unable to open the room.');
      default:
        throw const FormatException();
    }
  }

  void _startNegotiation() {
    phase = LinkPhase.negotiating;
    _deadline?.cancel();
    _deadline = Timer(const Duration(seconds: 60), () {
      if (phase != LinkPhase.connected) {
        _fail(
          'A direct file connection could not be established. Router or provider restrictions can block it. Try Nearby or a connection that accepts incoming traffic.',
        );
      }
    });
    notifyListeners();
  }

  void _bindChannel(RTCDataChannel channel) {
    if (_inactive) {
      unawaited(_finishCleanup('late data channel', channel.close));
      return;
    }
    if (_channel != null) {
      unawaited(channel.close());
      return;
    }
    _channel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        unawaited(_channelOpened(channel));
      } else if (state == RTCDataChannelState.RTCDataChannelClosed &&
          !_closing) {
        _fail('The connection was interrupted.');
      }
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      unawaited(_channelOpened(channel));
    }
  }

  Future<void> _channelOpened(RTCDataChannel channel) async {
    if (_wire != null || _inactive) return;
    _wire = _RtcWire(channel);
    transfer = TransferEngine(_wire!, isSender: isSender)
      ..addListener(_transferChanged);
    phase = LinkPhase.connected;
    unawaited(AndroidSession.transferring(this).catchError((Object _) {}));
    _deadline?.cancel();
    try {
      await _updateSafetyCode();
    } catch (_) {
      if (!_inactive) _fail('Unable to verify the secure connection.');
      return;
    }
    if (_inactive) return;
    _releaseSignaling();
    notifyListeners();
    if (isSender) await transfer!.offer(_selected);
  }

  void _transferChanged() {
    if (transfer?.phase == TransferPhase.complete ||
        transfer?.phase == TransferPhase.error ||
        transfer?.phase == TransferPhase.cancelled) {
      unawaited(AndroidSession.release(this).catchError((Object _) {}));
      unawaited(_router?.close());
    }
    if (!_closing) notifyListeners();
  }

  Future<void> _updateSafetyCode() async {
    final local = await _peer?.getLocalDescription();
    final remote = await _peer?.getRemoteDescription();
    final pattern = RegExp(r'a=fingerprint:sha-256 ([A-Fa-f0-9:]+)');
    final a = pattern.firstMatch(local?.sdp ?? '')?.group(1)?.toUpperCase();
    final b = pattern.firstMatch(remote?.sdp ?? '')?.group(1)?.toUpperCase();
    if (a != null && b != null) {
      final pair = [a, b]..sort();
      final digest = sha256.convert(utf8.encode(pair.join('|'))).toString();
      safetyCode = digest
          .substring(0, 12)
          .toUpperCase()
          .replaceAllMapped(RegExp(r'.{4}'), (m) => '${m[0]} ')
          .trim();
    }
  }

  void _releaseSignaling() {
    if (!_closing &&
        phase == LinkPhase.connected &&
        _gathered &&
        _routerCandidatesPending == 0 &&
        !_readySent &&
        _socket?.readyState == WebSocket.open) {
      _readySent = true;
      _socket!.add(jsonEncode({'type': 'ready'}));
    }
  }

  void _fail(String message) {
    if (_closing ||
        phase == LinkPhase.error ||
        transfer?.phase == TransferPhase.complete) {
      return;
    }
    error = message;
    phase = LinkPhase.error;
    _deadline?.cancel();
    notifyListeners();
    unawaited(close());
  }

  // Native close/remote WebSocket handshakes must not hold the UI indefinitely.
  Future<void> _finishCleanup(
    String resource,
    Future<void> Function() action,
  ) async {
    try {
      await action().timeout(const Duration(seconds: 2));
    } catch (_) {
      debugPrint('Line: $resource cleanup did not finish normally.');
    }
  }

  Future<void> _disposePeer(RTCPeerConnection? peer) async {
    if (peer == null) return;
    // Dispose channels and native observers while the peer still exists.
    await _finishCleanup('WebRTC dispose', peer.dispose);
    await _finishCleanup('WebRTC close', peer.close);
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    if (!_iceComplete.isCompleted) _iceComplete.complete();
    _connector?.cancel();
    _deadline?.cancel();
    _httpClient?.close(force: true);
    transfer?.removeListener(_transferChanged);
    await Future.wait([
      _finishCleanup('Android session', () => AndroidSession.release(this)),
      if (_socket != null)
        _finishCleanup('room socket', () async {
          await _socket!.close();
        }),
      if (_localServer != null)
        _finishCleanup('room listener', () => _localServer!.close()),
      if (_router != null)
        _finishCleanup('router routes', () => _router!.close()),
      () async {
        if (transfer != null) {
          await _finishCleanup('transfer cancel', transfer!.cancel);
          await _finishCleanup('transfer shutdown', transfer!.shutdown);
          transfer!.dispose();
        }
        if (_wire != null) await _finishCleanup('data channel', _wire!.close);
        await _disposePeer(_peer);
      }(),
    ]);
  }
}
