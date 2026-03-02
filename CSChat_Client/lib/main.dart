import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:url_launcher/url_launcher.dart'; // For OTA downloads
import 'package:package_info_plus/package_info_plus.dart'; // For version display
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
import 'services.dart';
import 'models.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 설정 초기화
  await ConfigService.to.init();
  
  // 알림 서비스 초기화
  await NotificationService.to.init();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = const WindowOptions(
      size: Size(450, 800),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: "CSChat", // Inno Setup looks for window titles
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      
      // [Tray] 시스템 트레이 초기화 (Windows)
      await _initTray();
      
      // [Window] 창 닫기 버튼 가로채기 설정
      await windowManager.setPreventClose(true);
    });
  }
  
  // 백그라운드 서비스용 알림 채널 사전 생성 (필수!)
  await _createForegroundNotificationChannel();
  
  // 백그라운드 서비스 설정 (configure만, start는 로그인 후)
  await configureBackgroundService();
  
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: AppState.to),
      ],
      child: const CSChatApp(),
    ),
  );
}

// [Tray] 트레이 초기화 함수
Future<void> _initTray() async {
  if (!Platform.isWindows) return;
  
  try {
    await trayManager.setIcon(
      Platform.isWindows 
        ? 'assets/images/app_icon.ico' 
        : 'assets/images/app_icon.png',
    );
    
    Menu menu = Menu(
      items: [
        MenuItem(
          key: 'show_window',
          label: '열기',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'exit_app',
          label: '종료',
        ),
      ],
    );
    await trayManager.setContextMenu(menu);
    await trayManager.setToolTip('CSChat');
  } catch (e) {
    print('[Tray] Initialization Error: $e');
  }
}

// 백그라운드 서비스용 알림 채널 생성 함수
Future<void> _createForegroundNotificationChannel() async {
  try {
    print('[Main] Creating foreground notification channel...');
    
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();
    
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'my_foreground_service', // 채널 ID (서비스 설정과 일치)
      'CSChat 백그라운드 서비스', // 채널 이름
      description: 'CSChat 백그라운드 메시지 수신 서비스',
      importance: Importance.low, // 포그라운드 서비스는 low로 설정
      playSound: false,
      enableVibration: false,
    );
    
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    
    print('[Main] Foreground notification channel created successfully');
  } catch (e) {
    print('[Main] Failed to create notification channel: $e');
  }
}

class CSChatApp extends StatefulWidget {
  const CSChatApp({super.key});

  @override
  State<CSChatApp> createState() => _CSChatAppState();
}

class _CSChatAppState extends State<CSChatApp> with WidgetsBindingObserver, WindowListener, TrayListener {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this); // WindowListener 등록
    trayManager.addListener(this);   // TrayListener 등록
    
    // 인앱 알림배너 리스너 등록
    NotificationService.to.onInAppNotification = _showInAppBanner;
    
    // 알림 클릭 리스너 등록 (Global)
    NotificationService.to.onNotificationClick = _handleGlobalNotificationClick;
  }

  Future<void> _handleGlobalNotificationClick(String payload) async {
    print('[GlobalNotification] Clicked: $payload');
    if (navigatorKey.currentState != null) {
      // MainApp 레벨에서 핸들러 호출
      // payload가 JSON인지 확인하고 ChatScreen으로 이동
      try {
        final pData = jsonDecode(payload);
        final roomId = pData['roomId'];
        // ... (나머지 로직은 메인 화면의 핸들러와 중복될 수 있으므로 통합 고려)
      } catch (e) {
        print('[GlobalNotification] Error: $e');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this); // Listener 해제
    trayManager.removeListener(this);
    super.dispose();
  }

  // --- WindowListener ---
  @override
  void onWindowClose() {
    // 닫기 버튼 클릭 시 종료하지 않고 숨김
    windowManager.isPreventClose().then((isPreventClose) {
      if (isPreventClose) {
        windowManager.hide();
        print('[Window] Minimize to Tray (Hidden)');
      }
    });
  }

  // --- TrayListener ---
  @override
  void onTrayIconMouseDown() {
    // 트레이 아이콘 클릭 시 앱 열기
    windowManager.show();
    windowManager.focus();
    // [User Request] 어느 탭에서든 채팅탭(index 1)으로 강제 전환
    AppState.to.setTabIndex(1);
  }

  @override
  void onTrayIconRightMouseDown() {
    // [v2.5.9] Windows에서 우클릭 시 메뉴가 뜨지 않는 문제 수정
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_window') {
      windowManager.show();
      windowManager.focus();
      // [User Request] 채팅탭으로 전환
      AppState.to.setTabIndex(1);
    } else if (menuItem.key == 'exit_app') {
      // 실제 종료 - [v2.5.8] 종료 안정성 강화
      print('[Tray] Exiting application...');
      await windowManager.setPreventClose(false);
      await windowManager.close();
      exit(0);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    bool focused = (state == AppLifecycleState.resumed);
    AppState.to.setFocused(focused);
    print('[Main] App Focus Change: $focused ($state)');
    
    // [하이브리드 방식] 백그라운드로 갈 때 포그라운드 서비스 알림 업데이트
    if (Platform.isAndroid && !focused && state == AppLifecycleState.paused) {
      try {
        final service = FlutterBackgroundService();
        final isRunning = await service.isRunning();
        
        if (isRunning) {
          // 백그라운드 서비스에 알림 업데이트 요청
          service.invoke('setAsForeground');
          print('[Main] Foreground service notification updated for background mode');
        }
      } catch (e) {
        print('[Main] Failed to update foreground notification: $e');
      }
    }
  }

  void _showInAppBanner(String title, String body, String payload) {
    print('[Main] Showing in-app banner: $title');
    if (!mounted) return;
    
    // [Bug Fix] navigatorKey.currentState?.overlay를 직접 사용하여 더 확실하게 오버레이 획득
    final overlayState = navigatorKey.currentState?.overlay;
    if (overlayState == null) {
      print('[Main] FATAL: navigatorKey.currentState?.overlay is NULL');
      return;
    }
    
    print('[Main] OverlayState found, building banner...');
    
    late OverlayEntry entry;
    
    entry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 10,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: InAppNotificationBanner(
            title: title,
            body: body,
            onTap: () {
              entry.remove();
              if (NotificationService.to.onNotificationClick != null) {
                NotificationService.to.onNotificationClick!(payload);
              }
            },
            onDismiss: () {
              entry.remove();
            },
          ),
        ),
      ),
    );

    overlayState.insert(entry);
    print('[Main] In-app banner inserted into Overlay');
    
    // 3초 후 자동 삭제
    Future.delayed(const Duration(seconds: 3), () {
      try {
        entry.remove();
      } catch (_) {
        // 이미 삭제되었거나 다른 이유로 실패한 경우 무시
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConfigService.to.themeNotifier,
      builder: (context, isDark, child) {
        return MaterialApp(
          navigatorKey: navigatorKey, // 서비스에서 정의된 키 사용
          title: 'CSChat',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: Brightness.dark,
              surface: const Color(0xFF121212), // 다크 모드 배경색
            ),
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFF121212), // 스캐폴드 배경
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF1E1E1E), // 앱바 배경
              foregroundColor: Colors.white,
            ),
            cardColor: const Color(0xFF1E1E1E),
          ),
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          home: const LoginScreen(),
        );
      },
    );
  }
}

// --- Models ---







// --- Constants ---
// const String serverUrl = 'http://192.168.0.43:3001'; // Removed: Use ConfigService.to.serverUrl

// --- Global Socket Service ---
class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? socket;
  final ValueNotifier<bool> isConnected = ValueNotifier<bool>(false);
  int? _currentRoomId;

  void init(int userId) {
    if (socket != null) {
      socket!.dispose();
    }

    final serverUrl = ConfigService.to.serverUrl;
    print('[Socket] 초기화 시작: $serverUrl (User: $userId)');
    socket = IO.io(serverUrl, IO.OptionBuilder()
      .setTransports(['websocket', 'polling']) // [v2.5.25] 폴링 폴백 추가
      .enableForceNew()
      .enableReconnection()
      .setReconnectionDelay(1500) // 재연결 지연 상향
      .setReconnectionDelayMax(5000)
      .setReconnectionAttempts(99999) // 사실상 무한 재시도
      .setExtraHeaders({'Connection': 'keep-alive'}) // 연결 유지 헤더
      .build());

    socket!.onConnect((_) async {
      print('[Socket] 연결 성공: ${socket!.id}');
      isConnected.value = true;
      
      // [Fix] deviceId를 함께 보내어 중복 로그인 오탐지 방지
      final deviceId = await DeviceService.to.getDeviceId();
      socket!.emit('register_user', {
        'userId': userId,
        'deviceId': deviceId,
      });
      
      if (_currentRoomId != null) {
        socket!.emit('join_room', _currentRoomId);
      }
      
      // [Added] 초기 연결 시 전체 안읽은 수 갱신
      AppState.to.refreshTotalUnread();
    });

    socket!.onDisconnect((_) {
      print('[Socket] 연결 끊김');
      isConnected.value = false;
    });

    socket!.onConnectError((data) => print('[Socket] 연결 에러: $data'));
    socket!.on('error', (data) => print('[Socket] 일반 에러: $data'));
    
    socket!.on('force_logout', (data) {
      print('[Socket] Force Logout received: $data');
      final message = data is Map ? (data['message'] ?? '다른 기기에서 로그인하여 접속이 종료되었습니다.') : '다른 기기에서 로그인하여 접속이 종료되었습니다.';
      
      // 전역 Navigator를 통해 다이얼로그 표시
      final context = navigatorKey.currentContext;
      if (context != null) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('중복 로그인 알림'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () async {
                  // [Fix] 세션만 종료하고 저장된 계정 정보는 유지 (안정성 향상)
                  // 자동 로그인이 해제되지 않도록 saved_username/password 삭제 로직 제거
                  
                  if (ctx.mounted) {
                    Navigator.of(ctx).pop();
                    navigatorKey.currentState?.pushAndRemoveUntil(
                      MaterialPageRoute(builder: (c) => const LoginScreen()),
                      (route) => false,
                    );
                  }
                },
                child: const Text('확인'),
              ),
            ],
          ),
        );
      }
    });
    
    // [Added] 긴급 공지 수신 핸들러 (전역)
    socket!.on('notice', (data) {
      try {
        final content = data['content'] ?? '';
        final senderName = data['senderName'] ?? data['sender_name'] ?? '시스템 관리자';
        final roomId = data['roomId'] ?? data['room_id'];
        final parsedRoomId = roomId is int ? roomId : int.tryParse(roomId.toString()) ?? 0;
        
        final payload = jsonEncode({
          'roomId': parsedRoomId,
          'roomName': '긴급 공지',
          'isGroup': true,
          'senderId': 1,
          'senderName': senderName,
        });

        NotificationService.to.show(
          '📢 [긴급] $senderName',
          content,
          payload: payload,
          roomId: parsedRoomId,
        );
      } catch (e) {
        print('[Socket] Notice Notification Error: $e');
      }
    });

    // [Added] 전역 메시지 수신 핸들러 (포그라운드 알림용)
    socket!.on('receive_message', (data) {
      print('[Socket] Global Message Received: $data');
      try {
        final currentUid = ConfigService.to.currentUser?.id;
        final senderId = (data['senderId'] ?? data['sender_id']);
        final parsedSenderId = senderId is int ? senderId : int.tryParse(senderId.toString()) ?? 0;
        
        // 내가 보낸 메시지는 알림 제외
        if (currentUid != null && parsedSenderId == currentUid) {
          print('[Socket] Skip notification: Message from self');
          return;
        }

        final roomId = data['roomId'] ?? data['room_id'];
        final parsedRoomId = roomId is int ? roomId : int.tryParse(roomId.toString()) ?? 0;
        
        final curRoomId = AppState.to.currentRoomId;
        print('[Socket] Notification Check: MsgRoom=$parsedRoomId, CurRoom=$curRoomId, Focused=${AppState.to.isFocused}');

        // 현재 열려있는 방의 메시지면 알림 생략
        if (curRoomId == parsedRoomId) return;

        // [Added] 다른 방 메시지 수신 시 전체 안읽은 수 증가
        AppState.to.incrementTotalUnreadCount();

        final content = data['content'] ?? '사진을 보냈습니다.';
        final senderName = data['senderName'] ?? data['sender_name'] ?? '알 수 없음';
        final isGroup = data['isGroup'] == true || data['is_group'] == 1;
        
        String title = senderName;
        if (isGroup) {
            title = '[그룹] $senderName';
        }

        final payload = jsonEncode({
          'roomId': parsedRoomId,
          'roomName': isGroup ? '그룹 채팅' : senderName, 
          'isGroup': isGroup, 
          'senderId': parsedSenderId,
          'senderName': senderName,
        });

        NotificationService.to.show(
          title, 
          content,
          payload: payload,
          roomId: parsedRoomId,
        );
      } catch (e) {
        print('[Socket] Global Notification Error: $e');
      }
    });

    socket!.on('registration_success', (data) {
      print('[Socket] Registration Success: $data');
      final serverStartTime = data['startTime'];
      if (serverStartTime != null) {
        _handleServerRestart(serverStartTime);
      }
    });

    socket!.connect();
  }

  // [Added v2.0.0] 서버 재시작 처리 로직
  int? _lastServerStartTime;
  void _handleServerRestart(int newStartTime) {
    if (_lastServerStartTime != null && _lastServerStartTime! < newStartTime) {
      print('[Socket] 서버 재시작 감지됨! (이전: $_lastServerStartTime, 현재: $newStartTime)');
      NotificationService.to.show(
        '🔄 연결 복구',
        '서버가 재시작되어 실시간 연결이 자동으로 복구되었습니다.',
        payload: jsonEncode({'type': 'system'}),
        roomId: 0,
      );
    }
    _lastServerStartTime = newStartTime;
  }

  void joinRoom(int roomId) {
    _currentRoomId = roomId;
    AppState.to.setRoomId(roomId); // AppState 동기화
    if (socket != null && isConnected.value) {
      socket!.emit('join_room', roomId);
      print('[Socket] 방 입장 시도: $roomId');
    }
  }

  void sendMessage(Map<String, dynamic> data) {
    if (socket != null && isConnected.value) {
      socket!.emit('send_message', data);
    }
  }

  void dispose() {
    socket?.dispose();
    socket = null;
    isConnected.value = false;
  }
}

final socketService = SocketService();

class ConnectionStatusBar extends StatelessWidget {
  const ConnectionStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: socketService.isConnected,
      builder: (context, isConnected, child) {
        if (isConnected) return const SizedBox.shrink();
        
        return Container(
          width: double.infinity,
          color: Colors.red[600],
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_off, color: Colors.white, size: 14),
              SizedBox(width: 8),
              Text(
                '서버와 연결이 끊어졌습니다. 연결 재시도 중...',
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              SizedBox(width: 8),
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// --- Login Screen ---
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  bool _isLoading = false;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _initVersion();
    _checkAutoLogin();
    // [v2.5.7] 앱 실행 시 업데이트 확인
    WidgetsBinding.instance.addPostFrameCallback((_) => _startUpdateCheck());
  }

  Future<void> _startUpdateCheck() async {
    final info = await PackageInfo.fromPlatform();
    final updateInfo = await UpdateService.to.checkForUpdate(info.version, int.tryParse(info.buildNumber) ?? 0);
    
    if (updateInfo != null && mounted) {
      _showUpdateDialog(
        context, 
        updateInfo,
        currentVersion: info.version,
        currentBuild: int.tryParse(info.buildNumber) ?? 0,
      );
    }
  }

  Future<void> _initVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = info.version);
  }

  Future<void> _checkAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('saved_username');
    final password = prefs.getString('saved_password');

    if (username != null && password != null) {
      _userController.text = username;
      _passController.text = password;
      
      // 권한 요청 후 로그인 진행
      await _requestNotificationPermission();
      // 백그라운드 서비스는 로그인 성공 후 초기화
      
      _login(isAuto: true);
    }
  }

  Future<bool> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      try {
        final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
        final granted = await flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        
        print('[Permission] Notification permission: ${granted ?? false}');
        return granted ?? false;
      } catch (e) {
        print('[Permission] Failed to request notification permission: $e');
        return false;
      }
    }
    return true; // iOS는 기본 허용으로 간주
  }

  Future<void> _checkAndRequestBatteryOptimization() async {
    if (Platform.isAndroid) {
      try {
        // 배터리 최적화 상태 확인 (실제 구현은 permission_handler 필요)
        // 여기서는 사용자에게 안내만 표시
        print('[Battery] Checking battery optimization...');
        
        // 사용자에게 배터리 최적화 제외 안내
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('백그라운드 알림 안내'),
              content: const Text(
                '앱이 종료된 상태에서도 메시지 알림을 받으려면 배터리 최적화를 제외해주세요.\n\n'
                '설정 > 앱 > CSChat > 배터리 > 제한 없음'
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('나중에'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    // 설정 화면으로 이동하는 로직 (추후 구현)
                    print('[Battery] User wants to change settings');
                  },
                  child: const Text('설정하기'),
                ),
              ],
            ),
          );
        }
      } catch (e) {
        print('[Battery] Failed to check battery optimization: $e');
      }
    }
  }

  Future<void> _requestBatteryOptimizationExemption() async {
    if (Platform.isAndroid) {
      try {
        // Android 6.0+ 배터리 최적화 제외 요청
        // 사용자에게 설정 화면을 표시하여 선택하도록 함
        print('[Battery] Requesting battery optimization exemption');
        // 실제 구현은 android_intent_plus 또는 permission_handler 패키지 필요
        // 현재는 로그만 출력
      } catch (e) {
        print('[Battery] Failed to request exemption: $e');
      }
    }
  }

  Future<void> _login({bool isAuto = false}) async {
    if (_isLoading) return;

    setState(() => _isLoading = true);
    try {
      final serverUrl = ConfigService.to.serverUrl;
      final macAddress = await DeviceService.to.getDeviceId();
      final deviceInfo = await DeviceService.to.getDetailedInfo(); // [v2.5.4]
      print('[Login] Device MAC (ID): $macAddress, Info: $deviceInfo');

      final response = await http.post(
        Uri.parse('$serverUrl/api/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': _userController.text,
          'password': _passController.text,
          'macAddress': macAddress,
          'osInfo': deviceInfo['osInfo'],
          'deviceType': deviceInfo['deviceType'],
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final user = User.fromJson(data['user']);
        
        // [New] 서비스에 유저 정보 저장
        ConfigService.to.currentUser = user;
        
        // [New] 알림 클릭 핸들러 등록
        NotificationService.to.onNotificationClick = (payload) {
          try {
            print('[Notification] Clicked with payload: $payload');
            final pData = jsonDecode(payload);
            final roomId = pData['roomId'];
            final roomName = pData['roomName'];
            final isGroup = pData['isGroup'] ?? false;
            final targetUserId = pData['senderId'];
            final targetUserName = pData['senderName'];

            // 네비게이션 키를 이용해 이동
            navigatorKey.currentState?.push(
              MaterialPageRoute(
                builder: (context) => ChatScreen(
                  currentUser: user, // 캡처된 user 객체 사용
                  roomId: roomId,
                  roomName: roomName,
                  isGroup: isGroup,
                  targetUser: isGroup ? null : User(id: targetUserId, username: targetUserName), 
                ),
              ),
            );
          } catch (e) {
            print('Nav Error: $e');
          }
        };
        
        // 자동 로그인이 아닐 경우에만 저장 (또는 갱신)
        if (!isAuto) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('saved_username', _userController.text);
            await prefs.setString('saved_password', _passController.text);
        }
        
        // [New] 백그라운드 서비스를 위해 userId 저장
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('current_user_id', user.id);
        print('[Login] Saved userId for background service: ${user.id}');
        
        // 소켓 연결 시작 및 대기 (인증 성공 후 즉시 시도)
        socketService.init(user.id);
        
        // [v2.0.0] 연결될 때까지 충분히 대기 (최대 6초)
        int retry = 0;
        bool isSocketConnected = false;
        while (retry < 30) {
          if (socketService.isConnected.value) {
            isSocketConnected = true;
            break;
          }
          await Future.delayed(const Duration(milliseconds: 200));
          retry++;
        }

        if (context.mounted) {
          // 알림 권한 요청 (Android 13+) - 필수
          final notificationGranted = await _requestNotificationPermission();
          
          // 배터리 최적화 제외 안내 (선택적)
          await _checkAndRequestBatteryOptimization();
          
          // 백그라운드 서비스 시작 (권한 확인 후)
          if (notificationGranted) {
            try {
              final started = await startBackgroundService();
              if (started) {
                print('[Login] Background service started successfully');
              } else {
                print('[Login] Background service failed to start');
              }
            } catch (e) {
              print('[Login] Service start error: $e');
            }
          }

          if (isSocketConnected) {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => MainScreen(currentUser: user)),
              (route) => false,
            );
          } else {
            // [v2.0.0] 연결 지연 시 알림 후 진입
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('통신 서버 연결이 지연되고 있습니다. 잠시 후 자동으로 연결됩니다.'))
            );
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => MainScreen(currentUser: user)),
              (route) => false,
            );
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('아이디 또는 비밀번호가 틀렸습니다.')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('로그인 통신 오류: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showServerConfigDialog() {
    final TextEditingController ipController = TextEditingController();
    final TextEditingController portController = TextEditingController();
    
    // 현재 설정된 URL에서 IP와 Port 추출
    final currentUrl = ConfigService.to.serverUrl;
    final uri = Uri.tryParse(currentUrl);
    
    if (uri != null) {
      ipController.text = uri.host;
      portController.text = uri.port.toString();
    } else {
      ipController.text = '192.168.0.43';
      portController.text = '3001';
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('서버 설정'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipController,
              decoration: const InputDecoration(labelText: '서버 IP (예: 192.168.0.43)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: portController,
              decoration: const InputDecoration(labelText: '포트 (예: 3001)'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () async {
              final ip = ipController.text.trim();
              final port = portController.text.trim();
              
              if (ip.isNotEmpty && port.isNotEmpty) {
                final newUrl = 'http://$ip:$port';
                await ConfigService.to.setServerUrl(newUrl);
                
                print('[Config] Server URL updated to: $newUrl');
                
                if (mounted) {
                   Navigator.pop(context);
                   ScaffoldMessenger.of(context).showSnackBar(
                     SnackBar(content: Text('서버 주소가 변경되었습니다: $newUrl')),
                   );
                }
              }
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 테마 기반 색상 설정
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      // backgroundColor: Colors.grey[50], // 하드코딩 제거
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            margin: const EdgeInsets.all(24.0),
            padding: const EdgeInsets.all(32.0),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor, // 테마 카드 색상 사용
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 앱 로고
                GestureDetector(
                  onTap: _showServerConfigDialog,
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.indigo[600],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(
                      Icons.shield_outlined,
                      size: 45,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // 앱 타이틀
                const Text(
                  'CSChat',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '단독망 전용 메신저',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 40),
                // 아이디 입력
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '아이디',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[800],
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _userController,
                      style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                      decoration: InputDecoration(
                        hintText: '아이디를 입력하세요',
                        filled: true,
                        fillColor: isDark ? Colors.grey[800] : Colors.grey[100], // 다크 모드 지원
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                      ),
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // 비밀번호 입력
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '비밀번호',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[800],
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _passController,
                      obscureText: true,
                      style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                      decoration: InputDecoration(
                        hintText: '비밀번호를 입력하세요',
                        filled: true,
                        fillColor: isDark ? Colors.grey[800] : Colors.grey[100], // 다크 모드 지원
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                      ),

                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _login(),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                // 로그인 버튼
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: _isLoading
                      ? Center(
                          child: CircularProgressIndicator(
                            color: Colors.indigo[600],
                          ),
                        )
                      : ElevatedButton(
                          onPressed: _login,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.indigo[600],
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.login, size: 20),
                              SizedBox(width: 8),
                              Text(
                                '로그인',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 24),
                // 앱 버전 정보
                Text(
                  'APP VERSION $_version',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[400],
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- Main Screen (Tab Navigation) ---
class MainScreen extends StatefulWidget {
  final User currentUser;
  const MainScreen({super.key, required this.currentUser});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = AppState.to.currentTabIndex;
    AppState.to.addListener(_onAppStateChanged);

    // 알림 클릭 핸들러 재설정
    NotificationService.to.onNotificationClick = (payload) {
      _handleNotificationClick(payload);
    };
    
    // 앱이 알림으로 실행되었는지 확인
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.to.checkForLaunchPayload();
      // [v2.5.7] 메인 화면 진입 시에도 업데이트 확인
      _startUpdateCheck();
    });
  }

  Future<void> _startUpdateCheck() async {
    final info = await PackageInfo.fromPlatform();
    final updateInfo = await UpdateService.to.checkForUpdate(info.version, int.tryParse(info.buildNumber) ?? 0);
    
    if (updateInfo != null && mounted) {
      _showUpdateDialog(
        context, 
        updateInfo, 
        currentVersion: info.version,
        currentBuild: int.tryParse(info.buildNumber) ?? 0,
      );
    }
  }

  void _onAppStateChanged() {
    if (mounted) {
      if (_selectedIndex != AppState.to.currentTabIndex) {
        setState(() {
          _selectedIndex = AppState.to.currentTabIndex;
        });
      }
    }
  }

  @override
  void dispose() {
    AppState.to.removeListener(_onAppStateChanged);
    super.dispose();
  }

  Future<void> _handleNotificationClick(String payload) async {
    try {
      final pData = jsonDecode(payload);
      final roomId = pData['roomId'];
      final roomName = pData['roomName'];
      final isGroup = pData['isGroup'] ?? false;
      final targetUserId = pData['senderId'];
      final targetUserName = pData['senderName'];

      if (Platform.isWindows) {
        await windowManager.show();
        await windowManager.focus();
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            currentUser: widget.currentUser,
            roomId: roomId, 
            roomName: roomName,
            isGroup: isGroup,
            targetUser: isGroup ? null : User(id: targetUserId, username: targetUserName),
          ),
        ),
      );
    } catch (e) {
      print('Nav Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (Platform.isAndroid) {
          final channel = MethodChannel('com.example.cschat/sound');
          try {
            await channel.invokeMethod('moveTaskToBack');
            return false; // 앱 종료 방지
          } catch (e) {
            print('MoveTaskToBack Error: $e');
            return true; // 에러 시 기본 동작 (종료)
          }
        }
        return true;
      },
      child: Scaffold(
        body: Column(
          children: [
            const ConnectionStatusBar(),
            Expanded(
              child: [
                FriendsTab(currentUser: widget.currentUser),
                ChatsTab(currentUser: widget.currentUser),
                SettingsTab(currentUser: widget.currentUser),
              ][_selectedIndex],
            ),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: (index) => AppState.to.setTabIndex(index),
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.people), label: '친구'),
            BottomNavigationBarItem(icon: Icon(Icons.chat), label: '채팅'),
            BottomNavigationBarItem(icon: Icon(Icons.settings), label: '설정'),
          ],
        ),
      ),
    );
  }
}

// --- Friends Tab ---
class FriendsTab extends StatefulWidget {
  final User currentUser;
  const FriendsTab({super.key, required this.currentUser});

  @override
  State<FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<FriendsTab> {
  List<User> _users = [];
  String _searchQuery = ''; // 검색어 상태 추가

  // 필터링된 친구 목록
  List<User> get _filteredUsers {
    if (_searchQuery.isEmpty) return _users;
    return _users.where((user) =>
      user.username.toLowerCase().contains(_searchQuery.toLowerCase())
    ).toList();
  }

  @override
  void initState() {
    super.initState();
    _fetchUsers();
    _listenUserStatus();
  }

  void _listenUserStatus() {
    socketService.socket?.on('user_status', (data) {
      final userId = data['userId'];
      final status = data['status'];
      
      if (mounted) {
        setState(() {
          final index = _users.indexWhere((u) => u.id == userId);
          if (index != -1) {
            _users[index].isOnline = (status == 'online');
          }
        });
      }
    });

    // 전역 메시지 알림 (어떤 화면에 있든 동작)

  }

  Future<void> _fetchUsers() async {
    final serverUrl = ConfigService.to.serverUrl;
    final response = await http.get(Uri.parse('$serverUrl/api/users'));
    if (response.statusCode == 200) {
      final List data = jsonDecode(response.body);
      setState(() {
        _users = data.map((u) => User.fromJson(u)).where((u) => u.id != widget.currentUser.id).toList();
        // 온라인 사용자 우선 정렬
        _users.sort((a, b) {
          if (a.isOnline && !b.isOnline) return -1;
          if (!a.isOnline && b.isOnline) return 1;
          return a.username.compareTo(b.username);
        });
      });
    }
  }

  Future<void> _startChat(User targetUser) async {
    try {
      print('채팅 시작 요청: userId1=${widget.currentUser.id}, userId2=${targetUser.id}');
      
      final serverUrl = ConfigService.to.serverUrl;
      final response = await http.post(
        Uri.parse('$serverUrl/api/rooms/private'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId1': widget.currentUser.id,
          'userId2': targetUser.id,
        }),
      );

      print('응답 상태 코드: ${response.statusCode}');
      print('응답 본문: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final room = data['room'];
        final roomId = room['id'];
        
        print('채팅방 생성/조회 성공: roomId=$roomId');
        
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                currentUser: widget.currentUser,
                targetUser: targetUser,
                roomId: roomId,
                roomName: targetUser.username,
                isGroup: false,
              ),
            ),
          );
        }
      } else {
        print('채팅방 생성 실패: ${response.statusCode}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('채팅방 생성 실패 (${response.statusCode})')),
          );
        }
      }
    } catch (e) {
      print('채팅 시작 오류: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류 발생: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? null : Colors.white,
      appBar: AppBar(
        title: const Text('친구'),
        backgroundColor: isDark ? Theme.of(context).appBarTheme.backgroundColor : Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          // 검색창
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
              decoration: InputDecoration(
                hintText: '친구 검색',
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: isDark ? Colors.grey[800] : Colors.grey[100],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ),
          ),
          // 내 프로필 카드
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark ? Colors.indigo.withOpacity(0.2) : Colors.purple[50],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.indigo[600],
                  child: const Icon(Icons.person, size: 32, color: Colors.white),
                ),
                const SizedBox(width: 16),
                Text(
                  widget.currentUser.username,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 친구 목록 헤더
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  '친구 ${_filteredUsers.length}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 친구 목록
          Expanded(
            child: _filteredUsers.isEmpty
                ? Center(child: Text(_searchQuery.isEmpty ? '친구가 없습니다' : '검색 결과가 없습니다'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredUsers.length,
                    itemBuilder: (context, index) {
                      final user = _filteredUsers[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(vertical: 4),
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundColor: isDark ? Colors.grey[700] : Colors.grey[300],
                                child: const Icon(Icons.person, color: Colors.white),
                              ),
                              if (user.isOnline)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: Colors.green,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 2),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          title: Text(
                            user.username,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            user.isOnline ? '온라인' : '오프라인',
                            style: TextStyle(
                              fontSize: 13,
                              color: user.isOnline ? Colors.green : Colors.grey,
                            ),
                          ),
                          onTap: () => _startChat(user),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateGroupDialog,
        backgroundColor: Colors.purple[100],
        child: Icon(Icons.add, color: Colors.indigo[600]),
      ),
    );
  }

  // 그룹 생성 다이얼로그 표시
  void _showCreateGroupDialog() {
    final TextEditingController groupNameController = TextEditingController();
    final List<User> selectedUsers = [widget.currentUser]; // 본인은 기본 포함
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('그룹 만들기'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 그룹 이름 입력
                  TextField(
                    controller: groupNameController,
                    decoration: InputDecoration(
                      labelText: '그룹 이름',
                      hintText: '그룹 이름을 입력하세요',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 멤버 수 표시
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '멤버 ${selectedUsers.length}명',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 친구 목록 (체크박스)
                  Flexible(
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          // 본인 (체크 불가)
                          ListTile(
                            leading: const CircleAvatar(
                              child: Icon(Icons.person),
                            ),
                            title: Text('나 (${widget.currentUser.username})'),
                            trailing: const Icon(Icons.check_circle, color: Colors.green),
                          ),
                          const Divider(),
                          // 다른 친구들
                          ..._users.map((user) {
                            final isSelected = selectedUsers.any((u) => u.id == user.id);
                            return CheckboxListTile(
                              value: isSelected,
                              onChanged: (bool? value) {
                                setState(() {
                                  if (value == true) {
                                    selectedUsers.add(user);
                                  } else {
                                    selectedUsers.removeWhere((u) => u.id == user.id);
                                  }
                                });
                              },
                              title: Text(user.username),
                              subtitle: Text(user.isOnline ? '온라인' : '오프라인'),
                              secondary: CircleAvatar(
                                backgroundColor: Colors.grey[300],
                                child: const Icon(Icons.person, color: Colors.white),
                              ),
                            );
                          }).toList(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              ElevatedButton(
                onPressed: selectedUsers.length < 2
                    ? null
                    : () async {
                        final groupName = groupNameController.text.trim();
                        if (groupName.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('그룹 이름을 입력하세요')),
                          );
                          return;
                        }
                        
                        Navigator.pop(context);
                        await _createGroup(groupName, selectedUsers);
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo[600],
                  foregroundColor: Colors.white,
                ),
                child: const Text('그룹 생성'),
              ),
            ],
          );
        },
      ),
    );
  }

  // 그룹 생성 API 호출
  Future<void> _createGroup(String groupName, List<User> members) async {
    final memberIds = members.map((u) => u.id).toList();
    
    try {
      final serverUrl = ConfigService.to.serverUrl;
      final response = await http.post(
        Uri.parse('$serverUrl/api/rooms/group'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'groupName': groupName,
          'memberIds': memberIds,
        }),
      );
      
      if (response.statusCode == 201) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('그룹 "$groupName"이(가) 생성되었습니다')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('그룹 생성 실패')),
          );
        }
      }
    } catch (e) {
      print('[Error] 그룹 생성 오류: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('서버 통신 오류')),
        );
      }
    }
  }

  @override
  void dispose() {
    socketService.socket?.off('user_status');
    super.dispose();
  }
}

// --- Chats Tab ---
class ChatsTab extends StatefulWidget {
  final User currentUser;
  const ChatsTab({super.key, required this.currentUser});

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  List<ChatRoom> _chatRooms = [];
  ChatRoom? _globalChatRoom;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadChatRooms();
    _setupSocketListeners();
  }

  void _setupSocketListeners() {
    socketService.socket?.on('room_updated', _onSocketEvent);
    socketService.socket?.on('receive_message', _onSocketEvent);
    socketService.socket?.on('group_created', _onSocketEvent); // 그룹 생성 이벤트
  }

  void _onSocketEvent(dynamic data) {
    if (mounted) _loadChatRooms();
  }

  @override
  void dispose() {
    socketService.socket?.off('room_updated', _onSocketEvent);
    socketService.socket?.off('receive_message', _onSocketEvent);
    socketService.socket?.off('group_created', _onSocketEvent);
    super.dispose();
  }


  Future<void> _loadChatRooms() async {
    setState(() => _isLoading = true);
    
    try {
      final serverUrl = ConfigService.to.serverUrl;
      final response = await http.get(
        Uri.parse('$serverUrl/api/rooms/my/${widget.currentUser.id}'),
      );

        if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        final allRooms = data.map((json) => ChatRoom.fromJson(json)).toList();
        
        setState(() {
          // 전체 대화방 분리 (roomType == 'public' 또는 name == 'global')
          try {
            _globalChatRoom = allRooms.firstWhere(
              (r) => r.roomType == 'public' || r.name == 'global',
            );
            // 목록에서는 제거
            _chatRooms = allRooms.where((r) => r.id != _globalChatRoom!.id).toList();
          } catch (e) {
            _globalChatRoom = null;
            _chatRooms = allRooms;
          }
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      print('채팅방 목록 로드 오류: $e');
      setState(() => _isLoading = false);
    }
  }

  String _formatTime(String? timestamp) {
    if (timestamp == null) return '';
    
    try {
      final dateTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final diff = now.difference(dateTime);
      
      if (diff.inDays > 0) {
        return '${dateTime.month}/${dateTime.day}';
      } else {
        return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
      }
    } catch (e) {
      return '';
    }
  }

  void _openChatRoom(ChatRoom room) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => ChatScreen(
          currentUser: widget.currentUser,
          roomId: room.id,
          roomName: room.name,
          isGroup: room.isGroup,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // [카카오톡 스타일] 오른쪽에서 왼쪽으로 슬라이드
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          
          var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          var offsetAnimation = animation.drive(tween);
          
          return SlideTransition(
            position: offsetAnimation,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    ).then((_) => _loadChatRooms());
  }

  // 채팅방 나가기 메뉴 표시 (Windows 우클릭, Mobile 롱프레스)
  void _showLeaveMenu(BuildContext context, TapDownDetails? details, ChatRoom room) {
    if (details == null) return;
    
    final position = RelativeRect.fromLTRB(
      details.globalPosition.dx,
      details.globalPosition.dy,
      details.globalPosition.dx,
      details.globalPosition.dy,
    );

    showMenu(
      context: context,
      position: position,
      items: [
        const PopupMenuItem(
          value: 'leave',
          child: Row(
            children: [
              Icon(Icons.exit_to_app, color: Colors.red, size: 20),
              SizedBox(width: 8),
              Text('나가기', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'leave') {
        _confirmLeave(room);
      }
    });
  }

  // 나가기 확인 다이얼로그
  void _confirmLeave(ChatRoom room) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('채팅방 나가기'),
        content: const Text('채팅방을 나가시겠습니까?\n대화 내용이 모두 삭제됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _leaveChatRoom(room.id);
            },
            child: const Text('나가기', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // 방 나가기 API 호출
  Future<void> _leaveChatRoom(int roomId) async {
    try {
      final serverUrl = ConfigService.to.serverUrl;
      final response = await http.post(
        Uri.parse('$serverUrl/api/rooms/leave'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'roomId': roomId,
          'userId': widget.currentUser.id,
        }),
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('채팅방을 나갔습니다.')),
          );
          _loadChatRooms(); // 목록 새로고침
        }
      } else {
        print('[API] 방 나가기 실패: ${response.body}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('채팅방 나가기 실패')),
          );
        }
      }
    } catch (e) {
      print('[API] 방 나가기 오류: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류 발생: $e')),
        );
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? null : Colors.white,
      appBar: AppBar(
        title: const Text('대화목록'),
        backgroundColor: isDark ? Theme.of(context).appBarTheme.backgroundColor : Colors.white,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadChatRooms,
              child: ListView(
                children: [
                  // 전체 대화방 섹션
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '전체 대화방',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  // 전체 대화방 아이템 (데이터 바인딩)
                  if (_globalChatRoom != null)
                    ListTile(
                      leading: CircleAvatar(
                        radius: 24,
                        backgroundColor: Colors.indigo[600],
                        child: const Icon(Icons.star, color: Colors.white, size: 24),
                      ),
                      title: const Text(
                        '전체 대화방',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        _globalChatRoom!.lastMessage ?? '전체 공지 및 대화',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[600],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            _formatTime(_globalChatRoom!.lastMessageTime),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[500],
                            ),
                          ),
                          if (_globalChatRoom!.unreadCount > 0) ...[
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                _globalChatRoom!.unreadCount.toString(),
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ],
                      ),
                      onTap: () => _openChatRoom(_globalChatRoom!),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('전체 대화방 로딩 중...', style: TextStyle(color: Colors.grey)),
                    ),
                  const SizedBox(height: 16),
                  // 일반 대화방 섹션
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      '일반 대화방',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  // 일반 대화방 목록
                  if (_chatRooms.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          '채팅방이 없습니다',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[400],
                          ),
                        ),
                      ),
                    )
                  else
                    ..._chatRooms.map((room) {
                      return GestureDetector(
                        onSecondaryTapDown: (details) => _showLeaveMenu(context, details, room), // Windows 우클릭
                        onLongPressStart: (details) => _showLeaveMenu(context, TapDownDetails(globalPosition: details.globalPosition), room), // Mobile 롱프레스
                        child: ListTile(
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundColor: room.isGroup 
                                    ? (isDark ? Colors.indigo[900] : Colors.indigo[200]) 
                                    : (isDark ? Colors.grey[700] : Colors.grey[300]),
                                child: Icon(
                                  room.isGroup ? Icons.group : Icons.person,
                                  color: Colors.white,
                                ),
                              ),
                              if (!room.isGroup && room.isOnline)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: Colors.green,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 2),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          title: Text(
                            room.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            room.lastMessage ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 13,
                            ),
                          ),
                          trailing: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _formatTime(room.lastMessageTime),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[500],
                                ),
                              ),
                              if (room.unreadCount > 0) ...[
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    room.unreadCount > 99 ? '99+' : '${room.unreadCount}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          onTap: () => _openChatRoom(room),
                        ),
                      );
                    }).toList(),
                ],
              ),
            ),
    );
  }
}

// --- Settings Tab ---
class SettingsTab extends StatefulWidget {
  final User currentUser;
  const SettingsTab({super.key, required this.currentUser});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController();
  String _appVersion = '';
  int _buildNumber = 0;

  Future<void> _initVersion() async {
    final info = await PackageInfo.fromPlatform(); // package_info_plus
    if (mounted) {
      setState(() {
        _appVersion = info.version;
        _buildNumber = int.tryParse(info.buildNumber) ?? 0;
      });
    }
  }

  Future<void> _checkUpdate() async {
    if (_appVersion.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('버전 정보를 불러오는 중입니다. 잠시 후 다시 시도해주세요.')),
      );
      return;
    }

    try {
      final updateInfo = await UpdateService.to.checkForUpdate(_appVersion, _buildNumber);
      if (!mounted) return;

      if (updateInfo == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('현재 최신 버전을 사용 중입니다.')),
        );
        return;
      }

      final String serverVersion = updateInfo['version'] ?? '알 수 없음';
      final int serverBuild = updateInfo['buildNumber'] ?? 0;
      final String buildNumberStr = serverBuild.toString();

      final List<String> changelog = updateInfo['changelog'] != null 
          ? (updateInfo['changelog'] as List<dynamic>).cast<String>()
          : ['업데이트 정보가 없습니다.'];
      
      String? downloadUrl;
      if (Platform.isWindows) {
        downloadUrl = updateInfo['downloadUrl']?['windows'];
      } else if (Platform.isAndroid) {
        downloadUrl = updateInfo['downloadUrl']?['android'];
      }
      
      if (downloadUrl == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('해당 플랫폼의 다운로드 주소를 찾을 수 없습니다.')),
        );
        return;
      }

      String finalDownloadUrl = downloadUrl;
      if (finalDownloadUrl.startsWith('/')) {
        final serverUrl = ConfigService.to.serverUrl;
        finalDownloadUrl = '$serverUrl$finalDownloadUrl';
      }

      // [Fix] 공통 다이얼로그 함수 사용
      if (mounted) {
        _showUpdateDialog(
          context, 
          updateInfo, 
          currentVersion: _appVersion,
          currentBuild: _buildNumber
        );
      }
    } catch (e) {
      print('[Update Error] $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('업데이트 확인 중 오류가 발생했습니다: $e')),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _initVersion();
  }

  Future<void> _loadConfig() async {
    final serverUrl = ConfigService.to.serverUrl;
    final uri = Uri.tryParse(serverUrl);
    if (uri != null) {
      _ipController.text = uri.host;
      _portController.text = uri.port.toString();
    } else {
      _ipController.text = '192.168.0.43';
      _portController.text = '3001';
    }
  }

  Future<void> _saveConfig() async {
    final ip = _ipController.text.trim();
    final port = _portController.text.trim();
    
    if (ip.isEmpty || port.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IP와 포트를 입력해주세요')),
      );
      return;
    }

    final newUrl = 'http://$ip:$port';
    
    // 로딩 인디케이터 표시
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('saved_username');
      final password = prefs.getString('saved_password');

      // 서버 주소 먼저 업데이트
      await ConfigService.to.setServerUrl(newUrl);

      if (username == null || password == null) {
        // 저장된 정보가 없으면 로그인 페이지로 이동
        if (mounted) {
          Navigator.pop(context); // 로딩 닫기
          socketService.dispose();
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => const LoginScreen()),
            (route) => false,
          );
        }
        return;
      }

      // 새 서버로 로그인 시도
      final macAddress = await DeviceService.to.getDeviceId();
      final deviceInfo = await DeviceService.to.getDetailedInfo();

      final response = await http.post(
        Uri.parse('$newUrl/api/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'macAddress': macAddress,
          'osInfo': deviceInfo['osInfo'],
          'deviceType': deviceInfo['deviceType'],
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final user = User.fromJson(data['user']);
        
        ConfigService.to.currentUser = user;
        await prefs.setInt('current_user_id', user.id);
        
        // 소켓 재초기화
        socketService.dispose();
        socketService.init(user.id);

        if (mounted) {
          Navigator.pop(context); // 로딩 닫기
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('서버 설정 변경 및 자동 재로그인에 성공했습니다.')),
          );
          
          // 앱 상태 초기화를 위해 MainScreen 재진입
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => MainScreen(currentUser: user)),
            (route) => false,
          );
        }
      } else {
        throw Exception('Login failed on new server');
      }
    } catch (e) {
      print('[Settings] Auto-relogin failed: $e');
      if (mounted) {
        Navigator.pop(context); // 로딩 닫기
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('새 서버 연결 실패 또는 인증 정보가 올바르지 않습니다. 로그인 화면으로 이동합니다.')),
        );
        socketService.dispose();
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const LoginScreen()),
          (route) => false,
        );
      }
    }
  }

  void _showChangePasswordDialog() {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('비밀번호 변경'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: currentPasswordController,
              decoration: const InputDecoration(labelText: '현재 비밀번호'),
              obscureText: true,
            ),
            TextField(
              controller: newPasswordController,
              decoration: const InputDecoration(labelText: '새 비밀번호'),
              obscureText: true,
            ),
            TextField(
              controller: confirmPasswordController,
              decoration: const InputDecoration(labelText: '새 비밀번호 확인'),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () async {
              if (newPasswordController.text != confirmPasswordController.text) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('새 비밀번호가 일치하지 않습니다')),
                );
                return;
              }
              if (newPasswordController.text.isEmpty) {
                 ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('새 비밀번호를 입력해주세요')),
                );
                return;
              }

              try {
                final serverUrl = ConfigService.to.serverUrl;
                final response = await http.post(
                  Uri.parse('$serverUrl/api/users/change-password'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'userId': widget.currentUser.id,
                    'currentPassword': currentPasswordController.text,
                    'newPassword': newPasswordController.text,
                  }),
                );

                if (response.statusCode == 200) {
                  if (mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('비밀번호가 변경되었습니다.')),
                    );
                  }
                } else {
                  if (mounted) {
                    final error = jsonDecode(response.body)['error'];
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(error ?? '비밀번호 변경 실패')),
                    );
                  }
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('서버 통신 오류')),
                  );
                }
              }
            },
            child: const Text('변경'),
          ),
        ],
      ),
    );
  }

  void _exitApp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('앱 완전 종료'),
        content: const Text('백그라운드 서비스를 중지하고 앱을 완전히 종료하시겠습니까?\n종료 후에는 다시 실행할 때까지 메시지를 수신할 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () async {
              // 백그라운드 서비스 중지 요청
              FlutterBackgroundService().invoke('stopService');
              // 잠시 대기 후 앱 종료
              await Future.delayed(const Duration(milliseconds: 500));
              if (Platform.isAndroid) {
                SystemNavigator.pop();
              } else {
                exit(0);
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red[600],
              foregroundColor: Colors.white,
            ),
            child: const Text('종료'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: isDark ? null : Colors.grey[50], // 다크 모드는 테마 따름
      appBar: AppBar(
        title: const Text('설정'),
        backgroundColor: isDark ? Theme.of(context).appBarTheme.backgroundColor : Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 내 정보 섹션
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark ? Colors.indigo.withOpacity(0.2) : Colors.purple[50],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '내 정보',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'ID: ${widget.currentUser.username}',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _showChangePasswordDialog,
                        icon: const Icon(Icons.lock, size: 18),
                        label: const Text('비밀번호 변경'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.indigo[600],
                          side: BorderSide(color: Colors.indigo[200]!),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.remove('saved_username');
                          await prefs.remove('saved_password');
                          
                          if (context.mounted) {
                            socketService.dispose();
                            Navigator.pushAndRemoveUntil(
                              context,
                              MaterialPageRoute(builder: (context) => const LoginScreen()),
                              (route) => false,
                            );
                          }
                        },
                        icon: const Icon(Icons.logout, size: 18),
                        label: const Text('로그아웃'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red[600],
                          side: BorderSide(color: Colors.red[200]!),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 서버 연결 설정
          const Text(
            '서버 연결 설정',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? Theme.of(context).cardColor : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? Colors.grey[800]! : Colors.grey[300]!),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '서버 IP 주소',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[700],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _ipController,
                  decoration: InputDecoration(
                    hintText: '192.168.0.43',
                    filled: true,
                    fillColor: isDark ? Colors.grey[800] : Colors.grey[50],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey[300]!),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey[300]!),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '포트 (Port)',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[700],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _portController,
                  decoration: InputDecoration(
                    hintText: '8080',
                    filled: true,
                    fillColor: isDark ? Colors.grey[800] : Colors.grey[50],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey[300]!),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey[300]!),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saveConfig, // 공통 저장 함수 호출 (v2.5.19 재로그인 포함)
                child: const Text('서버 설정 저장'),
              ),
            ),
          ),
          const SizedBox(height: 24),
          // 알림 설정
          const Text(
            '알림 설정',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? Theme.of(context).cardColor : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? Colors.grey[800]! : Colors.grey[300]!),
            ),
            child: SwitchListTile(
              title: const Text('알림/진동'),
              subtitle: const Text('메시지 수신 시 알림음 및 진동'),
              value: ConfigService.to.isSoundEnabled,
              onChanged: (value) async {
                await ConfigService.to.setSoundEnabled(value);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(value ? '알림 사운드가 활성화되었습니다' : '알림 사운드가 비활성화되었습니다')),
                );
              },
              activeColor: Colors.indigo[600],
            ),
          ),
          const SizedBox(height: 12),
          // 다크 모드
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? Theme.of(context).cardColor : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? Colors.grey[800]! : Colors.grey[300]!),
            ),
            child: SwitchListTile(
              title: const Text('다크 모드 (Creative Dark)'),
              value: ConfigService.to.isDarkMode,
              onChanged: (value) async {
                await ConfigService.to.setDarkMode(value);
                setState(() {});
              },
              activeColor: Colors.indigo[600],
            ),
          ),
          const SizedBox(height: 24),
          
          // 앱 정보 및 업데이트
          const Text(
            '앱 정보',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: isDark ? Theme.of(context).cardColor : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? Colors.grey[800]! : Colors.grey[300]!),
            ),
            child: Column(
              children: [
                ListTile(
                  title: const Text('현재 버전'),
                  trailing: Text(
                    'v$_appVersion',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('배너 알림 테스트 (디버그)'),
                  subtitle: const Text('수동으로 인앱 배너를 띄워 UI를 확인합니다.'),
                  trailing: const Icon(Icons.bug_report, size: 16),
                  onTap: () {
                    NotificationService.to.onInAppNotification?.call(
                      '테스트 알림', 
                      '배너 출력 기능이 정상적으로 작동합니다!', 
                      jsonEncode({'roomId': 0, 'payload': 'test'})
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('업데이트 확인'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                  onTap: _checkUpdate,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 저장 및 연결 버튼
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _saveConfig,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo[600],
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.refresh, size: 20),
                  SizedBox(width: 8),
                  Text(
                    '저장 및 연결',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 앱 완전 종료 버튼
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton(
              onPressed: _exitApp,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red[700],
                side: BorderSide(color: Colors.red[200]!),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.power_settings_new, size: 20),
                  SizedBox(width: 8),
                  Text(
                    '앱 완전 종료',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }
}

// --- Chat Screen ---
class ChatScreen extends StatefulWidget {
  final User currentUser;
  final User? targetUser; // 1:1 채팅일 경우 상대방 정보
  final int roomId;
  final String roomName; // 채팅방 이름
  final bool isGroup; // 그룹 채팅 여부

  const ChatScreen({
    super.key,
    required this.currentUser,
    this.targetUser,
    required this.roomId,
    required this.roomName,
    required this.isGroup,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver, TickerProviderStateMixin { // [Fix] 애니메이션을 위해 Ticker 추가
  bool _isConnected = false;
  final List<ChatMessage> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  final FocusNode _listenerFocusNode = FocusNode(); // [Added] 키보드 리스너용 지속 포커스 노드
  
  final ImagePicker _picker = ImagePicker(); // [Added] 이미지 피커 인스턴스
  bool _isUploading = false; // [Added] 업로드 상태 관리
  
  // [Added] 알림 배지 점멸 애니메이션
  late AnimationController _badgeBlinkController;
  
  // [카카오톡 스타일] 페이지네이션 변수
  int _currentPage = 0;
  final int _messagesPerPage = 20; // 한 번에 로드할 메시지 수
  bool _isLoadingMore = false;
  bool _hasMoreMessages = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 생명주기 감지 등록
    // 현재 보고 있는 방 ID 설정 (알림 방지)
    AppState.to.setRoomId(widget.roomId);
    _saveCurrentRoomId(widget.roomId); // [Restored]
    _fetchHistory(); // [Restored] 최근 메시지만 먼저 로드
    
    _initSocket();
    
    // [카카오톡 스타일] 스크롤 리스너 추가 (위로 스크롤 시 과거 메시지 로드)
    _scrollController.addListener(_onScroll);
    
    // [Added] 배지 점멸 애니메이션 초기화
    _badgeBlinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    
    // [Added] 진입 시 한 번 더 안읽은 수 최신화
    AppState.to.refreshTotalUnread();
    
    // 진입 시 즉시 mark_as_read 전송 및 포커스 요청
    // [Fix] 진입 시 자동 키보드 팝업 방지 (사용자가 입력창 터치 시에만 올라오도록)
    // WidgetsBinding.instance.addPostFrameCallback((_) {
    //   _messageFocusNode.requestFocus();
    // });
  }
  
  // [카카오톡 스타일] 스크롤 이벤트 핸들러
  void _onScroll() {
    // 스크롤이 최상단 근처에 도달하면 과거 메시지 로드
    if (_scrollController.position.pixels <= 100 && !_isLoadingMore && _hasMoreMessages) {
      _loadMoreMessages();
    }
  }
  
  // [카카오톡 스타일] 과거 메시지 추가 로드
  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMoreMessages) return;
    
    setState(() {
      _isLoadingMore = true;
    });
    
    _currentPage++;
    await _fetchHistory(page: _currentPage, append: true);
    
    setState(() {
      _isLoadingMore = false;
    });
  }

  Future<void> _saveCurrentRoomId(int roomId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('current_room_id', roomId);
    AppState.to.setRoomId(roomId); // AppState 동기화
    print('[ChatScreen] Saved currentRoomId: $roomId');
  }

  Future<void> _clearCurrentRoomId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_room_id');
    AppState.to.setRoomId(null); // AppState 동기화
    print('[ChatScreen] Cleared currentRoomId');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('📱 Lifecycle Changed: $state');
    // inactive(잠금화면/알림센터) 또는 paused(백그라운드) 상태일 때 방 ID 해제
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      AppState.to.setRoomId(null);
      print(' -> currentRoomId cleared (Background/Inactive)');
    } else if (state == AppLifecycleState.resumed) {
      // 앱이 다시 활성화되면 현재 방 ID 복구 및 읽음 처리
      AppState.to.setRoomId(widget.roomId);
      socketService.socket?.emit('mark_as_read', {
          'roomId': widget.roomId,
          'userId': widget.currentUser.id
      });
      
      // [Added] 읽음 처리 후 전체 안읽은 수 갱신
      AppState.to.refreshTotalUnread();
      
      // [Fix] Resume 시 입력창 포커스 재요청
      _messageFocusNode.requestFocus();
      
      print(' -> currentRoomId restored, mark_as_read sent & focus requested');
    }
  }

  void _initSocket() {
    _isConnected = socketService.isConnected.value;
    socketService.isConnected.addListener(_onSocketChanged);
    
    // 방 참여
    socketService.joinRoom(widget.roomId);
    
    // [Fix] 방 입장 시 읽음 처리 (알림 배지를 보고 들어온 경우)
    socketService.socket?.emit('mark_as_read', {
      'roomId': widget.roomId,
      'userId': widget.currentUser.id
    });
    print('[Socket] 방 입장 시 mark_as_read 전송: roomId=${widget.roomId}');
    
    // 메시지 수신 핸들러 등록
    socketService.socket?.on('receive_message', _onReceiveMessage);
    
    // 읽음 알림 수신 핸들러 등록
    socketService.socket?.on('messages_read', _onMessagesRead);

    // [v2.5.19] 공지 수정/삭제 실시간 핸들러
    socketService.socket?.on('notice_updated', _onNoticeUpdated);
    socketService.socket?.on('notice_deleted', _onNoticeDeleted);
  }

  void _onNoticeUpdated(dynamic data) {
    if (!mounted) return;
    final id = data['id'];
    final content = data['content'];

    setState(() {
      for (var msg in _messages) {
        if (msg.type == 'notice' && msg.id == id) {
          msg.content = content;
        }
      }
    });
    print('[Socket] 공지 수정 반영: ID $id');
  }

  void _onNoticeDeleted(dynamic data) {
    if (!mounted) return;
    final id = data['id'];

    setState(() {
      _messages.removeWhere((msg) => msg.type == 'notice' && msg.id == id);
    });
    print('[Socket] 공지 삭제 반영: ID $id');
  }

  void _onSocketChanged() {
    if (mounted) {
        setState(() => _isConnected = socketService.isConnected.value);
        // [Fix] 소켓 재연결 시 방에 다시 참여해야 이벤트를 받을 수 있음
        if (_isConnected) {
            print('[Socket] 재연결 감지 -> 방 재참여 시도: ${widget.roomId}');
            socketService.joinRoom(widget.roomId);
            
            // [Fix] 재연결 시에도 즉시 읽음 처리 및 포커스
            socketService.socket?.emit('mark_as_read', {
              'roomId': widget.roomId,
              'userId': widget.currentUser.id
            });
            _messageFocusNode.requestFocus();
            
             ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('서버 재연결됨. 방 재참여 완료.'), duration: Duration(milliseconds: 1000)),
            );
        }
    }
  }

  void _onMessagesRead(dynamic data) {
    final eventRoomId = data['roomId'] ?? data['room_id'];
    _addLog('Evt: Read $eventRoomId');
    
    if (mounted && eventRoomId.toString() == widget.roomId.toString()) {
      _addLog('Fetch Trigger');
      
      // [Fix] 로컬 상태 즉시 업데이트 (반응성 향상)
      final readerId = data['userId'];
      setState(() {
        for (var i = 0; i < _messages.length; i++) {
          final msg = _messages[i];
          // 내가 보낸 메시지거나, 다른 사람이 보낸 메시지여도 읽은 사람이 msg 발신자가 아니면 count 감소
          if (msg.readCount > 0 && readerId != msg.senderId) {
             _messages[i] = msg.copyWith(readCount: msg.readCount - 1);
          }
        }
      });

      // 데이터 정합성을 위해 백그라운드 페치
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _fetchHistory();
      });
    } else {
      _addLog('Skip: $eventRoomId != ${widget.roomId}');
    }
  }

  void _onReceiveMessage(dynamic data) {
    _addLog('Evt: Recv ${data['id']}');
    try {
      final newMessage = ChatMessage.fromJson(data);
      print('[Socket] 메시지 수신: $data');

      // 현재 보고 있는 방의 메시지인지 확인 (중요!)
      final msgRoomId = data['roomId'] ?? data['room_id'];
      if (msgRoomId != null && msgRoomId.toString() != widget.roomId.toString()) {
        print('[Socket] 다른 방 메시지($msgRoomId) 무시 (현재: ${widget.roomId})');
        return;
      }
      
      if (mounted) {
        setState(() {
          // 낙관적 업데이트 대비 중복 체크 강화
          bool alreadyExists = _messages.any((m) => m.id != -1 && m.id == newMessage.id);
          if (!alreadyExists) {
            // 보낸 메시지(temp)가 있다면 교체, 아니면 추가
            final index = _messages.indexWhere((m) => m.id == -1 && m.content == newMessage.content);
            if (index != -1) {
              _messages[index] = newMessage;
            } else {
              _messages.add(newMessage);
            }
          }
        });
        _scrollToBottom();
        
        // [Fix] 화면이 mounted 상태이면(보고 있으면) 즉시 읽음 처리 전송
        // (기존 lifecycleState 체크가 모바일 환경에서 불안정할 수 있어 mounted 체크로 대체)
        socketService.socket?.emit('mark_as_read', {
            'roomId': widget.roomId,
            'userId': widget.currentUser.id
        });
        
        // [Added] 수신 후 읽음 처리 되었으므로 전체 수 갱신 필요할 수 있음 (보통 현재 방은 영향 없으나 안정성 위해)
        AppState.to.refreshTotalUnread();
        
        print('[Socket] Auto mark_as_read triggered (mounted=true)');
      }
    } catch (e) {
      print('[Socket Error] receive_message 파싱 실패: $e');
      _addLog('Recv Err: $e');
    }
  }

  Future<void> _fetchHistory({int page = 0, bool append = false, int retryCount = 0}) async {
    _addLog('Fetch Start (Page: $page)');
    final serverUrl = ConfigService.to.serverUrl;
    
    // [카카오톡 스타일] 페이지네이션 지원
    // page=0: 최근 메시지만 로드 (초기)
    // page>0: 과거 메시지 추가 로드
    final offset = page * _messagesPerPage;
    final url = '$serverUrl/api/rooms/${widget.roomId}/messages?userId=${widget.currentUser.id}&limit=$_messagesPerPage&offset=$offset&t=${DateTime.now().millisecondsSinceEpoch}';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        _addLog('Fetch OK (${data.length})');
        
        if (data.length < _messagesPerPage) {
          _hasMoreMessages = false; // 더 이상 로드할 메시지 없음
        }
        
        if (mounted) {
            setState(() {
                if (append) {
                  // [카카오톡 스타일] 과거 메시지를 리스트 앞에 추가
                  final oldMessages = data.map((m) => ChatMessage.fromJson(m)).toList();
                  _messages.insertAll(0, oldMessages);
                } else {
                  // [카카오톡 스타일] 초기 로드: 최근 메시지만 표시
                  _messages.clear();
                  _messages.addAll(data.map((m) => ChatMessage.fromJson(m)).toList());
                }
                
                // [Debug] 마지막 내 메시지의 read_count 로그
                try {
                    final myLastMsg = _messages.lastWhere((m) => m.senderId == widget.currentUser.id);
                    _addLog('My: ${myLastMsg.content.substring(0, 5)}.. RC:${myLastMsg.readCount}');
                } catch (_) {}
            });
            
            if (!append) {
              // [카카오톡 스타일] 초기 로드 시에만 즉시 하단으로 스크롤 (애니메이션 없음)
              _scrollToBottom(instant: true);
            }
            
            // [Fix] UI 갱신이 안 되는 경우를 대비해 강제 갱신
            Future.delayed(const Duration(milliseconds: 100), () {
              if (mounted) setState(() {});
              if (!append) {
                // 한번 더 스크롤 (이미지 로딩 등으로 인한 높이 변화 대응)
                _scrollToBottom(instant: true);
              }
            });
        }
      } else {
          // 실패 시 재시도 (최대 2회)
          if (retryCount < 2) {
              Future.delayed(const Duration(milliseconds: 500), () => _fetchHistory(retryCount: retryCount + 1));
          }
      }
    } catch (e) {
      _addLog('Fetch Error: $e');
    }
  }

  // [Debug] 로그 리스트
  final List<String> _debugLogs = [];
  void _addLog(String log) {
    if (!mounted) return;
    setState(() {
      _debugLogs.insert(0, '[${DateTime.now().second}:${DateTime.now().millisecond}] $log');
      if (_debugLogs.length > 5) _debugLogs.removeLast();
    });
  }

  void _sendMessage() {
    if (_messageController.text.isEmpty) return;
    final content = _messageController.text;
    _messageController.clear();

    final messageData = {
      'roomId': widget.roomId,
      'content': content,
      'senderId': widget.currentUser.id, // 명시적 작성
      'type': 'text',
    };

    // 낙관적 업데이트: 서버 응답 전 즉시 화면 표시
    final tempMsg = ChatMessage(
      id: -1, // 임시 ID
      senderId: widget.currentUser.id,
      content: content,
      type: 'text',
      readCount: 0, // 내가 보낸 메시지는 이미 읽음
      createdAt: DateTime.now().toIso8601String(),
    );

    setState(() {
      _messages.add(tempMsg);
    });
    _scrollToBottom();

    socketService.sendMessage(messageData);
    
    // 메시지 전송 후 입력창에 포커스 유지
    _messageFocusNode.requestFocus();
  }

  // [Added] 사진 촬영/선택 로직
  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        imageQuality: 70, // 용량 최적화
      );

      if (image != null) {
        String? customFilename;
        if (source == ImageSource.camera) {
          // cschat_yyyyMMdd_HHmmss.jpg 형식 생성
          final String timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
          customFilename = 'cschat_$timestamp.jpg';
        }
        await _uploadAndSendFile(image.path, 'image', customFilename: customFilename);
      }
    } catch (e) {
      print('[ChatScreen] 사진 선택 오류: $e');
    }
  }

  // [Added] 동영상 촬영 로직
  Future<void> _pickVideo() async {
    try {
      final XFile? video = await _picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(minutes: 10),
      );

      if (video != null) {
        // cschat_video_yyyyMMdd_HHmmss.mp4 형식 생성
        final String timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
        final String customFilename = 'cschat_video_$timestamp.mp4';
        
        await _uploadAndSendFile(video.path, 'video', customFilename: customFilename);
      }
    } catch (e) {
      print('[ChatScreen] 동영상 촬영 오류: $e');
    }
  }

  // [Added] 일반 파일 선택 로직
  Future<void> _pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles();

      if (result != null && result.files.single.path != null) {
        await _uploadAndSendFile(result.files.single.path!, 'file');
      }
    } catch (e) {
      print('[ChatScreen] 파일 선택 오류: $e');
    }
  }

  // [Added] 파일 업로드 및 메시지 전송 공통 로직
  Future<void> _uploadAndSendFile(String filePath, String type, {String? customFilename}) async {
    setState(() => _isUploading = true);
    
    try {
      final serverUrl = ConfigService.to.serverUrl;
      final request = http.MultipartRequest('POST', Uri.parse('$serverUrl/api/upload'));
      
      // [Fix] 파일명 깨짐 방지를 위해 필드로 별도 전송 (UTF-8 유지)
      // customFilename이 있으면 우선 사용 (카메라 촬영 등)
      request.fields['original_filename'] = customFilename ?? p.basename(filePath);
      request.files.add(await http.MultipartFile.fromPath('file', filePath));
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final fileUrl = data['fileUrl'];
        final filename = data['filename'];
        final thumbnailUrl = data['thumbnailUrl']; // [Added] 썸네일 수신

        // 소켓을 통해 파일 메시지 전송
        final messageData = {
          'roomId': widget.roomId,
          'content': filename, // 파일명을 내용으로 사용
          'fileUrl': fileUrl,
          'thumbnailUrl': thumbnailUrl, // [Added] 썸네일 포함
          'senderId': widget.currentUser.id,
          'type': type,
        };

        socketService.sendMessage(messageData);
        print('[ChatScreen] 파일 전송 완료: $fileUrl (Thumbnail: $thumbnailUrl)');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('파일 업로드에 실패했습니다.')),
        );
      }
    } catch (e) {
      print('[ChatScreen] 파일 전송 오류: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('파일 전송 중 오류가 발생했습니다.')),
      );
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  // [Added] 첨부 메뉴 표시
  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildAttachmentItem(
                    icon: Icons.camera_alt_rounded,
                    label: '카메라',
                    color: Colors.blue,
                    onTap: () {
                      Navigator.pop(context);
                      _pickImage(ImageSource.camera);
                    },
                  ),
                  _buildAttachmentItem(
                  icon: Icons.photo_library_rounded,
                  label: '갤러리',
                  color: Colors.purple,
                  onTap: () {
                    Navigator.pop(context);
                    _pickImage(ImageSource.gallery);
                  },
                ),
                _buildAttachmentItem(
                  icon: Icons.videocam_rounded,
                  label: '동영상',
                  color: Colors.redAccent,
                  onTap: () {
                    Navigator.pop(context);
                    _pickVideo();
                  },
                ),
                _buildAttachmentItem(
                  icon: Icons.insert_drive_file_rounded,
                  label: '파일',
                  color: Colors.orange,
                  onTap: () {
                    Navigator.pop(context);
                    _pickFile();
                  },
                ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  void _scrollToBottom({bool instant = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        if (instant) {
          // [카카오톡 스타일] 초기 로딩 시 애니메이션 없이 즉시 하단으로 이동
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        } else {
          // 일반 메시지 전송 시에는 부드럽게 스크롤
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  @override
  void dispose() {
    // 채팅방 나갈 때 방 ID 초기화
    AppState.to.setRoomId(null);
    _clearCurrentRoomId(); // SharedPreferences에서도 제거
    // 메시지 핸들러 해제 및 리스너 제거 (특정 핸들러만 제거하여 전역 알림 리스너 보존)
    socketService.socket?.off('receive_message', _onReceiveMessage);
    socketService.socket?.off('messages_read', _onMessagesRead);
    socketService.isConnected.removeListener(_onSocketChanged);
    WidgetsBinding.instance.removeObserver(this); // [Fix] 옵저버 해제 필수
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    _listenerFocusNode.dispose(); // [Fix] 리소스 해제
    _badgeBlinkController.dispose(); // [Added] 애니메이션 해제
    super.dispose();
  }

  Future<List<User>> _fetchParticipants() async {
    try {
      final serverUrl = ConfigService.to.serverUrl;
      final response = await http.get(Uri.parse('$serverUrl/api/rooms/${widget.roomId}/members'));
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((u) => User.fromJson(u)).toList();
      }
    } catch (e) {
      print('Failed to fetch participants: $e');
    }
    return [];
  }

  void _showParticipants() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('대화상대', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            SizedBox(
              height: 300,
              child: FutureBuilder<List<User>>(
                future: _fetchParticipants(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (!snapshot.hasData || snapshot.data!.isEmpty) {
                    return const Center(child: Text('참여자가 없습니다.'));
                  }
                  final users = snapshot.data!;
                  return ListView.builder(
                    itemCount: users.length,
                    itemBuilder: (context, index) {
                      final user = users[index];
                      final isMe = user.id == widget.currentUser.id;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isMe ? Colors.indigo : Colors.grey,
                          child: Text(user.username[0].toUpperCase(), style: const TextStyle(color: Colors.white)),
                        ),
                        title: Text(
                          user.username + (isMe ? ' (나)' : ''),
                          style: TextStyle(fontWeight: isMe ? FontWeight.bold : FontWeight.normal),
                        ),
                        trailing: user.isOnline 
                            ? Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle))
                            : null,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: widget.isGroup ? _showParticipants : null,
          child: MouseRegion(
            cursor: widget.isGroup ? SystemMouseCursors.click : SystemMouseCursors.basic,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.isGroup ? widget.roomName : '${widget.roomName}님과의 대화',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                // [Moved & Styled] 다른 방 안읽은 메시지 배지 (오른쪽 배치, 길쭉한 타원형 배지)
                ListenableBuilder(
                  listenable: AppState.to,
                  builder: (context, child) {
                    final count = AppState.to.totalUnreadCount;
                    if (count == 0) return const SizedBox();
                    
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 12),
                        FadeTransition(
                          opacity: _badgeBlinkController,
                          child: GestureDetector(
                            onTap: () {
                              // 아이콘 클릭 시 대화목록(메인화면)의 채팅탭(Index 1)으로 이동
                              AppState.to.setTabIndex(1);
                              
                              // [Fix] 로그인 페이지로 가지 않도록 MainScreen(루트)까지만 팝
                              Navigator.of(context).popUntil((route) => route.isFirst);
                            },
                            child: Container(
                              // [v2.5.20] 크기 2배 상향 및 길쭉한 둥근 사각형 (타원형) 디자인
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(30), // 길쭉한 둥근 사각형
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.withOpacity(0.5), 
                                    blurRadius: 8, 
                                    spreadRadius: 2
                                  )
                                ]
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.mail_outline, size: 24, color: Colors.white), // 아이콘 확대
                                  const SizedBox(width: 10),
                                  Text(
                                    '$count',
                                    style: const TextStyle(
                                      color: Colors.white, 
                                      fontSize: 18, // 텍스트 확대
                                      fontWeight: FontWeight.bold
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          Icon(Icons.circle, size: 10, color: _isConnected ? Colors.green : Colors.red),
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          const ConnectionStatusBar(),
          Expanded(
            child: Container(
              color: isDark ? const Color(0xFF1E1F22) : const Color(0xFFE3E8ED), // 배경색 변경 (디스코드/카카오톡 느낌)
              child: ListView.builder(
                controller: _scrollController,
                reverse: false, // [Fix] 다시 정방향 (위=과거, 아래=최신)
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final isMe = msg.senderId == widget.currentUser.id;
                  final isNotice = msg.type == 'notice';
                  
                  // [Fix] 날짜 구분선 로직 (정방향 로직 복귀)
                  // 정방향이므로 index가 커질수록 최신(미래) 메시지임.
                  // 현재 메시지(index) 위에 구분선을 띄우려면, '바로 이전 메시지(index-1)'와 날짜를 비교해야 함.
                  bool showDateDivider = false;
                  DateTime msgDate;
                  try {
                    msgDate = DateTime.parse(msg.createdAt).toLocal();
                  } catch (e) {
                    msgDate = DateTime.now();
                  }

                  if (index == 0) {
                    // 가장 과거 메시지(첫 아이템)는 무조건 날짜 표시
                    showDateDivider = true;
                  } else {
                    final prevMsg = _messages[index - 1];
                    DateTime prevDate;
                    try {
                      prevDate = DateTime.parse(prevMsg.createdAt).toLocal();
                    } catch (e) {
                      prevDate = DateTime.now();
                    }
                    
                    if (prevDate.year != msgDate.year || 
                        prevDate.month != msgDate.month || 
                        prevDate.day != msgDate.day) {
                      showDateDivider = true;
                    }
                  }

                  // 요일 문자열 변환
                  const weekDays = ['월', '화', '수', '목', '금', '토', '일'];
                  final weekDayStr = weekDays[msgDate.weekday - 1];

                  // 시간 포맷 (HH:mm)
                  final timeStr = msg.createdAt.length >= 16 
                      ? msg.createdAt.substring(11, 16) 
                      : msg.createdAt;

                  Widget dateDividerWidget = const SizedBox();
                  if (showDateDivider) {
                    dateDividerWidget = Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Row(
                        children: [
                          Expanded(child: Divider(color: isDark ? Colors.white10 : Colors.black12)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: isDark ? Colors.white10 : Colors.black.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${msgDate.year}년 ${msgDate.month}월 ${msgDate.day}일 $weekDayStr요일',
                                style: TextStyle(
                                  color: isDark ? Colors.white54 : Colors.black54,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold
                                ),
                              ),
                            ),
                          ),
                          Expanded(child: Divider(color: isDark ? Colors.white10 : Colors.black12)),
                        ],
                      ),
                    );
                  }

                  Widget messageWidget;

                  if (isNotice) {
                    final isEmergency = msg.content.contains('긴급'); // 긴급 공지 여부 확인
                    
                    messageWidget = Center(
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.9),
                        decoration: BoxDecoration(
                          color: isEmergency 
                              ? (isDark ? const Color(0xFF3A2020) : const Color(0xFFFFF2F2)) // 긴급 시 연빨강 배경
                              : (isDark ? const Color(0xFF2B2D31) : const Color(0xFFF5F2E9)), // 일반 시 크림색
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isEmergency ? Colors.red.withOpacity(0.8) : Colors.grey.withOpacity(0.3),
                            width: isEmergency ? 2.0 : 1.2
                          ),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))
                          ]
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // [v2.5.23] 공지 헤더 (적색 경고 배너 디자인)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: isEmergency ? const Color(0xFFD32F2F) : Colors.grey[700],
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(15),
                                  topRight: Radius.circular(15),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
                                  const SizedBox(width: 10),
                                  Text(
                                    isEmergency ? '[긴급 공지 사항]' : '[공지 사항]',
                                    style: const TextStyle(
                                      color: Colors.white, 
                                      fontWeight: FontWeight.bold, 
                                      fontSize: 18,
                                      letterSpacing: -0.5
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // 공지 내용
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 26, 20, 16),
                              child: Text(
                                msg.content,
                                style: TextStyle(
                                  color: isEmergency 
                                      ? (isDark ? Colors.red[100] : const Color(0xFFB71C1C)) 
                                      : (isDark ? Colors.white : const Color(0xFF222222)), 
                                  fontSize: 18,
                                  height: 1.5,
                                  fontWeight: isEmergency ? FontWeight.bold : FontWeight.w500,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            // [Added] 우측 하단 시간 표시 (이미지 디자인 반영)
                            Padding(
                              padding: const EdgeInsets.only(right: 16, bottom: 12),
                              child: Align(
                                alignment: Alignment.bottomRight,
                                child: Text(
                                  timeStr,
                                  style: TextStyle(
                                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  } else if (isMe) {
                    // [나의 메시지]
                    messageWidget = Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // 시간 & 읽음 표시 (왼쪽)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                                if (!msg.isRead && msg.readCount > 0)
                                  Text(
                                    '${msg.readCount}',
                                    style: TextStyle(
                                      color: Colors.yellow[700], 
                                      fontSize: 10, 
                                      fontWeight: FontWeight.bold
                                    ),
                                  ),
                              Text(
                                timeStr,
                                style: TextStyle(
                                  color: isDark ? Colors.grey[400] : Colors.grey[600],
                                  fontSize: 10
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 6),
                          // 말풍선
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF5865F2) : const Color(0xFF4C66FF), // 브랜드 컬러
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  topRight: Radius.circular(2), // 말꼬리 효과
                                  bottomLeft: Radius.circular(16),
                                  bottomRight: Radius.circular(16),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 2,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                              child: _buildMessageContent(msg, true),
                            ),
                          ),
                        ],
                      ),
                    );
                  } else {
                    // [상대방 메시지]
                    messageWidget = Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 프로필 아이콘
                          Container(
                            margin: const EdgeInsets.only(right: 8),
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: isDark ? Colors.grey[700] : Colors.white,
                              child: Text(
                                (msg.senderName?.isNotEmpty == true ? msg.senderName![0] : '?').toUpperCase(),
                                style: TextStyle(
                                  fontSize: 12, 
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : Colors.black87
                                ),
                              ),
                            ),
                          ),
                          // 이름 및 내용
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 이름 (말풍선 밖으로 뺌)
                              if (msg.senderName != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 2, bottom: 4),
                                  child: Text(
                                    msg.senderName!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark ? Colors.grey[400] : Colors.grey[700],
                                    ),
                                  ),
                                ),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  // 말풍선
                                  ConstrainedBox(
                                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: isDark ? const Color(0xFF2B2D31) : Colors.white,
                                        borderRadius: const BorderRadius.only(
                                          topLeft: Radius.circular(2), // 말꼬리 효과
                                          topRight: Radius.circular(16),
                                          bottomLeft: Radius.circular(16),
                                          bottomRight: Radius.circular(16),
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.05),
                                            blurRadius: 2,
                                            offset: const Offset(0, 1),
                                          ),
                                        ],
                                      ),
                                      child: _buildMessageContent(msg, false),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  // 시간 & 읽음 표시 (오른쪽)
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (!msg.isRead && msg.readCount > 0)
                                        Text(
                                          '${msg.readCount}',
                                          style: TextStyle(
                                            color: Colors.yellow[700], 
                                            fontSize: 10, 
                                            fontWeight: FontWeight.bold
                                          ),
                                        ),
                                      Text(
                                        timeStr,
                                        style: TextStyle(
                                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                                          fontSize: 10
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }

                  return Column(
                    children: [
                      dateDividerWidget,
                      messageWidget,
                    ],
                  );
                },
              ),
            ),
          ),
          
          // --- 입력창 영역 ---
          if (_isUploading)
            const LinearProgressIndicator(minHeight: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2B2D31) : Colors.white,
              boxShadow: [
                 BoxShadow(
                   color: Colors.black.withOpacity(isDark ? 0.3 : 0.05),
                   offset: const Offset(0, -1),
                   blurRadius: 5
                 )
              ]
            ),
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    onPressed: _showAttachmentMenu,
                    icon: Icon(Icons.add_circle_outline, color: isDark ? Colors.white70 : Colors.indigo[600]),
                  ),
                  Expanded(
                    child: RawKeyboardListener(
                      focusNode: _listenerFocusNode, // [Fix] 지속적인 포커스 노드 사용
                      onKey: (event) {
                        if (event.runtimeType.toString() == 'RawKeyDownEvent' &&
                            event.logicalKey.debugName == 'Enter') {
                          if (!event.isShiftPressed) _sendMessage();
                        }
                      },
                      child: TextField(
                        controller: _messageController,
                        focusNode: _messageFocusNode,
                        autofocus: false, // [Fix] autofocus 비활성화 (모바일 키보드 자동 팝업 방지)
                        maxLines: 5,
                        minLines: 1,
                        textInputAction: TextInputAction.send,
                        style: TextStyle(
                            color: isDark ? Colors.white : Colors.black87,
                            fontSize: 15
                        ),
                        decoration: InputDecoration(
                          hintText: '메시지 보내기...',
                          hintStyle: TextStyle(color: isDark ? Colors.white38 : Colors.grey[400]),
                          filled: true,
                          fillColor: isDark ? const Color(0xFF383A40) : const Color(0xFFF2F4F6),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          isDense: true,
                        ),
                        onTap: () {
                          socketService.socket?.emit('mark_as_read', {
                            'roomId': widget.roomId,
                            'userId': widget.currentUser.id
                          });
                        },
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF4C66FF), // 브랜드 컬러
                    ),
                    child: IconButton(
                      onPressed: _sendMessage,
                      icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      padding: const EdgeInsets.all(12),
                      constraints: const BoxConstraints(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // [Added] 메시지 타입별 렌더링 함수
  Widget _buildMessageContent(ChatMessage msg, bool isMe) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    if (msg.type == 'image' && msg.fileUrl != null) {
      final serverUrl = ConfigService.to.serverUrl;
      final fullImageUrl = msg.fileUrl!.startsWith('http') ? msg.fileUrl! : '$serverUrl${msg.fileUrl}';
      
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => FullScreenImageViewer(
                    imageUrl: fullImageUrl,
                    filename: msg.content,
                  ),
                ),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                fullImageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, size: 50),
              ),
            ),
          ),
          if (msg.content.isNotEmpty && msg.content != msg.id.toString())
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                msg.content,
                style: TextStyle(
                  color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black87),
                  fontSize: 14,
                ),
              ),
            ),
        ],
      );
  } else if (msg.type == 'video' && msg.fileUrl != null) {
    return VideoMessageBubble(msg: msg, isMe: isMe, isDark: isDark);
  } else if (msg.type == 'file' && msg.fileUrl != null) {
    return InkWell(
      onTap: () {
        // 파일 다운로드/열기 로직 호출
        _downloadAndOpenFile(msg.fileUrl!, msg.content);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.insert_drive_file_rounded,
            color: isMe ? Colors.white : Colors.indigo[600],
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              msg.content,
              style: TextStyle(
                color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black87),
                fontSize: 14,
                decoration: TextDecoration.underline,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
    
    // 기본 텍스트 메시지
    return Text(
      msg.content,
      style: TextStyle(
        color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black87),
        fontSize: 15,
        height: 1.4,
      ),
    );
  }

  // [Added] 파일 다운로드 및 열기 로직
  Future<void> _downloadAndOpenFile(String fileUrl, String filename) async {
    final serverUrl = ConfigService.to.serverUrl;
    final fullUrl = fileUrl.startsWith('http') ? fileUrl : '$serverUrl$fileUrl';
    final uri = Uri.parse(fullUrl);
    
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('파일을 열 수 있는 앱이 없습니다.')),
        );
      }
    }
  }
}

// --- In-App Notification Banner Widget ---
class InAppNotificationBanner extends StatelessWidget {
  final String title;
  final String body;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  const InAppNotificationBanner({
    super.key,
    required this.title,
    required this.body,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isEmergency = title.contains('긴급'); // 긴급 여부 판정
    
    // [v2.5.26] 긴급 공지 시 더욱 진한 적색 테마 적용
    final bgColor = isEmergency 
        ? (isDark ? const Color(0xFFB71C1C) : const Color(0xFFD32F2F))
        : (isDark ? const Color(0xFF2C2C2E) : Colors.white);
    
    final textColor = isEmergency ? Colors.white : (isDark ? Colors.white : Colors.black87);
    final subTextColor = isEmergency ? Colors.white.withOpacity(0.9) : (isDark ? Colors.white70 : Colors.black54);

    return GestureDetector(
      onTap: onTap,
      onVerticalDragUpdate: (details) {
        if (details.primaryDelta! < -10) {
          onDismiss();
        }
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: isEmergency ? Colors.red.withOpacity(0.3) : Colors.black.withOpacity(0.2),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(
            color: isEmergency ? Colors.white24 : (isDark ? Colors.white10 : Colors.black12),
            width: isEmergency ? 1.0 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isEmergency ? Colors.white24 : Colors.indigo[600],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isEmergency ? Icons.warning_amber_rounded : Icons.chat_bubble_outline, 
                color: Colors.white, 
                size: 24
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: subTextColor,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.close, size: 20, color: textColor.withOpacity(0.7)),
              onPressed: onDismiss,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }
}

// [v2.5.7] 업데이트 안내 다이얼로그 (수정: 현재 버전 정보 파라미터 추가)
void _showUpdateDialog(BuildContext context, Map<String, dynamic> updateInfo, {String? currentVersion, int? currentBuild}) {
  final changelog = (updateInfo['changelog'] as List?)?.join('\n') ?? '새로운 버전이 준비되었습니다.';
  final downloadUrlMap = updateInfo['downloadUrl'] as Map?;
  
  // 서버 버전 정보
  final serverVer = updateInfo['version'] ?? '?';
  final serverBuild = updateInfo['buildNumber'] ?? '?';

  String? downloadUrl;
  if (Platform.isWindows) {
    downloadUrl = downloadUrlMap?['windows'];
  } else {
    downloadUrl = downloadUrlMap?['android'];
  }

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update, color: Colors.indigo[700]),
          const SizedBox(width: 8),
          const Text('새 버전 업데이트'),
        ],
      ),
      content: SingleChildScrollView(
        child: ListBody(
          children: [
            Text('새로운 버전(v$serverVer)이 출시되었습니다.', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text('[업데이트 내역]', style: TextStyle(fontSize: 13, color: Colors.grey)),
            Text(changelog, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            // [Debug Info]
            if (currentVersion != null)
              Text(
                '현재: v$currentVersion ($currentBuild) / 최신: $serverVer ($serverBuild)',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('나중에'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo[700], foregroundColor: Colors.white),
          onPressed: () async {
            if (downloadUrl != null) {
               final uri = Uri.parse(downloadUrl);
               if (await canLaunchUrl(uri)) {
                 await launchUrl(uri, mode: LaunchMode.externalApplication);
               }
            }
          },
          child: const Text('지금 업데이트'),
        ),
      ],
    ),
  );
}

// [v2.0.0] 전체 화면 이미지 뷰어 위젯 (카카오톡 스타일)
class FullScreenImageViewer extends StatefulWidget {
  final String imageUrl;
  final String filename;

  const FullScreenImageViewer({
    super.key,
    required this.imageUrl,
    required this.filename,
  });

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  bool _isDownloading = false;

  Future<void> _downloadImage() async {
    setState(() => _isDownloading = true);
    try {
      final response = await http.get(Uri.parse(widget.imageUrl));
      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        String? savePath;

        if (Platform.isWindows) {
          savePath = await FilePicker.platform.saveFile(
            dialogTitle: '이미지 저장',
            fileName: widget.filename,
            type: FileType.image,
          );
        } else if (Platform.isAndroid) {
          bool granted = false;
          // 안드로이드 버전 확인 및 권한 요청 (더 포괄적으로 변경)
          if (await Permission.photos.request().isGranted || 
              await Permission.storage.request().isGranted ||
              await Permission.manageExternalStorage.request().isGranted) {
            granted = true;
          }

          if (granted) {
            final directory = await getExternalStorageDirectory();
            // [Fix] 공용 사진 폴더 (Pictures) 시도하여 갤러리에 즉시 표시되도록 개선
            String downloadPath = '/storage/emulated/0/Pictures/CSChat';
            final downloadDir = Directory(downloadPath);
            if (!await downloadDir.exists()) {
              try {
                await downloadDir.create(recursive: true);
              } catch (e) {
                // 권한 혹은 경로 문제 시 기본 외부 저장소 사용
                downloadPath = '/storage/emulated/0/Download';
                final fallbackDir = Directory(downloadPath);
                if (!await fallbackDir.exists()) {
                   downloadPath = directory?.path ?? '';
                }
              }
            }
            
            if (downloadPath.isNotEmpty) {
              savePath = p.join(downloadPath, widget.filename);
            }
          } else {
            // 권한 거부 시 설정 화면 이동 안내 등
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('저장 권한이 필요합니다. 설정에서 권한을 허용해 주세요.'),
                  action: SnackBarAction(label: '설정', onPressed: openAppSettings),
                ),
              );
            }
          }
        }

        if (savePath != null) {
          final file = File(savePath);
          await file.writeAsBytes(bytes);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('이미지가 저장되었습니다: ${p.basename(savePath)}'),
                backgroundColor: Colors.green[700],
              ),
            );
          }
        }
      }
    } catch (e) {
      print('[Viewer] Download error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('다운로드 중 오류 발생: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5.0,
              child: Image.network(
                widget.imageUrl,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return const Center(child: CircularProgressIndicator(color: Colors.white));
                },
                errorBuilder: (context, error, stackTrace) => const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.broken_image, color: Colors.white, size: 50),
                    SizedBox(height: 10),
                    Text('이미지를 불러올 수 없습니다.', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 10,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 32),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                ),
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.filename,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 16),
                    if (_isDownloading)
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.download_for_offline_rounded, color: Colors.white, size: 36),
                        onPressed: _downloadImage,
                        tooltip: '이미지 저장',
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// [Added] 카카오톡 스타일 비디오 메시지 렌더링을 위한 독립 위젯
class VideoMessageBubble extends StatefulWidget {
  final ChatMessage msg;
  final bool isMe;
  final bool isDark;

  const VideoMessageBubble({
    super.key,
    required this.msg,
    required this.isMe,
    required this.isDark,
  });

  @override
  State<VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

class _VideoMessageBubbleState extends State<VideoMessageBubble> {
  bool _isDownloading = false;
  bool _isDownloaded = false;
  String _localPath = '';

  @override
  void initState() {
    super.initState();
    _checkLocalFile();
  }

  Future<void> _checkLocalFile() async {
    if (!Platform.isWindows) return;
    try {
      final defaultDir = await getDownloadsDirectory();
      if (defaultDir != null) {
        final cschatDir = Directory(p.join(defaultDir.path, 'cschat_download'));
        final fileName = '${widget.msg.id}_${widget.msg.content}';
        final file = File(p.join(cschatDir.path, fileName));
        if (await file.exists()) {
          if (mounted) {
            setState(() {
              _isDownloaded = true;
              _localPath = file.path;
            });
          }
        }
      }
    } catch (e) {
      print('Check local file error: $e');
    }
  }

  Future<void> _downloadVideo(String fullVideoUrl) async {
    if (_isDownloading) return;
    setState(() => _isDownloading = true);
    
    try {
      String? initialDir;
      final defaultDir = await getDownloadsDirectory();
      if (defaultDir != null) {
        final cschatDir = Directory(p.join(defaultDir.path, 'cschat_download'));
        if (!await cschatDir.exists()) {
          await cschatDir.create(recursive: true);
        }
        initialDir = cschatDir.path;
      }

      final fileName = '${widget.msg.id}_${widget.msg.content}';
      
      // [Fix] 사용자가 원하는 경로를 지정할 수 있도록 file picker 오픈 (기본: cschat_download)
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '동영상 저장 위치 선택',
        fileName: fileName,
        initialDirectory: initialDir,
        type: FileType.video,
      );

      if (savePath == null) {
        // 사용자가 취소함
        if (mounted) setState(() => _isDownloading = false);
        return;
      }

      // [Fix] 기존 http.get 버퍼 방식(RAM 한계에 의한 파일 깨짐 및 무한로딩 유발)을 HttpClient 스트림 방식으로 교체
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(fullVideoUrl));
      final response = await request.close();
      
      if (response.statusCode == 200) {
        final file = File(savePath);
        final sink = file.openWrite();
        await response.pipe(sink);

        if (mounted) {
          setState(() {
            _isDownloaded = true;
            _localPath = file.path;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('동영상이 저장되었습니다: ${p.basename(savePath)}'),
              backgroundColor: Colors.green[700],
            ),
          );
        }
      } else {
        throw Exception('Server returned ${response.statusCode}');
      }
    } catch (e) {
      print('[VideoDownload] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('동영상 다운로드 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = ConfigService.to.serverUrl;
    final fullVideoUrl = widget.msg.fileUrl!.startsWith('http') 
        ? widget.msg.fileUrl! 
        : '$serverUrl${widget.msg.fileUrl}';
    final fullThumbUrl = widget.msg.thumbnailUrl != null 
        ? (widget.msg.thumbnailUrl!.startsWith('http') ? widget.msg.thumbnailUrl! : '$serverUrl${widget.msg.thumbnailUrl}')
        : null;

    final isWindows = Platform.isWindows;
    final showDownloadIcon = isWindows && !_isDownloaded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () {
            if (showDownloadIcon) {
              _downloadVideo(fullVideoUrl);
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => VideoPlayerScreen(
                    videoUrl: isWindows ? _localPath : fullVideoUrl,
                    filename: widget.msg.content,
                  ),
                ),
              );
            }
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 200,
                  height: 150,
                  color: Colors.black12,
                  child: fullThumbUrl != null
                      ? Image.network(
                          fullThumbUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => const Center(child: Icon(Icons.broken_image, size: 40, color: Colors.white54)),
                        )
                      : const Center(child: Icon(Icons.videocam, size: 40, color: Colors.white54)),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: _isDownloading 
                    ? const SizedBox(
                        width: 30, height: 30,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                      )
                    : Icon(
                        showDownloadIcon ? Icons.download_rounded : Icons.play_arrow_rounded, 
                        color: Colors.white, 
                        size: 30,
                      ),
              ),
            ],
          ),
        ),
        if (widget.msg.content.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              widget.msg.content,
              style: TextStyle(
                color: widget.isMe ? Colors.white : (widget.isDark ? Colors.white : Colors.black87),
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final String videoUrl;
  final String filename;

  const VideoPlayerScreen({
    super.key,
    required this.videoUrl,
    required this.filename,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  String? _errorMessage;

  Future<void> _initializePlayer() async {
      try {
        _errorMessage = null;

        if (Platform.isAndroid) {
          try {
            const channel = MethodChannel('com.example.cschat/sound');
            await channel.invokeMethod('setSpeakerOn');
          } catch (e) {
            print('Failed to set speaker on: $e');
          }
        }

        if (widget.videoUrl.startsWith('http')) {
          _videoPlayerController = VideoPlayerController.networkUrl(
            Uri.parse(widget.videoUrl),
            videoPlayerOptions: (Platform.isAndroid || Platform.isIOS) ? VideoPlayerOptions(mixWithOthers: true) : null,
          );
        } else {
          // [Fix] Windows 카카오톡 스타일 동영상 캐시에 의해 로컬 절대 경로로 입력된 경우
          final localFile = File(widget.videoUrl);
          if (!await localFile.exists()) {
            throw Exception("파일이 디스크에 존재하지 않습니다: ${widget.videoUrl}");
          } else {
            final size = await localFile.length();
            if (size == 0) {
              throw Exception("파일이 0바이트입니다. 다운로드 중 오류가 발생했습니다.");
            }
          }
          _videoPlayerController = VideoPlayerController.file(localFile);
        }

        await _videoPlayerController.initialize();
        await _videoPlayerController.setVolume(1.0);

      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController!,
        autoPlay: true,
        looping: false,
        // [Fix] 초기 aspectRatio가 부정확할 수 있으므로, Chewie 내부 계산에 맡기거나 videoPlayerController의 값이 0보다 클 때만 명시
        aspectRatio: _videoPlayerController!.value.aspectRatio > 0 
            ? _videoPlayerController!.value.aspectRatio 
            : 16/9,
        allowFullScreen: true,
        allowPlaybackSpeedChanging: true,
        placeholder: const Center(child: CircularProgressIndicator(color: Colors.white)),
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, color: Colors.white, size: 42),
                const SizedBox(height: 8),
                Text(errorMessage, style: const TextStyle(color: Colors.white)),
              ],
            ),
          );
        },
        materialProgressColors: ChewieProgressColors(
          playedColor: Colors.red,
          handleColor: Colors.redAccent,
          backgroundColor: Colors.grey,
          bufferedColor: Colors.white.withOpacity(0.5),
        ),
      );
    } catch (e) {
      print('[VideoPlayer] Initialization failed: $e');
      _errorMessage = '동영상을 재생할 수 없습니다.\n$e';
    } finally {
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  bool _isDownloading = false;

  Future<void> _downloadVideo() async {
    if (_isDownloading) return;
    setState(() => _isDownloading = true);

    try {
      final response = await http.get(Uri.parse(widget.videoUrl));
      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        String? savePath;

        if (Platform.isWindows) {
          savePath = await FilePicker.platform.saveFile(
            dialogTitle: '동영상 저장',
            fileName: widget.filename,
            type: FileType.video,
          );
        } else if (Platform.isAndroid) {
          // [Fix] Android 13+ 대응을 위해 photos, videos, storage 권한 모두 체크
          bool granted = false;
          if (await Permission.videos.request().isGranted || 
              await Permission.storage.request().isGranted ||
              await Permission.manageExternalStorage.request().isGranted) {
            granted = true;
          }

          if (granted) {
            final directory = await getExternalStorageDirectory();
            // Movies/CSChat 폴더 사용
            String downloadPath = '/storage/emulated/0/Movies/CSChat';
            final downloadDir = Directory(downloadPath);
            if (!await downloadDir.exists()) {
              try {
                await downloadDir.create(recursive: true);
              } catch (e) {
                downloadPath = '/storage/emulated/0/Download';
                final fallbackDir = Directory(downloadPath);
                if (!await fallbackDir.exists()) {
                   downloadPath = directory?.path ?? '';
                }
              }
            }
            
            if (downloadPath.isNotEmpty) {
              savePath = p.join(downloadPath, widget.filename);
            }
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('저장 권한이 필요합니다.'),
                  action: SnackBarAction(
                    label: '설정',
                    onPressed: openAppSettings,
                  ),
                ),
              );
            }
          }
        }

        if (savePath != null) {
          final file = File(savePath);
          await file.writeAsBytes(bytes);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('동영상이 저장되었습니다: ${p.basename(savePath)}'),
                backgroundColor: Colors.green[700],
              ),
            );
          }
        }
      } else {
        throw Exception('Server returned ${response.statusCode}');
      }
    } catch (e) {
      print('[VideoPlayer] Download error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('다운로드 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.filename,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_isDownloading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: '동영상 저장',
              onPressed: _downloadVideo,
            ),
        ],
      ),
      body: Center(
        child: _errorMessage != null
            ? Padding(
                padding: const EdgeInsets.all(20.0),
                child: Text(
                  '오류 발생:\n$_errorMessage',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              )
            : _chewieController != null && _chewieController!.videoPlayerController.value.isInitialized
                ? Chewie(controller: _chewieController!)
                : const CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}
