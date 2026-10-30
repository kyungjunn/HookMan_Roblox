# HOOKMAN

3D 훅 스윙 러너. 건물 사이 로프 진자, 상승 30° 릴리즈, 존 해금 성장.

로비에서 장비 장착 → 존 선택 → 개인 코스 스윙 → 골 완주 정산.

손맛은 클라, 점수·코인·해금은 서버.

## 설계

- **권한 분리** — 클라: 입력·로프·연출·UI. 서버: 훅 소유·판정·콤보·점수·저장. 공유: 수식·카탈로그.
- **런 = 상태기계** — 플레이어당 런 1개, 개인 코스 1개. `HookmanStage`만 전이.
- **성장 삼축** — 누적점수→존 해금, 코인→상점, 최고점→랭킹. 섞지 않음.
- **합성** — 상속 없음. ModuleScript + Remote. 순환 require는 콜백으로 끊음.

## 구조

```text
src/
  ServerScriptService/          런, 코스, 훅 검증, 경제, 저장, 랭킹, 로비
  ReplicatedStorage/Hookman/    설정, 판정, 보상, 경로, 카탈로그, 연출
  StarterPlayer/.../Hookman/    스윙 입력, 상점 UI
tests/                          규칙, 랭킹, 장소 라운드트립, Studio 통합
tools/                          rbxl 패키징, Studio 동기화
Hookman.rbxl                    실행용 장소
```

## 기능

- Q/E 훅 부착, 홀드 조향, Space 릴리즈, RopeConstraint 진자
- PERFECT / GREAT / GOOD / MISS, 서버 관측 재평가, 훅당 1회 득점
- 체크포인트, 장애물, 골 면. 낙하=리셋, 사망·포기=종료(코인 없음)
- 존 5곳, 훅/오오라/능력 상점, 듀얼 로프
- 프로필 세션 리스, 최고점 OrderedDataStore 랭킹
