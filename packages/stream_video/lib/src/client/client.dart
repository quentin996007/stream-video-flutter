// import 'package:http/http.dart';
import 'package:http/http.dart';
import 'package:logging/logging.dart';
import 'package:stream_video/protobuf/video_coordinator_rpc/coordinator_service.pbserver.dart';
import 'package:stream_video/protobuf/video_coordinator_rpc/coordinator_service.pbtwirp.dart';
import 'package:stream_video/protobuf/video_models/models.pb.dart' hide EdgeServer;
import 'package:stream_video/src/core/error/error.dart';

import 'package:stream_video/src/core/http/token.dart';
import 'package:stream_video/src/core/http/token_manager.dart';
import 'package:stream_video/src/latency_service/latency.dart';
import 'package:stream_video/src/models/edge_server.dart';
import 'package:stream_video/src/models/user_info.dart';
import 'package:stream_video/src/models/video_options.dart';
import 'package:stream_video/src/state/state.dart';
import 'package:stream_video/src/video_service/video_service.dart';
import 'package:stream_video/src/ws/websocket.dart';
import 'package:stream_video/stream_video.dart';
import 'package:tart/tart.dart';

/// Handler function used for logging records. Function requires a single
/// [LogRecord] as the only parameter.
typedef LogHandlerFunction = void Function(LogRecord record);

final _levelEmojiMapper = {
  Level.INFO: 'ℹ️',
  Level.WARNING: '⚠️',
  Level.SEVERE: '🚨',
};

class StreamVideoClient {
  late final CallCoordinatorServiceProtobufClient _callCoordinatorService;
  late final LatencyService _latencyService;
  late final WebSocketClient _ws;
  final _tokenManager = TokenManager();

  late final VideoService _videoService;
  StreamVideoClient(
    String apiKey, {
    this.logLevel = Level.WARNING,
    String? coordinatorUrl,
    String? baseURL,
    this.logHandlerFunction = StreamVideoClient.defaultLogHandler,
    WebSocketClient? ws,
  }) {
    _callCoordinatorService = CallCoordinatorServiceProtobufClient(
      coordinatorUrl ?? "http://localhost:26991",
      "",
      hooks: ClientHooks(
        onRequestPrepared: onClientRequestPrepared,
      ),
      // interceptor: myInterceptor()
    );

    _state = ClientState();
    _ws = ws ?? WebSocketClient(logger: logger, state: _state);
    _latencyService = LatencyService(logger: logger);
  }

  /// Client specific logger instance.
  /// Refer to the class [Logger] to learn more about the specific
  /// implementation.
  late final Logger logger = detachedLogger('📡');

  /// This client state
  late final ClientState _state;
  final LogHandlerFunction logHandlerFunction;

  final Level logLevel;

  /// Default log handler function for the [StreamChatClient] logger.
  static void defaultLogHandler(LogRecord record) {
    print(
      '${record.time} '
      '${_levelEmojiMapper[record.level] ?? record.level.name} '
      '${record.loggerName} ${record.message} ',
    );
    if (record.error != null) print(record.error);
    if (record.stackTrace != null) print(record.stackTrace);
  }

  /// Default logger for the [StreamChatClient].
  Logger detachedLogger(String name) => Logger.detached(name)
    ..level = logLevel
    ..onRecord.listen(logHandlerFunction);

  Future<void> setUser(UserInfo user,
      {Token? token,
      TokenProvider? provider,
      bool connectWebSocket = true}) async {
    logger.info('setting user : ${user.id}');
    logger.info('setting token : ${token!.rawValue}');

    await _tokenManager.setTokenOrProvider(
      user.id,
      token: token,
      provider: provider,
    );

    _state.currentUser = user;
  }

  Future<void> connectWs() async {
    final user = _state.currentUser;
    final token = await _tokenManager.loadToken();
    print("TOKEN ${token.rawValue}");
    _ws.connect(user: user!, token: token);
  }

  Future<EdgeServer> selectEdgeServer({
    required String callId,
    required Map<String, Latency> latencyByEdge,
  }) async {
    try {
      final token = await _tokenManager.loadToken();
      final ctx = _authorizationCtx(token);

      final response = await _callCoordinatorService.selectEdgeServer(
          ctx,
          SelectEdgeServerRequest(
              callId: callId, latencyByEdge: latencyByEdge));
      return EdgeServer(token: response.token, url: response.edgeServer.url);
    } on TwirpError catch (e) {
      final method =
          e.getContext.value(ContextKeys.methodName) ?? 'unknown method';
      throw StreamVideoError(
          'Twirp error on method: $method. Code: ${e.getCode}. Message: ${e.getMsg}');
    } on InvalidTwirpHeader catch (e) {
      throw StreamVideoError('InvalidTwirpHeader: $e');
    } catch (e, stack) {
      throw StreamVideoError('''
      Unknown Exception Occurred: $e
      Stack trace: $stack
      ''');
    }
  }

  Future<VideoRoom> startCall({
    required String id,
    required List<String> participantIds,
    required StreamCallType type,
    required VideoOptions videoOptions,
    //TODO: expose more parameters
  }) async {
    final createCallResponse =
        await createCall(id: id, participantIds: participantIds, type: type);
    //TODO: is this debug stuff really useful?
    assert(StreamCallType.video.rawType == createCallResponse.call.type,
        "call type from backend and client are different");

    final edges =
        await joinCall(callId: createCallResponse.call.id, type: type);
    Map<String, Latency> latencyByEdge = await _latencyService.measureLatencies(edges);
    final edgeServer = await selectEdgeServer(
        callId: createCallResponse.call.id, latencyByEdge: latencyByEdge);
    final room = await _videoService.connect(
        url: edgeServer.url, token: edgeServer.token, options: videoOptions);
    _state.participants.room = room;
    return room;
  }

 

  Future<CreateCallResponse> createCall(
      {required String id,
      required List<String> participantIds,
      required StreamCallType type
      //TODO: expose more parameters

      }) async {
    try {
      final token = await _tokenManager.loadToken();
      final ctx = _authorizationCtx(token);

      final response = await _callCoordinatorService.createCall(
          ctx,
          CreateCallRequest(
              id: id, participantIds: participantIds, type: type.rawType));
      return response;
    } on TwirpError catch (e) {
      final method =
          e.getContext.value(ContextKeys.methodName) ?? 'unknown method';
      throw StreamVideoError(
          'Twirp error on method: $method. Code: ${e.getCode}. Message: ${e.getMsg}');
    } on InvalidTwirpHeader catch (e) {
      throw StreamVideoError('InvalidTwirpHeader: $e');
    } catch (e, stack) {
      throw StreamVideoError('''
      Unknown Exception Occurred: $e
      Stack trace: $stack
      ''');
    }
  }

  Context _authorizationCtx(Token token) {
    return withHttpRequestHeaders(
        Context(), {'authorization': 'Bearer ${token.rawValue}}'});
  }

  Future<List<Edge>> joinCall(
      {required String callId, required StreamCallType type}) async {
    try {
      final token = await _tokenManager.loadToken();
      final ctx = _authorizationCtx(token);

      final response = await _callCoordinatorService.joinCall(
          ctx, JoinCallRequest(id: callId, type: type.rawType));
      return response.edges;
    } on TwirpError catch (e) {
      final method =
          e.getContext.value(ContextKeys.methodName) ?? 'unknown method';
      throw StreamVideoError(
          'Twirp error on method: $method. Code: ${e.getCode}. Message: ${e.getMsg}');
    } on InvalidTwirpHeader catch (e) {
      throw StreamVideoError('InvalidTwirpHeader: $e');
    } catch (e, stack) {
      throw StreamVideoError('''
      Unknown Exception Occurred: $e
      Stack trace: $stack
      ''');
    }
  }
}

/// onClientRequestPrepared is a client hook used to print out the method name of the RPC call
Context onClientRequestPrepared(Context ctx, Request req) {
  final methodNameVal = ctx.value(ContextKeys.methodName);
  print('RequestPrepared for $methodNameVal');
  return ctx;
}

/// myInterceptor is an example of how to use an interceptor to catch the context and request
/// before the RPC is made to the server. Depending on how many interceptors there are [next]
/// could represent another interceptor by using [chainInterceptor] or the actual RPC call
// Interceptor myInterceptor(/* pass in any dependencies needed */) {
//   return (Method next) {
//     return (Context ctx, dynamic req) {
//       switch (req.runtimeType) {
//         case Size:
//           print('This will be ran before the makeHat call');
//           break;
//         case SuitSizeReq:
//           print('This will be ran before the makeSuit call');
//       }
//       final serviceName = ctx.value(ContextKeys.serviceName);
//       final methodName = ctx.value(ContextKeys.methodName);
//       final reqDetails = req.toString().replaceAll('\n', '');
//       print('Service: $serviceName, Method: $methodName, Request: $reqDetails');

//       // ALWAYS call the next method (interceptor or RPC call)
//       return next(ctx, req);
//     };
//   };
// }