# 30초 이중 분할 영상: "One Moon mission, two ways to play" (2026-11-15)
왼쪽 웹(PlayCanvas, https://the-frontier-game.vercel.app), 오른쪽 Roblox. 1920 x 1080, 위 라벨, 아래 자막. 비활성 쪽은 딤드(밝기 약 40%), 전환은 0.4초 페이드. 클립 속도 1.2 ~ 1.5배. 음악과 마지막 편집은 팀이 한다.

| 초 | 화면 | 자막(EN) | 한국어 |
|---|---|---|---|
| 0 ~ 2.5 | 두 타이틀 페이드 인(둘 다 약간 딤드) | The Frontier: one Moon mission, two ways to play. | 하나의 달 미션, 두 가지 방법으로 |
| 2.5 ~ 8.5 | 웹 밝게, Roblox 딤드. 링크 열기, 시작, 착륙, 게임 | Web: open a link and play. No install, any device. | 웹: 링크만 열면 바로, 설치 없이 어디서나 |
| 8.5 ~ 14.5 | Roblox 밝게, 웹 딤드. 착륙, HUD, 로버 운전, 그린하우스 | Roblox: team up with friends as Mission Control, Explorer and Engineer. | 로블록스: 친구와 역할을 나눠 함께 |
| 14.5 ~ 20.5 | 둘 다 밝게. 웹 태양광과 얼음, Roblox SEP 경보와 실제 날짜 | Same rules, real NASA data: lunar terrain and space weather. | 같은 규칙, 실제 NASA 데이터 |
| 20.5 ~ 25.5 | 번갈아: 웹 건설, Roblox 금메달 결과 | Build, survive, earn your medal. | 짓고, 버티고, 메달을 따요 |
| 25.5 ~ 30 | 두 화면 페이드 아웃, 마지막 카드 | Web for access. Roblox for teamwork. | 웹은 누구나, 로블록스는 함께 |

- Roblox 촬영(팀): R1 타이틀에서 착륙(촬영 완료, 바탕화면 1~2번 영상), R2 로버 운전, R3 그린하우스 솟아오름, R4 SEP 경보, R5 금메달 결과, 선택 R6 2인 역할 선택.
- 웹 촬영(Claude, Playwright 녹화 1280 x 720 25fps): W1 타이틀, W2 챕터 선택, W3 착륙, W4 게임 HUD와 태양광 설치, W5 로버 또는 얼음.
- 합성: ffmpeg(이중 분할, 딤드, 페이드, 자막). 결과는 음악 없는 30초 mp4.
