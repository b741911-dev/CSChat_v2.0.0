import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:ui';
import 'dart:typed_data';
import 'models.dart';
import 'package:flutter/services.dart'; // MethodChannel
import 'package:device_info_plus/device_info_plus.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';
import 'package:provider/provider.dart';
class AppState extends ChangeNotifier {
  static final AppState to = AppState._();
  AppState._();

  int? _currentRoomId;
  int? get currentRoomId => _currentRoomId;
  
  void setRoomId(int? id) {
    _currentRoomId = id;
    notifyListeners();
  }

  bool _isFocused = true;
  bool get isFocused => _isFocused;
  
  void setFocused(bool focused) {
    _isFocused = focused;
    notifyListeners();
  }

  int _currentTabIndex = 0;
  int get currentTabIndex => _currentTabIndex;

  void setTabIndex(int index) {
    _currentTabIndex = index;
    notifyListeners();
  }

  // [Added] 전체 읽지 않은 메시지 수 관리
  int _totalUnreadCount = 0;
  int get totalUnreadCount => _totalUnreadCount;

  void setTotalUnreadCount(int count) {
    if (_totalUnreadCount != count) {
      _totalUnreadCount = count;
      notifyListeners();
    }
  }

  void incrementTotalUnreadCount() {
    _totalUnreadCount++;
    notifyListeners();
  }

  // [Added] 서버로부터 전체 읽지 않은 메시지 수 갱신
  Future<void> refreshTotalUnread() async {
    final user = ConfigService.to.currentUser;
    if (user == null) return;

    try {
      final response = await http.get(Uri.parse('${ConfigService.to.serverUrl}/api/unread/total?userId=${user.id}'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final count = data['count'] ?? 0;
        setTotalUnreadCount(count);
        print('[AppState] Total Unread Refreshed: $count');
      }
    } catch (e) {
      print('[AppState] refreshTotalUnread Error: $e');
    }
  }
}

class DeviceService {
  static final DeviceService to = DeviceService._();
  DeviceService._();

  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  String? _deviceId;

  Future<String> getDeviceId() async {
    if (_deviceId != null) return _deviceId!;

    try {
      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await _deviceInfo.androidInfo;
        _deviceId = androidInfo.id; // 64-bit number (hex) unique to each device
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await _deviceInfo.iosInfo;
        _deviceId = iosInfo.identifierForVendor; // unique ID for vendor
      } else if (Platform.isWindows) {
        WindowsDeviceInfo winInfo = await _deviceInfo.windowsInfo;
        _deviceId = winInfo.deviceId;
      } else {
        _deviceId = 'UNKNOWN_DEVICE';
      }
    } catch (e) {
      print('[DeviceService] Error getting device ID: $e');
      _deviceId = 'ERROR_DEVICE';
    }

    return _deviceId!;
  }

  // [v2.5.4] Detailed OS Info - Updated with Korean labels and Windows Edition
  Future<Map<String, String>> getDetailedInfo() async {
    String osInfo = 'Unknown';
    String deviceType = '데스크탑'; // Default
    
    try {
      if (Platform.isAndroid) {
        AndroidDeviceInfo info = await _deviceInfo.androidInfo;
        osInfo = 'Android ${info.version.release} (SDK ${info.version.sdkInt})';
        deviceType = '모바일';
      } else if (Platform.isWindows) {
        WindowsDeviceInfo info = await _deviceInfo.windowsInfo;
        // windowsInfo might have productName (Edition) and displayVersion (e.g. 22H2)
        // Fallback to basic info if modern fields are missing
        String edition = info.productName; // e.g. "Windows 11 Pro"
        String version = info.displayVersion; // e.g. "23H2"
        
        if (edition.isNotEmpty && version.isNotEmpty) {
           osInfo = '$edition (버전 $version)';
        } else {
           osInfo = 'Windows ${info.majorVersion}.${info.minorVersion} Build ${info.buildNumber}';
        }
        deviceType = '데스크탑';
      } else if (Platform.isIOS) {
        IosDeviceInfo info = await _deviceInfo.iosInfo;
        osInfo = 'iOS ${info.systemVersion}';
        deviceType = '모바일';
      }
    } catch(e) {
      print('[DeviceService] Error getting detailed info: $e');
    }
    return {'osInfo': osInfo, 'deviceType': deviceType};
  }
}



class ConfigService {
  static final ConfigService to = ConfigService._();
  ConfigService._();
  
  late SharedPreferences _prefs;
  User? currentUser; // 현재 로그인한 사용자
  
  bool get isSoundEnabled => _prefs.getBool('isSoundEnabled') ?? true;
  set isSoundEnabled(bool v) => _prefs.setBool('isSoundEnabled', v);
  
  bool get isPopupEnabled => _prefs.getBool('isPopupEnabled') ?? true;
  set isPopupEnabled(bool v) => _prefs.setBool('isPopupEnabled', v);


  String get serverUrl => _prefs.getString('serverUrl') ?? 'http://192.168.0.43:3001';

  Future<void> setServerUrl(String url) async {
    await _prefs.setString('serverUrl', url);
  }

  bool get isDarkMode => _prefs.getBool('isDarkMode') ?? false;

  final ValueNotifier<bool> themeNotifier = ValueNotifier(false);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    themeNotifier.value = isDarkMode;
  }

  Future<void> setSoundEnabled(bool enabled) async {
    await _prefs.setBool('isSoundEnabled', enabled);
  }

  Future<void> setDarkMode(bool enabled) async {
    await _prefs.setBool('isDarkMode', enabled);
    themeNotifier.value = enabled;
  }
  
  // Native Sound Playback
  static const platform = MethodChannel('com.example.cschat/sound');

  Future<void> playSystemSound() async {
    try {
      await platform.invokeMethod('playNotificationSound');
      print('[ConfigService] System sound played via native channel');
    } catch (e) {
      print('[ConfigService] Failed to play system sound: $e');
    }
  }
}

class NotificationService {
  static final NotificationService to = NotificationService._();
  NotificationService._();
  
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  // 현재 보고 있는 채팅방 ID (알림 소리 방지용)
  int? get currentRoomId => AppState.to.currentRoomId;
  
  // 알림 클릭 시 호출될 콜백 (메인 앱에서 설정)
  Function(String payload)? onNotificationClick;

  // 인앱 알림배너용 콜백
  Function(String title, String body, String payload)? onInAppNotification;

  // 알림 스로틀링용 (roomId별 마지막 알림 시간)
  final Map<int, DateTime> _lastNotificationTime = {};

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings();
    const linux = LinuxInitializationSettings(defaultActionName: 'Open notification');
    
    final settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
    );
    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (details) {
        if (details.payload != null && onNotificationClick != null) {
          onNotificationClick!(details.payload!);
        }
      },
    );

    // Windows Native 알림 초기화
    if (Platform.isWindows) {
      await localNotifier.setup(
        appName: 'CSChat',
        // shortcutPolicy: ShortcutPolicy.requireCreate,
      );
    }

    // Android 알림 채널 생성 (소리/진동 분리)
    // Android 알림 채널 생성 (소리/진동 분리) - v16 (System Sound)
    // 1. 소리+진동 채널
    final AndroidNotificationChannel loudChannel = AndroidNotificationChannel(
      'cschat_alert_v16', 
      'CSChat 알림 (소리/진동)',
      description: '소리와 진동이 포함된 알림',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500]), // 간결한 진동
    );

    // 2. 무음 채널
    final AndroidNotificationChannel silentChannel = AndroidNotificationChannel(
      'cschat_silent_v16', 
      'CSChat 알림 (무음)',
      description: '소리와 진동이 없는 알림',
      importance: Importance.max, 
      playSound: false,
      enableVibration: false,
    );

    final plugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (plugin != null) {
      // 기존 채널 삭제 (Clean up)
      try {
        await plugin.deleteNotificationChannel('cschat_alert_v15');
        await plugin.deleteNotificationChannel('cschat_silent_v15');
        await plugin.deleteNotificationChannel('cschat_alert_v14');
        await plugin.deleteNotificationChannel('cschat_silent_v14');
      } catch (e) {
        print('채널 삭제 중 오류 (무시): $e');
      }
      
      await plugin.createNotificationChannel(loudChannel);
      await plugin.createNotificationChannel(silentChannel);
    }
    
    // 알림 권한 요청 (Android 13+)
    if (Platform.isAndroid) {
      final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        await androidPlugin.requestNotificationsPermission();
      }
    }
    
    print('[Notification] 알림 채널 생성(v16) 및 권한 요청 완료');
  }

  Future<void> show(String title, String body, {String? payload, int? roomId}) async {
    // 1. 팝업 알림 설정 확인
    if (!ConfigService.to.isPopupEnabled) return;
    
    // 2. 현재 채팅방 확인 (해당 방에 있으면 알림 생략)
    final curRoomId = AppState.to.currentRoomId;
    if (roomId != null && curRoomId == roomId) return;

    // [Throttling] 동일 방 연속 알림 방지 (2초)
    if (roomId != null) {
      final now = DateTime.now();
      final lastTime = _lastNotificationTime[roomId];
      if (lastTime != null && now.difference(lastTime).inSeconds < 2) return;
      _lastNotificationTime[roomId] = now;
    }

    bool isFocused = AppState.to.isFocused;
    
    // Windows에서 더 정확한 포커스 감지를 시도하되, 기본 state와 OR 연산하여 안전성 확보
    if (Platform.isWindows) {
      final winFocused = await windowManager.isFocused();
      print('[NotificationService] Windows Focus: winManager=$winFocused, appState=$isFocused');
      isFocused = isFocused || winFocused;
    }
    
    // 3. 앱 포커스 상태에 따른 분기 (Windows/Android 공용)
    print('[NotificationService] Final isFocused=$isFocused, onInAppNotification is ${onInAppNotification != null ? 'SET' : 'NULL'}');
    
    if (isFocused) {
      // [옵션 1] 앱이 포커스 상태일 때 -> 인앱 알림 배너만 표시하고 시스템 알림은 차단
      if (onInAppNotification != null && payload != null) {
        print('[NotificationService] Showing in-app banner ONLY (system notification blocked)');
        onInAppNotification!(title, body, payload);
        return; // 인앱 배너 표시 후 즉시 종료 (시스템 알림 차단)
      } else {
        print('[NotificationService] Skip banner: payload=$payload');
        return; // 배너를 표시할 수 없으면 시스템 알림도 표시하지 않음
      }
    } else if (Platform.isWindows) {
      // 케이스 C: 윈도우에서 포커스가 없을 때 -> 네이티브 Toast 및 창 팝업
      print('[NotificationService] Triggering Windows Toast & Window Popup');
      await windowManager.show();
      await windowManager.focus();
      
      // [User Request] 어느 탭에서든 채팅탭(index 1)으로 강제 전환
      AppState.to.setTabIndex(1);
      
      _showWindowsToast(title, body, payload);
      return;
    }

    // 4. 백그라운드 상태일 때만 시스템 알림 표시 (Android)
    print('[NotificationService] App in background - showing system notification');
    
    // 사운드/진동 설정 확인 및 채널 선택
    final isSoundEnabled = ConfigService.to.isSoundEnabled;
    final channelId = isSoundEnabled ? 'cschat_alert_v16' : 'cschat_silent_v16';

    final androidDetails = AndroidNotificationDetails(
      channelId, 
      isSoundEnabled ? 'CSChat 알림 (소리/진동)' : 'CSChat 알림 (무음)',
      channelDescription: 'CSChat 메시지 알림',
      importance: Importance.max,
      priority: Priority.high,
      color: title.contains('긴급') ? const Color(0xFFD32F2F) : null, // [v2.5.26] 긴급 공지 시 적색 강조
      fullScreenIntent: false, 
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.message,
      ticker: '새 메시지 도착',
      playSound: isSoundEnabled,
      enableVibration: isSoundEnabled,
      vibrationPattern: isSoundEnabled ? Int64List.fromList([0, 500]) : null,
    );
    final details = NotificationDetails(android: androidDetails);
    
    try {
      if (payload == null && roomId != null) {
          payload = jsonEncode({'roomId': roomId});
      }

      await _notifications.show(
        DateTime.now().microsecondsSinceEpoch % 2147483647,
        title,
        body,
        details,
        payload: payload,
      );
      print('[Notification] System notification shown: $title (Sound: $isSoundEnabled)');
      
      // 시스템 소리/진동 강제 재생 (Native Bridge 필수)
      if (isSoundEnabled) {
        await ConfigService.to.playSystemSound();
      }
    } catch (e) {
      print('알림 표시 실패: $e');
    }
  }

  Future<void> _showWindowsToast(String title, String body, String? payload) async {
    LocalNotification notification = LocalNotification(
      identifier: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      body: body,
      silent: !ConfigService.to.isSoundEnabled,
    );
    notification.onClick = () async {
      print('[WindowsToast] Clicked: $payload');
      // 윈도우 포커스
      await windowManager.show();
      await windowManager.focus();
      if (payload != null && onNotificationClick != null) {
        onNotificationClick!(payload);
      }
    };
    notification.show();
  }
  
  Future<void> playSound() async {
    // audioplayers 제거됨. 시스템 알림 사운드를 사용하므로 별도 재생 불필요.
    // 필요 시 여기에 진동 로직만 추가 가능.
  }

  Future<void> checkForLaunchPayload() async {
    final details = await _notifications.getNotificationAppLaunchDetails();
    if (details != null && details.didNotificationLaunchApp && details.notificationResponse?.payload != null) {
      print('[Notification] App launched from notification: ${details.notificationResponse?.payload}');
      if (onNotificationClick != null) {
        onNotificationClick!(details.notificationResponse!.payload!);
      }
    }
  }
}


// ============================================================================
// 백그라운드 서비스 - Top-level Functions (Isolate Entry Points)
// ============================================================================

// 백그라운드 서비스 설정 함수 (앱 시작 시 호출 - configure만 수행)
Future<void> configureBackgroundService() async {
  try {
    final service = FlutterBackgroundService();
    
    print('[Service] Configuring background service...');
    
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onBackgroundStart,
        autoStart: false, // 수동 시작 (로그인 후)
        isForegroundMode: true,
        notificationChannelId: 'my_foreground_service', // main.dart에서 생성한 채널 ID와 일치
        initialNotificationTitle: '🟢 CSChat 실행 중',
        initialNotificationContent: '백그라운드에서 메시지를 수신하고 있습니다 • 탭하여 열기',
        foregroundServiceNotificationId: 888, // 고유한 ID
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onBackgroundStart,
        onBackground: onIosBackground,
      ),
    );
    
    print('[Service] Background service configured successfully');
  } catch (e, stackTrace) {
    print('[Service] Configuration failed: $e');
    print('[Service] Stack trace: $stackTrace');
    // 설정 실패해도 앱은 계속 실행
  }
}

// 백그라운드 서비스 시작 함수 (로그인 성공 후 호출)
Future<bool> startBackgroundService() async {
  try {
    final service = FlutterBackgroundService();
    
    print('[Service] Starting background service...');
    
    // 서비스 시작
    final started = await service.startService();
    
    if (started) {
      print('[Service] Background service started successfully');
      return true;
    } else {
      print('[Service] Failed to start service (returned false)');
      return false;
    }
  } catch (e, stackTrace) {
    print('[Service] Start failed: $e');
    print('[Service] Stack trace: $stackTrace');
    return false;
  }
}

// iOS 백그라운드 핸들러
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    print('[iOS BG] Initialized successfully');
    return true;
  } catch (e) {
    print('[iOS BG] Initialization error: $e');
    return false;
  }
}

// Android 백그라운드 Isolate 진입점 (Top-level 필수)
@pragma('vm:entry-point')
void onBackgroundStart(ServiceInstance service) async {
  // 최상위 레벨 try-catch로 모든 에러 포착
  try {
    print('[BG_LOG] ===== Background Service Starting =====');
    print('[BG_LOG] Step 1: Service instance received');
    
    // Android 서비스를 포그라운드로 즉시 설정
    if (service is AndroidServiceInstance) {
      try {
        print('[BG_LOG] Step 2: Setting as foreground service...');
        await service.setAsForegroundService();
        print('[BG_LOG] Step 2: Foreground service set successfully');
      } catch (e) {
        print('[BG_LOG] Step 2 ERROR: Failed to set foreground service: $e');
      }
    }
    
    // Flutter 바인딩 초기화
    try {
      print('[BG_LOG] Step 3: Initializing DartPluginRegistrant...');
      DartPluginRegistrant.ensureInitialized();
      print('[BG_LOG] Step 3: DartPluginRegistrant initialized successfully');
    } catch (e) {
      print('[BG_LOG] Step 3 ERROR: DartPluginRegistrant init failed: $e');
      service.stopSelf();
      return;
    }
    
    // 알림 업데이트 (포그라운드 서비스 안정화)
    if (service is AndroidServiceInstance) {
      try {
        print('[BG_LOG] Step 3.5: Updating foreground notification...');
        await service.setForegroundNotificationInfo(
          title: "🟢 CSChat 실행 중",
          content: "백그라운드에서 메시지를 수신하고 있습니다 • 탭하여 열기",
        );
        print('[BG_LOG] Step 3.5: Notification updated successfully');
      } catch (e) {
        print('[BG_LOG] Step 3.5 ERROR: Failed to update notification: $e');
      }
    }
    
    // Isolate 엔진 안정화 대기 (1초)
    print('[BG_LOG] Step 4: Waiting for isolate stabilization (1 second)...');
    await Future.delayed(const Duration(seconds: 1));
    print('[BG_LOG] Step 4: Isolate stabilized');
    
    // SharedPreferences에서 사용자 정보 로드
    print('[BG_LOG] Step 5: Loading SharedPreferences...');
    late SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      print('[BG_LOG] Step 5: SharedPreferences loaded successfully');
    } catch (e) {
      print('[BG_LOG] Step 5 ERROR: Failed to load SharedPreferences: $e');
      service.stopSelf();
      return;
    }
    
    print('[BG_LOG] Step 6: Reading user data...');
    final userId = prefs.getInt('current_user_id');
    final serverUrl = prefs.getString('serverUrl') ?? 'http://192.168.0.43:3001';
    print('[BG_LOG] Step 6: userId=$userId, serverUrl=$serverUrl');
    
    if (userId == null) {
      print('[BG_LOG] Step 6 ERROR: No userId found, stopping service');
      service.stopSelf();
      return;
    }
    
    print('[BG_LOG] Step 7: Creating socket connection...');
    final socket = IO.io(serverUrl, IO.OptionBuilder()
      .setTransports(['websocket', 'polling']) // 폴링 폴백 추가
      .enableAutoConnect()
      .enableReconnection()
      .setReconnectionDelay(2000)
      .setReconnectionDelayMax(10000)
      .setReconnectionAttempts(99999)
      .setExtraHeaders({'Connection': 'keep-alive'})
      .build());
    print('[BG_LOG] Step 7: Socket instance created');
    
    print('[BG_LOG] Step 8: Setting up socket event handlers...');
    socket.onConnect((_) async {
      print('[BG_LOG] Socket CONNECTED');
      
      // [Fix] Background에서도 deviceId를 함께 보내어 중복 로그인 방지
      final deviceId = await DeviceService.to.getDeviceId();
      socket.emit('register_user', {
        'userId': userId,
        'deviceId': deviceId,
      });
      print('[BG_LOG] Emitted register_user: $userId, deviceId: $deviceId');
    });
    
    socket.onDisconnect((_) {
      print('[BG_LOG] Socket DISCONNECTED');
    });
    
    socket.onError((error) {
      print('[BG_LOG] Socket ERROR: $error');
    });
    
    // 메시지 수신 핸들러
    socket.on('receive_message', (data) async {
      print('[BG_LOG] Message RECEIVED: $data');
      await _handleBackgroundMessage(data, userId, prefs);
    });

    // [Added] 긴급 공지 수신 핸들러
    socket.on('notice', (data) async {
      print('[BG_LOG] Notice RECEIVED: $data');
      await _handleBackgroundMessage(data, userId, prefs, isNotice: true);
    });
    print('[BG_LOG] Step 8: Event handlers set');
    
    print('[BG_LOG] Step 9: Connecting socket...');
    socket.connect();
    print('[BG_LOG] Step 9: Socket connect() called');
    
    // 서비스 종료 리스너
    print('[BG_LOG] Step 10: Setting up stop service listener...');
    service.on('stopService').listen((event) {
      print('[BG_LOG] Stop service requested');
      socket.disconnect();
      socket.dispose();
      service.stopSelf();
      print('[BG_LOG] Service stopped');
    });
    
    // [하이브리드 방식] 포그라운드 알림 업데이트 리스너
    service.on('setAsForeground').listen((event) async {
      if (service is AndroidServiceInstance) {
        try {
          print('[BG_LOG] Updating foreground notification...');
          await service.setAsForegroundService();
          await service.setForegroundNotificationInfo(
            title: "🟢 CSChat 실행 중",
            content: "백그라운드에서 메시지를 수신하고 있습니다 • 탭하여 열기",
          );
          print('[BG_LOG] Foreground notification updated');
        } catch (e) {
          print('[BG_LOG] Failed to update foreground notification: $e');
        }
      }
    });
    print('[BG_LOG] Step 10: Event listeners set');
    
    print('[BG_LOG] ===== Background Service Running =====');
    
  } catch (e, stackTrace) {
    print('[BG_LOG] FATAL ERROR: $e');
    print('[BG_LOG] Stack trace: $stackTrace');
    try {
      service.stopSelf();
      print('[BG_LOG] Service stopped after fatal error');
    } catch (_) {
      print('[BG_LOG] Failed to stop service after error');
    }
  }
}

// 백그라운드 메시지 처리 함수
Future<void> _handleBackgroundMessage(
  dynamic data,
  int userId,
  SharedPreferences prefs, {
  bool isNotice = false,
}) async {
  try {
    // SharedPreferences 최신화 (메인 아이솔레이트 변경사항 반영)
    await prefs.reload();
    
    print('[BG_LOG] [MSG] Processing message: $data');
    
    // 현재 보고 있는 방 확인
    final currentRoomId = prefs.getInt('current_room_id');
    print('[BG_LOG] [MSG] Current room ID: $currentRoomId');
    
    // 데이터 파싱
    final senderId = _parseInt(data['senderId'] ?? data['sender_id']);
    final roomId = _parseInt(data['roomId'] ?? data['room_id']);
    print('[BG_LOG] [MSG] Parsed - senderId: $senderId, roomId: $roomId');
    
    // 내가 보낸 메시지 무시
    if (senderId == userId) {
      print('[BG_LOG] [MSG] Skipping my own message');
      return;
    }
    
    // 현재 방이면 알림 생략
    if (currentRoomId != null && roomId == currentRoomId) {
      print('[BG_LOG] [MSG] Skipping notification for current room ($currentRoomId)');
      return;
    }
    
    // 알림 데이터 준비
    final senderName = data['senderName'] ?? data['sender_name'] ?? '알 수 없음';
    final content = data['content'] ?? '사진을 보냈습니다.';
    final isGroup = data['isGroup'] == true || data['is_group'] == 1;
    
    String title = senderName;
    if (isNotice) {
      title = '📢 [긴급] $senderName';
    } else if (isGroup) {
      title = '[그룹] $senderName';
    }
    
    print('[BG_LOG] [MSG] Showing notification - title: $title, content: $content');
    
    // 알림 설정 확인
    final isSoundEnabled = prefs.getBool('isSoundEnabled') ?? true;
    
    // 알림 표시
    await _showBackgroundNotification(
      title: title,
      body: content,
      isSoundEnabled: isSoundEnabled,
      payload: jsonEncode({
        'roomId': roomId,
        'roomName': data['roomName'] ?? (isGroup ? '그룹 채팅' : senderName),
        'isGroup': isGroup,
        'senderId': senderId,
        'senderName': senderName,
      }),
    );
    
    print('[BG_LOG] [MSG] Notification shown successfully');
  } catch (e, stackTrace) {
    print('[BG_LOG] [MSG] ERROR: $e');
    print('[BG_LOG] [MSG] Stack trace: $stackTrace');
  }
}

// 정수 파싱 헬퍼 함수
int _parseInt(dynamic value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

// 백그라운드 알림 표시 함수
Future<void> _showBackgroundNotification({
  required String title,
  required String body,
  required String payload,
  required bool isSoundEnabled,
}) async {
  try {
    print('[BG_LOG] [NOTIF] Initializing notification plugin...');
    final notifications = FlutterLocalNotificationsPlugin();
    
    await notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    print('[BG_LOG] [NOTIF] Plugin initialized');
    
    final channelId = isSoundEnabled ? 'cschat_alert_v16' : 'cschat_silent_v16';
    
    final androidDetails = AndroidNotificationDetails(
      channelId,
      isSoundEnabled ? 'CSChat 알림 (소리/진동)' : 'CSChat 알림 (무음)',
      channelDescription: 'CSChat 메시지 알림',
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: isSoundEnabled,
      vibrationPattern: isSoundEnabled ? Int64List.fromList([0, 500]) : null,
      playSound: isSoundEnabled,
      fullScreenIntent: true,
    );
    
    print('[BG_LOG] [NOTIF] Showing notification (Sound/Vib: $isSoundEnabled)...');
    await notifications.show(
      DateTime.now().microsecondsSinceEpoch % 2147483647,
      title,
      body,
      NotificationDetails(android: androidDetails),
      payload: payload,
    );
    print('[BG_LOG] [NOTIF] Notification displayed successfully');
    
    // 백그라운드 Native Bridge 호출 (시스템 소리/진동 강제 재생)
    if (isSoundEnabled) {
       try {
        const platform = MethodChannel('com.example.cschat/sound');
        await platform.invokeMethod('playNotificationSound');
        print('[BG_LOG] [NOTIF] Native sound/vib triggered');
      } catch (e) {
        print('[BG_LOG] [NOTIF] Native sound/vib error: $e');
      }
    }
  } catch (e) {
    print('[BG_LOG] [NOTIF] ERROR: $e');
  }
}


// OTA 업데이트 서비스
class UpdateService {
  static final UpdateService to = UpdateService._();
  UpdateService._();

  Future<Map<String, dynamic>?> checkForUpdate(String currentVersion, int currentBuild) async {
    try {
      final serverUrl = ConfigService.to.serverUrl;
      final response = await http.get(Uri.parse('$serverUrl/version.json'));
      
      if (response.statusCode == 200) {
        Map<String, dynamic> serverInfo = json.decode(response.body);
        
        // [v2.5.9] 플랫폼별 별도 버전 관리 지원
        if (serverInfo['platforms'] != null) {
          final platformKey = Platform.isAndroid ? 'android' : (Platform.isWindows ? 'windows' : null);
          if (platformKey != null && serverInfo['platforms'][platformKey] != null) {
             final pInfo = Map<String, dynamic>.from(serverInfo['platforms'][platformKey]);
             // 기본 정보(downloadUrl 등)는 유지하되 버전 관련 정보만 덮어씀
             pInfo['downloadUrl'] = serverInfo['downloadUrl'];
             serverInfo = pInfo;
          }
        }

        final serverVersion = serverInfo['version'];
        final serverBuild = serverInfo['buildNumber'] ?? 0;
        
        print('[Update] Current: $currentVersion+$currentBuild, Server: $serverVersion+$serverBuild');
        
        if (_isNewerVersion(serverVersion, serverBuild, currentVersion, currentBuild)) {
          return serverInfo;
        }
      }
    } catch (e) {
      print('[Update] Check failed: $e');
    }
    return null;
  }

  bool _isNewerVersion(String sVer, int sBuild, String cVer, int cBuild) {
    try {
      print('[Update] Compare: S($sVer.$sBuild) vs C($cVer.$cBuild)');
      
      // [Fix] 버전 문자열 정규화 (앞 3부분만 추출하여 비교)
      String normalize(String ver) {
        final parts = ver.split('.');
        if (parts.length > 3) return parts.sublist(0, 3).join('.');
        return ver;
      }

      final nSVer = normalize(sVer);
      final nCVer = normalize(cVer);

      if (nSVer == nCVer) {
        // 주 버전이 같으면 빌드 번호 비교
        // [Fix] 만약 cVer가 4자리 버전(예: 2.0.0.210)이고 cBuild가 0이라면,
        // cVer의 4번째 자리를 빌드 번호로 간주함 (Windows 대응)
        int effectiveCBuild = cBuild;
        final cParts = cVer.split('.');
        if (cBuild == 0 && cParts.length >= 4) {
          effectiveCBuild = int.tryParse(cParts[3]) ?? 0;
        }

        print('[Update] Normalized Match ($nSVer), Comparing Builds: S($sBuild) vs C($effectiveCBuild)');
        return sBuild > effectiveCBuild;
      }
      
      final s = nSVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final c = nCVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      
      // 부족한 부분 채우기
      while (s.length < 3) s.add(0);
      while (c.length < 3) c.add(0);
      
      for (int i = 0; i < 3; i++) {
        if (s[i] > c[i]) return true;
        if (s[i] < c[i]) return false;
      }
      
      // 여기까지 오면 주 버전이 완전히 같은 경우 (normalize 결과가 같지 않았더라도 로직상 동일 판정 시)
      return sBuild > cBuild;
    } catch (e) {
      print('[Update] Compare Error: $e');
      return sVer != cVer || sBuild > cBuild;
    }
  }
}


