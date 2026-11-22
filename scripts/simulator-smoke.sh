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

# A capture taken before the app has drawn (a slow simulator, often the iPad just after it boots) is blank;
# it is taken again after a short wait, up to five times.
shot() {
  local file="$RESULT_DIR/$1.png" attempt
  for attempt in 1 2 3 4 5; do
    perl -e 'alarm shift; exec @ARGV' 60 xcrun simctl io "$SIMULATOR_ID" screenshot "$file" \
      || { echo "::warning::$1 could not be captured within a minute" >&2; return 0; }
    python3 -I scripts/screen_is_blank.py "$file" || return 0
    echo "::warning::$1 was captured before the app drew (attempt $attempt)" >&2
    sleep 3
  done
}

cleanup() { xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# A simulator that never finishes booting (seen on the iPad on busy runners) used to hold the step until the
# whole job ran out of time. Booting gets five minutes; then the device is wiped and booted once more.
boot() {
  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  perl -e 'alarm shift; exec @ARGV' 300 xcrun simctl bootstatus "$SIMULATOR_ID" -b
}
if ! boot; then
  echo "::warning::$DEVICE_FAMILY simulator did not finish booting; wiping it and trying once more" >&2
  xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  xcrun simctl erase "$SIMULATOR_ID" >/dev/null 2>&1 || true
  boot
fi
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
with open(os.path.join(os.path.dirname(sys.argv[1]), 'PlugIns/HormeShare.appex/Info.plist'), 'rb') as f:
    share = plistlib.load(f)
assert share['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.share-services', 'Share extension must be embedded'
assert share['CFBundleIdentifier'] == info['CFBundleIdentifier'] + '.share'
assert share['CFBundleVersion'] == info['CFBundleVersion'] and share['CFBundleShortVersionString'] == info['CFBundleShortVersionString']
print('Verified universal device family, all iPad orientations, multitasking metadata, the embedded widgets and share extension')
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
    task('保険の書類を出す', isMust=True, deadline=date(now),
         steps=[dict(id=str(uuid.uuid4()), title='必要なところを記入する', isDone=False)]),
    task('美容院の予約をする', isMust=True, scheduledTime='14:00-14:15'),
    task('住民票を取りに行く', isMust=True, plannedAt=None, deadline=date(now + timedelta(days=2)), effort='medium'),
    task('部屋をリセットする', scheduledTime='21:00-21:15', project='部屋'),
    task('友達の誕生日プレゼントを選ぶ', deadline=date(now + timedelta(days=1)), effort='medium'),
    task('読みかけの本を読む', resumeNote='42ページの途中まで'),
    task('旅行の行き先を調べる', effort='medium'),
    task('友達とランチ', scheduledTime='12:00-13:30', isEvent=True),
    task('週末の旅行', plannedAt=date(now + timedelta(days=4)), isEvent=True),
    task('打ち合わせの資料をまとめる', project='仕事', scheduledTime='10:00-11:30', plannedAt=date(now + timedelta(days=1))),
    task('歯医者の予約', scheduledTime='13:00-13:30', plannedAt=date(now + timedelta(days=2))),
    task('過去問 第3回を解く', project='資格の勉強', scheduledTime='20:30-21:30', milestoneID=M_COUNT),
    task('過去問 第2回を解く', project='資格の勉強', completedAt=date(now - timedelta(days=1)), milestoneID=M_TASKS),
    task('第3章を解き直す', project='資格の勉強', plannedAt=date(now + timedelta(days=1)), milestoneID=M_TASKS),
    task('第4章を解き直す', project='資格の勉強', plannedAt=None, milestoneID=M_TASKS),
    task('試験本番', project='資格の勉強', plannedAt=date(now + timedelta(days=41)), isEvent=True),
]
# A task in pieces: the pieces carry the days, the task its deadline.
P_PROPOSAL = str(uuid.uuid4()).upper()
tasks += [
    task('企画書をつくる', id=P_PROPOSAL, plannedAt=None, project='仕事', deadline=date(now + timedelta(days=2)), effort='heavy'),
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
count_ms = milestone('過去問を5回解く', 'count', target=5, current=3, unit='回')
tasks_ms = milestone('苦手な章をなくす', 'tasks')
count_ms['id'] = M_COUNT; tasks_ms['id'] = M_TASKS
projects = [dict(id=str(uuid.uuid4()), name='資格の勉強', goal='試験に合格する', deadline=date(now + timedelta(days=41)), origin='',
                 overview='来月の資格試験に向けて。テキストは毎日少しずつ、過去問は時間を計って解く。',
                 createdAt=date(now - timedelta(days=20)), milestones=[
                     milestone('テキストを1周する', 'check', isDone=True), count_ms,
                     milestone('模試で70点', 'number', target=70, current=62, unit='点'), tasks_ms])]
cards = [
    dict(id=str(uuid.uuid4()), title='過去問の解き方', project='資格の勉強', createdAt=date(now - timedelta(days=30)),
         purpose='本番の時間配分に慣れるため。',
         goal='時間内に最後まで解ききる。',
         detail='1. タイマーを本番と同じ時間にする\n2. 分からない問題は印をつけて飛ばす\n3. 終わったら、間違えた問題だけ解き直す'),
    dict(id=str(uuid.uuid4()), title='部屋のリセット', createdAt=date(now - timedelta(days=20)),
         purpose='散らかった机が目に入ると、始める前に気力が削られるため。', goal='机の上に、いま使う物しかない状態。',
         detail='1. タイマーを15分にする\n2. 床の物を1か所に集める\n3. 机の上を「戻す・捨てる・保留」に分ける'),
]
path.parent.mkdir(parents=True, exist_ok=True)
def routine(title, time, **changes):
    item = dict(id=str(uuid.uuid4()), title=title, project='', memo='', weekdays=[1, 2, 3, 4, 5, 6, 7], time=time,
                notify=True, isBlock=False, isPaused=False, createdAt=date(now - timedelta(days=30)), doneDays=[], moves={})
    item.update(changes)
    return item
routines = [
    routine('テキストを1節進める', '19:00-19:30', project='資格の勉強', weekdays=[2, 3, 4, 5, 6]),
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
    idea('週末に作り置きをまとめてやる', 2, 0, [('3品あれば平日がだいぶ楽', 1), ('日曜の午前にやる', 0)]),
    idea('部屋の配置を変えて、机を窓際に', 1, 1),
    idea('使っていないサブスクを見直す', 4),
    idea('朝の散歩を習慣にしたい', 16),
]
# Lists: a place to go (already planned), and groceries with a trip made from them.
L_GO = str(uuid.uuid4()).upper()
L_SHOP = str(uuid.uuid4()).upper()
lists = [dict(id=L_GO, name='行ってみたいところ', createdAt=date(now - timedelta(days=10))),
         dict(id=L_SHOP, name='夕ごはんの材料', createdAt=date(now - timedelta(days=9)))]
def item(list_id, title, ago, **changes):
    value = dict(id=str(uuid.uuid4()).upper(), listID=list_id, title=title, memo='', link='', place='',
                 createdAt=date(now - timedelta(days=ago)))
    value.update(changes)
    return value
museum = item(L_GO, '美術館の企画展', 9, place='上野公園')
list_items = [museum, item(L_GO, '海の見えるカフェ', 5, memo='週末の朝が空いている'), item(L_GO, '駅前のパン屋', 3),
              item(L_SHOP, '鶏もも肉', 1), item(L_SHOP, '玉ねぎ', 1), item(L_SHOP, '卵', 1),
              item(L_SHOP, '牛乳', 4, doneAt=date(now - timedelta(days=3)))]
tasks += [task('美術館の企画展', plannedAt=date(now + timedelta(days=3)), scheduledTime='10:00-12:00', isEvent=True,
               listItemID=museum['id']),
          task('夕ごはんの材料を買う', plannedAt=date(now + timedelta(days=1)), scheduledTime='17:30-18:00', listID=L_SHOP)]
path.write_text(json.dumps(dict(version=1, tasks=tasks, ideas=ideas, boardCards=cards, routines=routines, projects=projects,
                                lists=lists, listItems=list_items), ensure_ascii=False))
PY
launch -uiNoPrompt | tee "$RESULT_DIR/launch.txt"
sleep 5
shot today
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
shot now-card
# Where the main thread is while the いま screen shows, to catch a stuck layout.
pid=$(pgrep -f 'ThreeDays.app/ThreeDays' | head -1 || true)
if [ -n "$pid" ]; then
  echo "== main thread of the app on the いま screen ($DEVICE_FAMILY)"
  sample "$pid" 2 2>/dev/null | sed -n '/Thread_[0-9]*.*DispatchQueue_1: com.apple.main-thread/,/^ *[0-9]* Thread_/p' | head -120 || true
fi
launch -horme-settings-preview
sleep 4
shot sharing-settings
# -uiTab and -uiOpenFirstCard exist only in Debug builds, for these captures.
launch -uiTab 1 >/dev/null
sleep 4
shot week
launch -uiTab 1 -uiWeekSheetOpen >/dev/null
sleep 4
shot week-sheet
launch -uiTab 1 -uiWeekSheetFull >/dev/null
sleep 4
shot week-sheet-full
launch -uiTab 0 >/dev/null
sleep 4
shot all
launch -uiTab 3 >/dev/null
sleep 4
shot ideas
launch -uiTab 3 -uiOpenFirstIdea >/dev/null
sleep 4
shot idea-open
launch -uiTab 3 -uiSortIdeas >/dev/null
sleep 4
shot sort-ideas
launch -uiTab 4 >/dev/null
sleep 4
shot board
launch -uiTab 4 -uiOpenFirstCard >/dev/null
sleep 4
shot board-card
launch -uiTab 3 -uiStockLists >/dev/null
sleep 4
shot stock-lists
launch -uiTab 3 -uiStockLists -uiOpenFirstList >/dev/null
sleep 4
shot list-page
launch -uiTab 4 -uiOpenFirstProject >/dev/null
sleep 5
shot project
launch -uiTab 4 -uiOpenFirstProject -uiProjectWay >/dev/null
sleep 5
shot project-way
launch -uiTab 2 -uiOpenRoutine >/dev/null
sleep 4
shot routine-edit
launch -uiTab 2 -uiQuickAdd >/dev/null
sleep 4
shot quick-add
launch -uiTab 2 -uiOpenTask >/dev/null
sleep 4
shot task-edit
launch -uiTab 2 -uiTimetable >/dev/null
sleep 4
shot timetable
# Shown as ended without saving it, so the launches after this one start open.
launch -uiTab 2 -uiDayClosed >/dev/null
sleep 4
shot day-closed
# The guided first run, in demo mode, on its first step.
launch -uiTab 2 -uiTutorial >/dev/null
sleep 5
shot tutorial
# Last: starting a task leaves it running in the saved sample data.
launch -uiTab 2 -uiFocus >/dev/null
sleep 4
shot focus
# Leaving the app while demo mode shows, on each tab: send it behind Settings, bring it back, and keep any
# crash report it leaves (once seen on an iPad).
crash_reports() { ls -1t "$HOME"/Library/Logs/DiagnosticReports/ThreeDays*.ips 2>/dev/null || true; }
before=$(crash_reports | head -1)
for tab in "2" "2 -uiTimetable" "1" "0" "3" "4"; do
  # shellcheck disable=SC2086
  if ! launch -uiTab $tab -uiDemo >/dev/null; then
    echo "::warning::The $DEVICE_FAMILY simulator stopped launching apps; the rest of the leave-and-return checks are skipped" >&2
    break
  fi
  sleep 3
  # Bounded like every launch. When Settings itself does not open, the simulator has stopped answering (seen on
  # busy iPad runners, with Horme idle): what follows would only time out, so the rest is skipped.
  if ! perl -e 'alarm shift; exec @ARGV' 60 xcrun simctl launch "$SIMULATOR_ID" com.apple.Preferences >/dev/null 2>&1; then
    echo "::warning::Settings did not open within a minute (tab $tab, $DEVICE_FAMILY): the simulator stopped answering; the rest of the leave-and-return checks are skipped" >&2
    pid=$(pgrep -f 'ThreeDays.app/ThreeDays' | head -1 || true)
    if [ -n "$pid" ]; then ps -o pid,%cpu,stat,etime -p "$pid" >&2 || true; fi
    break
  fi
  sleep 4
  if ! pgrep -f 'ThreeDays.app/ThreeDays' >/dev/null; then echo "::warning::Horme was not running after leaving demo mode on tab $tab"; fi
  latest=$(crash_reports | head -1)
  if [ -n "$latest" ] && [ "$latest" != "$before" ]; then
    echo "::error::Horme crashed after leaving demo mode on tab $tab ($DEVICE_FAMILY)"
    head -c 60000 "$latest" | python3 -c '
import json, sys
text = sys.stdin.read()
head, _, body = text.partition("\n")
try:
    report = json.loads(body)
except ValueError:
    print(text[:6000]); raise SystemExit
print("exception:", json.dumps(report.get("exception"), ensure_ascii=False))
for key in ("asi", "lastExceptionBacktrace", "termination"):
    if report.get(key): print(key + ":", json.dumps(report[key], ensure_ascii=False)[:3000])
threads = report.get("threads", [])
images = report.get("usedImages", [])
faulting = report.get("faultingThread", 0)
if faulting < len(threads):
    for frame in threads[faulting].get("frames", [])[:40]:
        image = images[frame["imageIndex"]] if frame.get("imageIndex", -1) < len(images) else {}
        print("  ", image.get("name", "?"), frame.get("symbol", ""), frame.get("sourceFile", ""), frame.get("sourceLine", ""))
' || true
    cp "$latest" "$RESULT_DIR/" || true
    before=$latest
  fi
  # Back to the front without relaunching, as from the app switcher. When it does not come back within a
  # minute, what its main thread is doing is printed: an app stuck coming back is a bug, not a slow runner.
  if ! perl -e 'alarm shift; exec @ARGV' 60 xcrun simctl launch "$SIMULATOR_ID" io.github.reiji55.threedays >/dev/null 2>&1; then
    echo "::error::Horme did not come back to the front within a minute (tab $tab, $DEVICE_FAMILY)" >&2
    pid=$(pgrep -f 'ThreeDays.app/ThreeDays' | head -1 || true)
    if [ -n "$pid" ]; then
      ps -o pid,%cpu,stat,etime -p "$pid" >&2 || true
      sample "$pid" 3 2>/dev/null | head -160 >&2 || true
    fi
  fi
  sleep 3
  latest=$(crash_reports | head -1)
  if [ -n "$latest" ] && [ "$latest" != "$before" ]; then
    echo "::error::Horme crashed coming back to demo mode on tab $tab ($DEVICE_FAMILY)"
    cp "$latest" "$RESULT_DIR/" || true
    before=$latest
  fi
done
shot demo-return
# Screenshots and launch logs verify startup and layout, not every interaction.
