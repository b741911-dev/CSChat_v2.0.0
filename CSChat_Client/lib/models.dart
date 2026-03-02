class User {
  final int id;
  final String username;
  bool isOnline; // 온/오프라인 상태
  
  User({
    required this.id,
    required this.username,
    this.isOnline = false,
  });
  
  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'],
      username: json['username'],
      isOnline: json['isOnline'] ?? false,
    );
  }
}

class ChatRoom {
  final int id;
  final String name;
  final bool isGroup;
  final String? lastMessage;
  final String? lastMessageTime;
  final User? otherUser; // 1:1 채팅방의 상대방
  final bool isOnline; // 상대방 온라인 상태 (1:1 채팅방만)
  final int unreadCount; // 읽지 않은 메시지 개수
  final String? roomType; // 방 타입 (public, 1:1, group)
  
  ChatRoom({
    required this.id,
    required this.name,
    required this.isGroup,
    this.lastMessage,
    this.lastMessageTime,
    this.otherUser,
    this.isOnline = false,
    this.unreadCount = 0,
    this.roomType,
  });
  
  factory ChatRoom.fromJson(Map<String, dynamic> json) {
    User? otherUser;
    if (json['otherUser'] != null) {
      otherUser = User.fromJson(json['otherUser']);
    }
    
    return ChatRoom(
      id: json['id'],
      name: json['name'] ?? '',
      isGroup: json['is_group'] == 1,
      lastMessage: json['last_message'],
      lastMessageTime: json['last_message_time'],
      otherUser: otherUser,
      isOnline: json['isOnline'] == true,
      unreadCount: json['unreadCount'] ?? 0,
      roomType: json['room_type'],
    );
  }
}

class ChatMessage {
  final dynamic id; // int 또는 String일 수 있으므로 dynamic 처리
  final int senderId;
  final String? senderName; // 발신자 이름 추가
  String content;
  final String? fileUrl;
  final String? thumbnailUrl; // [Added] 동영상 썸네일 URL
  final String type;
  final int readCount; // 읽음/안읽음 상태
  final String createdAt;

  ChatMessage({
    required this.id,
    required this.senderId,
    this.senderName,
    required this.content,
    this.fileUrl,
    this.thumbnailUrl,
    required this.type,
    required this.readCount,
    required this.createdAt,
  });

  // [Fix] isRead는 서버에서 받은 isRead 필드 또는 readCount 기반 판정
  bool get isRead {
    // 서버에서 isRead 필드를 보냈다면 그것을 사용
    // 아니면 readCount === 0 기준으로 판정
    return readCount == 0;
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    // [Fix] DB의 read_count를 그대로 사용 (서버의 isRead 필드는 무시)
    int msgReadCount = (json['readCount'] ?? json['read_count'] ?? 0) is int
        ? (json['readCount'] ?? json['read_count'] ?? 0)
        : int.tryParse((json['readCount'] ?? json['read_count'] ?? 0).toString()) ?? 0;
    
    return ChatMessage(
      id: json['id'],
      senderId: (json['senderId'] ?? json['sender_id']) is int 
          ? (json['senderId'] ?? json['sender_id']) 
          : int.tryParse((json['senderId'] ?? json['sender_id']).toString()) ?? 0,
      senderName: json['senderName'] ?? json['sender_name'], // 발신자 이름
      content: json['content'] ?? '',
      fileUrl: json['file_url'] ?? json['fileUrl'],
      thumbnailUrl: json['thumbnail_url'] ?? json['thumbnailUrl'],
      type: json['type'] ?? 'text',
      readCount: msgReadCount,
      createdAt: (json['created_at'] ?? json['createdAt'] ?? '').toString(),
    );
  }

  // copyWith 메서드 추가 (읽음 상태 업데이트용)
  ChatMessage copyWith({int? readCount}) {
    return ChatMessage(
      id: id,
      senderId: senderId,
      senderName: senderName,
      content: content,
      fileUrl: fileUrl,
      thumbnailUrl: thumbnailUrl,
      type: type,
      readCount: readCount ?? this.readCount,
      createdAt: createdAt,
    );
  }
}
