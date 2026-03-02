# 프로젝트 규칙 (Project Rules)

## 1. 언어 및 문서화 (Language and Documentation)
- **주 언어**: 모든 대화, 설명, 주석, 문서는 반드시 **한국어(Korean)**로 작성합니다.
- **코드**: 변수명, 함수명 등은 영어를 사용하되, 주석은 한국어로 작성하여 이해를 돕습니다.
- **작업 내역**: `work_history.md`에 작업 내역을 기록합니다.

## 2. 자동화 및 자율성 (Automation & Autonomy)
- **자율 실행 (Autonomous Execution)**: 사용자에게 "수락"을 기다리지 않고 터미널 명령어를 실행하거나 파일을 수정합니다. 작업이 명확하다면 즉시 다음 단계로 진행합니다.
- **터보 모드 (Turbo Mode)**: 항상 속도와 작업 완료를 최우선으로 하는 '터보' 모드로 동작합니다. 시스템에 파괴적인 명령어(예: 루트 디렉토리 삭제)가 아닌 이상 확인을 위해 멈추지 않습니다.
- **효율적인 워크플로우 (Streamlined Workflow)**: 목표 달성을 위해 필요한 파일 생성, 수정, 삭제를 자율적으로 수행합니다.

## 3. 버전 관리 및 정책 (Versioning & Policy)
- **참조 파일**: 작업 시 항상 `VERSION_HISTORY.md`와 `VERSION_POLICY.md`를 참조하여 버전 규칙을 준수합니다.
- **버전 업데이트**: 기능 변경이나 수정 사항이 있을 경우 `VERSION_HISTORY.md`를 업데이트합니다.

## 4. 작업 우선순위 (Task Prioritization)
- 사용자의 요청사항(프롬프트)을 최우선으로 처리합니다.
- `project_rules.md` 파일이 존재할 경우, 이 파일의 규칙이 전역 설정보다 우선합니다.
- **규칙 준수**: 본 파일(`project_rules.md`)의 모든 내용을 항상 최우선으로 적용해야 합니다.

## 5. 기술 스택 및 최신 기술 (Technology Stack & Updates)
- **Context7 적용**: **Context7 최신 기술 자료**를 적극적으로 검토하고, 이를 코드와 구현에 반영하도록 합니다.

## 6. 디자인 원칙 (Design Principle)
- **기본 컨셉 유지**: 새로운 기능을 추가하거나 코드를 개선할 때, **기존의 디자인 컨셉(vibrant colors, glassmorphism, dynamic animations 등)을 반드시 유지**하고 일관성을 지켜야 합니다.
- **UI/UX 일관성**: 모든 사용자 인터페이스는 기존의 디자인 가이드를 따라서 통일감 있게 구현합니다.
