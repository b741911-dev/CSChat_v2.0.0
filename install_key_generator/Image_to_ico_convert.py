from PIL import Image
import os

# 1. 원본 이미지 파일명 (생성하신 이미지 파일명으로 수정하세요)
input_image = "logo.png" 
output_icon = "icon.ico"

if os.path.exists(input_image):
    img = Image.open(input_image)
    # 윈도우 표준 아이콘 사이즈들을 모두 포함하여 고화질로 저장
    img.save(output_icon, format='ICO', sizes=[(256, 256), (128, 128), (64, 64), (32, 32), (16, 16)])
    print(f"✅ 변환 완료! '{output_icon}' 파일이 생성되었습니다.")
else:
    print(f"❌ 오류: '{input_image}' 파일을 찾을 수 없습니다. 파일명을 확인해주세요.")