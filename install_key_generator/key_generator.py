import tkinter as tk
from tkinter import messagebox
import hmac
import hashlib
import base64
import os
import sys

def resource_path(relative_path):
    """ Get absolute path to resource, works for dev and for PyInstaller """
    try:
        # PyInstaller creates a temp folder and stores path in _MEIPASS
        base_path = sys._MEIPASS
    except Exception:
        base_path = os.path.abspath(".")

    return os.path.join(base_path, relative_path)

# ==========================================
# [보안] 나만의 비밀키 (이전과 동일하게 유지)
# ==========================================
SECRET_KEY = b"CHANGE_THIS_TO_YOUR_OWN_SECRET_KEY"

def generate_license_key(uuid_str, serial_str):
    try:
        if not uuid_str or not serial_str:
            raise ValueError("입력값이 비어있습니다.")
        data_to_hash = (uuid_str.strip() + serial_str.strip()).encode('utf-8')
        signature = hmac.new(SECRET_KEY, data_to_hash, hashlib.sha256).digest()
        encoded_signature = base64.b32encode(signature).decode('utf-8')
        clean_key = encoded_signature.replace('=', '')[:16].upper()
        return '-'.join(clean_key[i:i+4] for i in range(0, len(clean_key), 4))
    except Exception as e:
        messagebox.showerror("Error", str(e))
        return None

def on_generate():
    generated_key = generate_license_key(entry_uuid.get(), entry_serial.get())
    if generated_key:
        entry_result.config(state='normal')
        entry_result.delete(0, tk.END)
        entry_result.insert(0, generated_key)
        entry_result.config(state='readonly')
        root.clipboard_clear()
        root.clipboard_append(generated_key)
        status_label.config(text="✔ 키가 생성되었으며 클립보드에 복사되었습니다.", fg="#a6e3a1")

# ==========================================
# UI 테마 설정 (Modern Dark Theme)
# ==========================================
BG_COLOR = "#1e1e2e"       # 메인 배경 (짙은 네이비)
CARD_COLOR = "#313244"     # 입력창 배경
TEXT_COLOR = "#cdd6f4"     # 메인 글자색
ACCENT_COLOR = "#89b4fa"   # 강조색 (파스텔 블루)
BTN_COLOR = "#a6e3a1"      # 버튼색 (에메랄드 그린)
BTN_TEXT = "#11111b"       # 버튼 글자색

# ==========================================
# UI 테마 및 중앙 배치 설정
# ==========================================
root = tk.Tk()
root.title("CSChat License Manager")

# 1. 앱의 가로, 세로 크기 설정
window_width = 500
window_height = 450

# 2. 모니터 해상도(가로, 세로) 가져오기
screen_width = root.winfo_screenwidth()
screen_height = root.winfo_screenheight()

# 3. 중앙 좌표 계산
# (모니터 가로 - 앱 가로) / 2 , (모니터 세로 - 앱 세로) / 2
center_x = int((screen_width - window_width) / 2)
center_y = int((screen_height - window_height) / 2)

# 4. geometry 설정 (가로x세로+x좌표+y좌표)
root.geometry(f"{window_width}x{window_height}+{center_x}+{center_y}")

root.configure(bg=BG_COLOR)
root.resizable(False, False)
# 윈도우 아이콘 설정 (아이콘 파일이 같은 폴더에 있을 경우)
try:
    root.iconbitmap(resource_path("icon.ico"))
except:
    pass

main_container = tk.Frame(root, bg=BG_COLOR, padx=30, pady=30)
main_container.pack(fill=tk.BOTH, expand=True)

from PIL import Image, ImageTk  # 아이콘을 불러오기 위해 필요합니다.

# ==========================================
# 헤더 타이틀 섹션 (수동 미세 조정형)
# ==========================================
header_frame = tk.Frame(main_container, bg=BG_COLOR)
header_frame.pack(pady=(0, 25))

# 1. 아이콘 레이블 (40px로 키워 볼륨감을 확보)
try:
    icon_img = Image.open(resource_path("icon.ico"))
    icon_img = icon_img.resize((40, 40), Image.Resampling.LANCZOS)
    render_img = ImageTk.PhotoImage(icon_img)
    
    img_label = tk.Label(header_frame, image=render_img, bg=BG_COLOR)
    img_label.image = render_img
    
    # [조정 포인트 1] pady=(상단, 하단) 
    # 아이콘이 글자보다 위로 떠 보인다면, 첫 번째 숫자(4)를 1씩 키워보세요.
    img_label.pack(side=tk.LEFT, pady=(4, 0)) 
except:
    img_label = tk.Label(header_frame, text="🛡️", font=("Segoe UI", 20), bg=BG_COLOR, fg=ACCENT_COLOR)
    img_label.pack(side=tk.LEFT, pady=(4, 0))

# 2. 타이틀 텍스트 레이블
title_label = tk.Label(header_frame, text="License Key Generator", 
                       font=("Segoe UI", 18, "bold"), bg=BG_COLOR, fg=ACCENT_COLOR)

# [조정 포인트 2] padx=(왼쪽, 오른쪽)
# 아이콘과 글자가 너무 가깝거나 멀면 첫 번째 숫자(5)를 조절하세요.
title_label.pack(side=tk.LEFT, padx=(5, 0))# 입력 필드 스타일 함수
def create_label(text):
    return tk.Label(main_container, text=text, font=("Segoe UI", 10, "bold"), 
                    bg=BG_COLOR, fg=TEXT_COLOR)

def create_entry():
    return tk.Entry(main_container, font=("Consolas", 11), bg=CARD_COLOR, 
                    fg="white", insertbackground="white", borderwidth=0, highlightthickness=1,
                    highlightbackground="#45475a", highlightcolor=ACCENT_COLOR)

# 1. UUID 섹션
create_label("DEVICE UUID").pack(anchor='w')
entry_uuid = create_entry()
entry_uuid.pack(fill=tk.X, pady=(5, 15), ipady=8)
entry_uuid.insert(0, "{C0D43105-C266-42F9-B4C3-02DCF1EFE5D5}")

# 2. Serial 섹션
create_label("SERIAL NUMBER").pack(anchor='w')
entry_serial = create_entry()
entry_serial.pack(fill=tk.X, pady=(5, 25), ipady=8)
entry_serial.insert(0, "CS-2026-REG-001")

# 3. 생성 버튼 (Hover 효과 추가)
def on_enter(e): btn_gen['background'] = '#94e2d5'
def on_leave(e): btn_gen['background'] = BTN_COLOR

btn_gen = tk.Button(main_container, text="GENERATE LICENSE KEY", font=("Segoe UI", 11, "bold"),
                    bg=BTN_COLOR, fg=BTN_TEXT, activebackground="#94e2d5", 
                    cursor="hand2", borderwidth=0, command=on_generate)
btn_gen.pack(fill=tk.X, ipady=12)
btn_gen.bind("<Enter>", on_enter)
btn_gen.bind("<Leave>", on_leave)

# 4. 결과 출력 섹션
tk.Label(main_container, text="GENERATED KEY", font=("Segoe UI", 10, "bold"), 
         bg=BG_COLOR, fg=TEXT_COLOR).pack(anchor='w', pady=(25, 5))
entry_result = tk.Entry(main_container, font=("Courier New", 15, "bold"), bg=BG_COLOR, 
                        fg=ACCENT_COLOR, borderwidth=0, justify='center', state='readonly')
entry_result.pack(fill=tk.X)

# 구분선 역할의 하단 강조선
tk.Frame(main_container, height=2, bg=ACCENT_COLOR).pack(fill=tk.X, pady=5)

# 하단 상태 표시
status_label = tk.Label(main_container, text="Ready to secure your application", 
                        font=("Segoe UI", 9), bg=BG_COLOR, fg="#6c7086")
status_label.pack(pady=(10, 0))

root.mainloop()