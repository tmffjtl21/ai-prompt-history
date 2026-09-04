# ai-prompt-history

Claude Code 와 나눈 하루치 대화를 요약해 날짜별 작업 일지로 남기는 저장소입니다.

```
2026/
  2026-09-04.md      # 하루 작업 일지 (자동 생성)
tools/
  worklog-daily.ps1  # 수집 → 요약 → 커밋·푸시
  summarize-prompt.md# 요약 형식과 규칙 (여기를 고치면 일지 형식이 바뀝니다)
.work/               # 원문 대화 추출본과 실행 로그 (git 제외)
```

## 동작 방식

1. `%USERPROFILE%\.claude\projects\*\*.jsonl` 에 남는 Claude Code 세션 기록에서 그날(로컬 기준 00:00~24:00)의 사용자 질문과 AI 답변만 골라냅니다. 도구 호출, 도구 결과, 서브에이전트 대화는 뺍니다.
2. 토큰·비밀번호·JWT 같은 값은 `***` 로 가린 뒤 `.work/<날짜>.transcript.md` 에 저장합니다.
3. `claude -p` 를 헤드리스로 실행해 `tools/summarize-prompt.md` 형식대로 `<연도>/<날짜>.md` 를 씁니다. 이 실행은 세션을 남기지 않으므로 다음 날 요약에 섞이지 않습니다.
4. 생성된 파일을 커밋하고 `origin` 이 있으면 푸시합니다.

## 예약 실행

Windows 작업 스케줄러에 `AI Prompt History Daily` 작업을 매일 09:00 로 등록해 전날 기록을 정리합니다. PC 가 꺼져 있었으면 다음 부팅 후 바로 실행됩니다.

```powershell
# 최초 1회 등록 (관리자 권한 불필요, 같은 이름이 있으면 교체)
powershell -NoProfile -ExecutionPolicy Bypass -File C:\dev\ai-prompt-history\tools\register-task.ps1
# 상태 확인
Get-ScheduledTask -TaskName 'AI Prompt History Daily' | Get-ScheduledTaskInfo
# 지금 바로 실행
Start-ScheduledTask -TaskName 'AI Prompt History Daily'
```

## 수동 실행

```powershell
# 전날
powershell -NoProfile -ExecutionPolicy Bypass -File C:\dev\ai-prompt-history\tools\worklog-daily.ps1
# 특정 날짜, 기존 파일 덮어쓰기
powershell -NoProfile -ExecutionPolicy Bypass -File C:\dev\ai-prompt-history\tools\worklog-daily.ps1 -Date 2026-09-04 -Force
# 푸시 없이
powershell -NoProfile -ExecutionPolicy Bypass -File C:\dev\ai-prompt-history\tools\worklog-daily.ps1 -NoPush
```

실행 로그는 `.work/run.log` 에 쌓입니다.
