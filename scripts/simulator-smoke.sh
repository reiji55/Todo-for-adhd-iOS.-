#!/bin/bash
set -euo pipefail

DEVICE_FAMILY="${1:-iPhone}"
case "$DEVICE_FAMILY" in iPhone|iPad) ;; *) echo "Expected iPhone or iPad"; exit 1 ;; esac
RESULT_DIR="ci-results/$DEVICE_FAMILY"
mkdir -p "$RESULT_DIR"
xcrun simctl list devices available --json > "$RESULT_DIR/simulators.json"
SIMULATOR_ID=$(python3 - "$RESULT_DIR/simulators.json" "$DEVICE_FAMILY" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    groups = json.load(f)['devices']
family = sys.argv[2]
devices = [d for runtime, devices in groups.items() if '.iOS-' in runtime
           for d in devices if d.get('isAvailable') and family in d['name']]
if not devices:
    raise SystemExit(f'No available {family} simulator runtime')
if family == 'iPad':
    devices.sort(key=lambda d: (not ('13-inch' in d['name'] or '12.9-inch' in d['name']), d['name']))
else:
    devices.sort(key=lambda d: (not ('SE' in d['name']), d['name']))
print(devices[0]['udid'])
PY
)

# A launch that hangs must give up within four minutes and leave a stack sample of the app, instead of
# silently using up the whole job. (A cold simulator's first launch can take over a minute on a busy runner.)
# It is tried once more, so a simulator hiccup alone does not fail the run.
launch() {
  local attempt pid
  for attempt in 1 2; do
    if perl -e 'alarm shift; exec @ARGV' 240 xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" \
        io.github.reiji55.threedays -AppleLanguages '(ja)' -AppleLocale ja_JP "$@"; then return 0; fi
    echo "::warning::Launch with $* did not finish (attempt $attempt)" >&2
    pid=$(pgrep -f 'ThreeDays.app/ThreeDays' | head -1 || true)
    if [ -n "$pid" ]; then
      ps -o pid,%cpu,stat,etime -p "$pid" >&2 || true
      sample "$pid" 3 2>/dev/null | head -120 >&2 || true
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  echo "::error::Launch with $* failed twice" >&2
  return 1
}

cleanup() { xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$SIMULATOR_ID" || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
APP_PATH=DerivedData/Build/Products/Debug-iphonesimulator/ThreeDays.app
python3 - "$APP_PATH/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
assert set(info['UIDeviceFamily']) == {1, 2}, 'App must support iPhone and iPad natively'
expected = {'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
            'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'}
assert set(info['UISupportedInterfaceOrientations~ipad']) == expected
assert not info.get('UIRequiresFullScreen', False), 'iPad multitasking must remain available'
assert info.get('CKSharingSupported') is True, 'CloudKit invitations must be supported'
assert 'remote-notification' in info.get('UIBackgroundModes', []), 'Silent sync refresh must be enabled'
assert any('horme' in t.get('CFBundleURLSchemes', []) for t in info.get('CFBundleURLTypes', [])), 'Widgets need the horme:// links'
import os
with open(os.path.join(os.path.dirname(sys.argv[1]), 'PlugIns/HormeWidgets.appex/Info.plist'), 'rb') as f:
    widget = plistlib.load(f)
assert widget['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension', 'Widget extension must be embedded'
assert widget['CFBundleIdentifier'] == info['CFBundleIdentifier'] + '.widgets'
assert widget['CFBundleVersion'] == info['CFBundleVersion'] and widget['CFBundleShortVersionString'] == info['CFBundleShortVersionString']
print('Verified universal device family, all iPad orientations, multitasking metadata, and the embedded widgets')
PY
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

# Add sample data only to an empty simulator container; never replace existing data.
SIMULATOR_DATA=$(xcrun simctl get_app_container "$SIMULATOR_ID" io.github.reiji55.threedays data)
python3 - "$SIMULATOR_DATA" <<'PY'
from pathlib import Path
from datetime import datetime, timedelta, timezone
import json, sys, uuid
path = Path(sys.argv[1]) / 'Library/Application Support/ThreeDays/notebook.json'
if path.exists():
    raise SystemExit(0)
now = datetime.now(timezone.utc)
def date(value):
    return value.strftime('%Y-%m-%dT%H:%M:%SZ')
def task(title, **changes):
    item = dict(id=str(uuid.uuid4()), title=title, plannedAt=date(now),
                scheduledTime='', isMust=False, effort='light', project='',
                memo='', handoff='', resumeNote='', steps=[], createdAt=date(now))
    item.update(changes)
    return item
M_COUNT = str(uuid.uuid4()).upper()
M_TASKS = str(uuid.uuid4()).upper()
tasks = [
    task('提出書類を送る', isMust=True, deadline=date(now),
         steps=[dict(id=str(uuid.uuid4()), title='宛先を確認する', isDone=False)]),
    task('予約の電話をする', isMust=True, scheduledTime='14:00-14:15'),
    task('住民票を取りに行く', isMust=True, plannedAt=None, deadline=date(now + timedelta(days=2)), effort='medium'),
    task('部屋をリセットする', scheduledTime='21:00-21:15', project='部屋'),
    task('提案の下書きをつくる', deadline=date(now + timedelta(days=1)), effort='heavy'),
    task('読みかけの本を読む', resumeNote='42ページの途中まで'),
    task('気になる資料を読む', effort='medium'),
    task('友達とランチ', scheduledTime='12:00-13:30', isEvent=True),
    task('買い物に行く', plannedAt=date(now + timedelta(days=1)), isEvent=True),
    task('提案の下書き 見出し3つ', project='仕事', scheduledTime='10:00-11:30', plannedAt=date(now + timedelta(days=1))),
    task('歯医者の予約', scheduledTime='13:00-13:30', plannedAt=date(now + timedelta(days=2))),
    task('予想問題 第4回を解く', project='TOEIC', scheduledTime='20:30-21:30', milestoneID=M_COUNT),
    task('Part7 時間を計って10問', project='TOEIC', completedAt=date(now - timedelta(days=1)), milestoneID=M_TASKS),
    task('長文を1本解き直す', project='TOEIC', plannedAt=date(now + timedelta(days=1)), milestoneID=M_TASKS),
    task('公式問題集の音声を落とす', project='TOEIC', plannedAt=None, milestoneID=M_TASKS),
    task('TOEIC 本番', project='TOEIC', plannedAt=date(now + timedelta(days=41)), isEvent=True),
]
# A task in pieces: the pieces carry the days, the task its deadline.
P_PROPOSAL = str(uuid.uuid4()).upper()
tasks += [
    task('提案書をつくる', id=P_PROPOSAL, plannedAt=None, project='仕事', deadline=date(now + timedelta(days=2)), effort='heavy'),
    task('構成を決める', parentID=P_PROPOSAL, rank=0, project='仕事', plannedAt=date(now - timedelta(days=1)),
         completedAt=date(now - timedelta(days=1))),
    task('見出しを3つ書く', parentID=P_PROPOSAL, rank=1, project='仕事', scheduledTime='15:00-16:00'),
    task('本文を書く', parentID=P_PROPOSAL, rank=2, project='仕事', plannedAt=date(now + timedelta(days=1))),
]
def milestone(title, kind, **changes):
    item = dict(id=str(uuid.uuid4()).upper(), title=title, kind=kind, target=1, current=0, unit='', isDone=False,
                createdAt=date(now - timedelta(days=20)))
    item.update(changes)
    return item
count_ms = milestone('予想問題を解く', 'count', target=5, current=3, unit='回')
tasks_ms = milestone('Part7を時間内に解く', 'tasks')
count_ms['id'] = M_COUNT; tasks_ms['id'] = M_TASKS
projects = [dict(id=str(uuid.uuid4()), name='TOEIC', goal='本番で500点', deadline=date(now + timedelta(days=41)), origin='',
                 overview='11月は実測を兼ねた本番。単語は毎日少しずつ、長文は時間を計って解く。',
                 createdAt=date(now - timedelta(days=20)), milestones=[
                     milestone('単語帳（金フレ）を1周する', 'check', isDone=True), count_ms,
                     milestone('模試で450点', 'number', target=450, current=420, unit='点'), tasks_ms])]
cards = [
    dict(id=str(uuid.uuid4()), title='TOEIC対策', project='TOEIC', createdAt=date(now - timedelta(days=30)),
         purpose='11月は実測を兼ねた本番。形式と時間配分を体に入れる。',
         goal='11月の試験で650点。',
         detail='━━━ 90分の使い方 ━━━\n\n■ 20分 ── 単語（金フレ）\n■ 40分 ── 隔日で交互に\n■ 30分 ── Part7 を時間を計って精読\n\n━━━ 単語のやり方 ━━━\n\n1. 日本語側を赤シートで隠す\n2. 英語を見て2秒で意味を言う\n3. 出なければ即×。粘らない'),
    dict(id=str(uuid.uuid4()), title='瞑想手法', createdAt=date(now - timedelta(days=20)),
         purpose='タスク中の思考の散らかりを抑える', goal='', detail='【朝：3分｜呼吸カウント】\n吐くたびに1から10まで数える'),
]
path.parent.mkdir(parents=True, exist_ok=True)
def routine(title, time, **changes):
    item = dict(id=str(uuid.uuid4()), title=title, project='', memo='', weekdays=[1, 2, 3, 4, 5, 6, 7], time=time,
                notify=True, isBlock=False, isPaused=False, createdAt=date(now - timedelta(days=30)), doneDays=[], moves={})
    item.update(changes)
    return item
routines = [
    routine('金フレ 未チェック語を回す', '19:00-20:30', project='TOEIC', weekdays=[2, 3, 4, 5, 6]),
    routine('睡眠', '0:00-7:00', isBlock=True, notify=False),
    routine('仕事（通勤含む）', '8:00-18:00', isBlock=True, notify=False, weekdays=[2, 3, 4, 5]),
]
def idea(text, written, touched=None, notes=()):
    item = dict(id=str(uuid.uuid4()), text=text, createdAt=date(now - timedelta(days=written)),
                notes=[dict(id=str(uuid.uuid4()), text=line, createdAt=date(now - timedelta(days=ago))) for line, ago in notes])
    if touched is not None:
        item['touchedAt'] = date(now - timedelta(days=touched))
    return item
ideas = [
    idea('散歩中に聞ける勉強メモを作れそう', 2, 0, [('金フレの音声を流用できるか調べる', 1), ('1本5分くらいの長さにする', 0)]),
    idea('部屋の配置を変えて、机を窓際に', 1, 1),
    idea('TOEICの単語、通勤中にアプリで回せないか', 4),
    idea('誕生日プレゼント、イヤホンケースはどうか', 16),
]
path.write_text(json.dumps(dict(version=1, tasks=tasks, ideas=ideas, boardCards=cards, routines=routines, projects=projects), ensure_ascii=False))
PY
launch -uiNoPrompt | tee "$RESULT_DIR/launch.txt"
sleep 5
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/today.png"
python3 - "$SIMULATOR_DATA" <<'PY'
from pathlib import Path
import json, sys, time
directory = Path(sys.argv[1]) / 'Library/Application Support/ThreeDays'
legacy = json.loads((directory / 'notebook.json').read_text())
# Steps become child tasks just after launch; a slow simulator may not have saved that yet.
deadline = time.time() + 30
while True:
    try:
        state = json.loads((directory / 'horme-state.json').read_text())
        if not any(t.get('steps') for t in state['notebook']['tasks']):
            break
    except (FileNotFoundError, json.JSONDecodeError):
        state = None
    if time.time() > deadline:
        break
    time.sleep(1)
assert state is not None, 'The app must save its state after launch'
tasks = state['notebook']['tasks']
by_id = {t['id'].lower(): t for t in tasks}
legacy_ids = {t['id'].lower() for t in legacy['tasks']}
assert legacy_ids <= set(by_id), 'Task identities must survive UUID normalization'
assert all(by_id[t['id'].lower()]['title'] == t['title'] for t in legacy['tasks']), 'Task text must survive migration'
# Steps from before parent and child tasks become child tasks, keeping their IDs; nothing else is added.
step_ids = {s['id'].lower() for t in legacy['tasks'] for s in t.get('steps', [])}
added = [t for t in tasks if t['id'].lower() not in legacy_ids]
assert {t['id'].lower() for t in added} == step_ids, 'Steps must become child tasks, and only they'
assert all(t.get('parentID') for t in added), 'Child tasks must point to their task'
assert not any(t.get('steps') for t in tasks), 'No steps may remain'
assert [c['title'] for c in state['notebook']['boardCards']] == [c['title'] for c in legacy['boardCards']], 'Board cards must survive migration'
assert len(state['notebook']['routines']) == len(legacy['routines']), 'Routines must survive migration'
assert state.get('connection') is None, 'Sharing must require user setup'
print('Verified atomic migration of existing tasks; cloud sync stays off until configured')
PY
# The いま card once a condition is chosen (the first capture asks for it when the time is free).
launch -uiTab 2 -uiEnergy high >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/now-card.png"
# Where the main thread is while the いま screen shows, to catch a stuck layout.
pid=$(pgrep -f 'ThreeDays.app/ThreeDays' | head -1 || true)
if [ -n "$pid" ]; then
  echo "== main thread of the app on the いま screen ($DEVICE_FAMILY)"
  sample "$pid" 2 2>/dev/null | sed -n '/Thread_[0-9]*.*DispatchQueue_1: com.apple.main-thread/,/^ *[0-9]* Thread_/p' | head -120 || true
fi
launch -horme-settings-preview
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/sharing-settings.png"
# -uiTab and -uiOpenFirstCard exist only in Debug builds, for these captures.
launch -uiTab 1 >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/week.png"
launch -uiTab 1 -uiWeekSheetOpen >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/week-sheet.png"
launch -uiTab 1 -uiWeekSheetFull >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/week-sheet-full.png"
launch -uiTab 0 >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/all.png"
launch -uiTab 3 >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/ideas.png"
launch -uiTab 3 -uiOpenFirstIdea >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/idea-open.png"
launch -uiTab 3 -uiSortIdeas >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/sort-ideas.png"
launch -uiTab 4 >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/board.png"
launch -uiTab 4 -uiOpenFirstCard >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/board-card.png"
launch -uiTab 4 -uiOpenFirstProject >/dev/null
sleep 5
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/project.png"
launch -uiTab 4 -uiOpenFirstProject -uiProjectWay >/dev/null
sleep 5
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/project-way.png"
launch -uiTab 2 -uiOpenRoutine >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/routine-edit.png"
launch -uiTab 2 -uiQuickAdd >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/quick-add.png"
launch -uiTab 2 -uiOpenTask >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/task-edit.png"
launch -uiTab 2 -uiTimetable >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/timetable.png"
# Shown as ended without saving it, so the launches after this one start open.
launch -uiTab 2 -uiDayClosed >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/day-closed.png"
# Last: starting a task leaves it running in the saved sample data.
launch -uiTab 2 -uiFocus >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/focus.png"
# Screenshots and launch logs verify startup and layout, not every interaction.
