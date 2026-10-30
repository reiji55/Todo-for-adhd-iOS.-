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
print('Verified universal device family, all iPad orientations, and multitasking metadata')
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
tasks = [
    task('提出書類を送る', isMust=True, deadline=date(now),
         steps=[dict(id=str(uuid.uuid4()), title='宛先を確認する', isDone=False)]),
    task('予約の電話をする', isMust=True),
    task('提案の下書きをつくる', deadline=date(now + timedelta(days=1)), effort='heavy'),
    task('読みかけの本を読む', resumeNote='42ページの途中まで'),
    task('気になる資料を読む', effort='medium'),
    task('週末の買い物を考える', plannedAt=date(now + timedelta(days=1))),
    task('提案の下書き 見出し3つ', project='仕事', scheduledTime='10:00-11:30', plannedAt=date(now + timedelta(days=1))),
    task('歯医者の予約', scheduledTime='13:00-13:30', plannedAt=date(now + timedelta(days=2))),
]
cards = [
    dict(id=str(uuid.uuid4()), title='TOEIC対策', createdAt=date(now - timedelta(days=30)),
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
path.write_text(json.dumps(dict(version=1, tasks=tasks, ideas=[], boardCards=cards, routines=routines), ensure_ascii=False))
PY
xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" io.github.reiji55.threedays -AppleLanguages '(ja)' -AppleLocale ja_JP -uiNoPrompt | tee "$RESULT_DIR/launch.txt"
sleep 5
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/today.png"
python3 - "$SIMULATOR_DATA" <<'PY'
from pathlib import Path
import json, sys
directory = Path(sys.argv[1]) / 'Library/Application Support/ThreeDays'
legacy = json.loads((directory / 'notebook.json').read_text())
state = json.loads((directory / 'horme-state.json').read_text())
assert [t['id'].lower() for t in state['notebook']['tasks']] == [t['id'].lower() for t in legacy['tasks']], 'Task identities must survive UUID normalization'
assert [t['title'] for t in state['notebook']['tasks']] == [t['title'] for t in legacy['tasks']], 'Task text must survive migration'
assert len(state['notebook']['tasks']) == len(legacy['tasks']), 'Existing sample tasks must survive migration'
assert [c['title'] for c in state['notebook']['boardCards']] == [c['title'] for c in legacy['boardCards']], 'Board cards must survive migration'
assert len(state['notebook']['routines']) == len(legacy['routines']), 'Routines must survive migration'
assert state.get('connection') is None, 'Sharing must require user setup'
print('Verified atomic migration of existing tasks; cloud sync stays off until configured')
PY
xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" io.github.reiji55.threedays -AppleLanguages '(ja)' -AppleLocale ja_JP -horme-settings-preview
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/sharing-settings.png"
# -uiTab and -uiOpenFirstCard exist only in Debug builds, for these captures.
xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" io.github.reiji55.threedays -AppleLanguages '(ja)' -AppleLocale ja_JP -uiTab 1 >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/week.png"
xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" io.github.reiji55.threedays -AppleLanguages '(ja)' -AppleLocale ja_JP -uiTab 4 >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/board.png"
xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" io.github.reiji55.threedays -AppleLanguages '(ja)' -AppleLocale ja_JP -uiTab 4 -uiOpenFirstCard >/dev/null
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot "$RESULT_DIR/board-card.png"
# Screenshots and launch logs verify startup and layout, not every interaction.
