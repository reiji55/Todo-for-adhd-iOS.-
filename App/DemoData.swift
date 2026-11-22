import Foundation

extension Notebook {
    /// Sample data for demo mode and the tutorial, dated around today so every screen has something to show.
    /// Everyday examples anyone can picture: an exam to study for, dinner to shop for, a trip to get ready for.
    static func demo(now: Date) -> Notebook {
        let calendar = Calendar.current
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now) ?? now }
        let earlier = day(-30)
        let pastPapers = Milestone(title: "過去問を5回解く", kind: .count, target: 5, current: 2, unit: "回", createdAt: earlier)
        let weakSpots = Milestone(title: "苦手な章をなくす", kind: .tasks, createdAt: earlier)
        let exam = Project(name: "資格の勉強", goal: "試験に合格する", deadline: day(41), milestones: [
            Milestone(title: "テキストを1周する", kind: .check, isDone: true, createdAt: earlier),
            pastPapers,
            Milestone(title: "模試で70点", kind: .number, target: 70, current: 62, unit: "点", createdAt: earlier),
            weakSpots
        ], createdAt: earlier, overview: "これはサンプルです。来月の資格試験に向けて。テキストは毎日少しずつ、過去問は時間を計って解く。")
        // Tasks in pieces: the pieces carry the days; the whole keeps its deadline and ★.
        let insurance = TaskItem(title: "保険の書類を出す", deadline: now, isMust: true, effort: .light, memo: "これはサンプルです。",
                                 createdAt: earlier)
        let proposal = TaskItem(title: "企画書をつくる", deadline: day(2), effort: .heavy, project: "仕事", createdAt: earlier)
        let review = TaskItem(title: "苦手な章の解き直し", effort: .medium, project: "資格の勉強", createdAt: earlier,
                              milestoneID: weakSpots.id)
        func piece(_ title: String, of parent: TaskItem, _ rank: Int, on date: Date? = nil, at time: String = "", done: Date? = nil) -> TaskItem {
            TaskItem(title: title, plannedAt: date, scheduledTime: time, project: parent.project,
                     createdAt: earlier.addingTimeInterval(Double(rank)), completedAt: done, parentID: parent.id, rank: rank)
        }
        // A shopping list, and the trip that checks it off.
        let dinner = StockList(name: "夕ごはんの材料", createdAt: day(-1), rank: 0)
        let places = StockList(name: "行ってみたいところ", createdAt: earlier, rank: 1)
        let shopping = TaskItem(title: "夕ごはんの材料を買う", plannedAt: now, scheduledTime: "18:30-19:00", effort: .light,
                                createdAt: day(-1), listID: dinner.id)
        func item(_ title: String, in list: StockList, group: String = "", _ order: Int) -> ListItem {
            ListItem(listID: list.id, title: title, group: group, createdAt: list.createdAt.addingTimeInterval(Double(order)))
        }
        return Notebook(tasks: [
            TaskItem(title: "過去問 第3回を解く", plannedAt: now, scheduledTime: "20:30-21:30", effort: .heavy,
                     project: "資格の勉強", milestoneID: pastPapers.id),
            TaskItem(title: "過去問 第2回を解く", plannedAt: day(-1), effort: .heavy, project: "資格の勉強",
                     completedAt: day(-1), milestoneID: pastPapers.id),
            review,
            piece("第1章を解き直す", of: review, 0, on: day(-2), done: day(-2)),
            piece("第2章を解き直す", of: review, 1, on: day(-1), done: day(-1)),
            piece("第3章を解き直す", of: review, 2, on: day(1)),
            piece("第4章を解き直す", of: review, 3),
            TaskItem(title: "試験本番", plannedAt: day(41), project: "資格の勉強", isEvent: true),
            insurance,
            piece("必要なところを記入する", of: insurance, 0, on: now),
            piece("ポストに出す", of: insurance, 1, on: now),
            shopping,
            TaskItem(title: "美容院の予約をする", plannedAt: now, scheduledTime: "14:00-14:15", effort: .light),
            TaskItem(title: "読みかけの本を読む", effort: .light, memo: "42ページの途中まで"),
            proposal,
            piece("構成を決める", of: proposal, 0, on: day(-1), done: day(-1)),
            piece("見出しを3つ書く", of: proposal, 1, on: now, at: "15:00-16:00"),
            piece("本文を書く", of: proposal, 2, on: day(1), at: "10:00-11:30"),
            TaskItem(title: "友達とランチ", plannedAt: now, scheduledTime: "12:00-13:30", memo: "駅前のお店", isEvent: true),
            TaskItem(title: "友達の誕生日プレゼントを選ぶ", deadline: day(5), effort: .medium, createdAt: earlier),
            TaskItem(title: "週末の旅行", plannedAt: day(6), isEvent: true),
            TaskItem(title: "図書館に本を返す", plannedAt: day(-1)),
            TaskItem(title: "旅行の行き先を調べる", effort: .medium),
            // 期間タスク: some day from two days ago to ten days on.
            TaskItem(title: "歯医者の予約を取る", deadline: day(10), effort: .light, createdAt: earlier, periodStart: day(-2))
        ], ideas: [
            Idea(text: "週末に作り置きをまとめてやる", createdAt: day(-1), notes: [IdeaNote(text: "3品あれば平日がだいぶ楽")]),
            Idea(text: "使っていないサブスクを見直す", createdAt: day(-3)),
            Idea(text: "朝の散歩を習慣にしたい", createdAt: day(-6)),
            Idea(text: "部屋の模様替え", createdAt: day(-12), bundle: "部屋のこと"),
            Idea(text: "本棚を1つ減らす", createdAt: day(-9), bundle: "部屋のこと")
        ], boardCards: [
            BoardCard(title: "部屋のリセット", purpose: "散らかった机が目に入ると、始める前に気力が削られるため。",
                      goal: "机の上に、いま使う物しかない状態。",
                      detail: "これはサンプルです。\n\n1. タイマーを15分にする\n2. 床の物を1か所に集める\n3. 机の上を「戻す・捨てる・保留」に分ける\n4. 保留は箱に入れて、今日は考えない\n\n▸ 15分で止める。全部やろうとしない",
                      createdAt: earlier, project: "部屋のリセット"),
            BoardCard(title: "過去問の解き方", purpose: "本番の時間配分に慣れるため。", goal: "時間内に最後まで解ききる。",
                      detail: "これはサンプルです。\n\n1. タイマーを本番と同じ時間にする\n2. 分からない問題は印をつけて飛ばす\n3. 終わったら、間違えた問題だけ解き直す",
                      createdAt: earlier, project: "資格の勉強")
        ], routines: [
            Routine(title: "テキストを1節進める", project: "資格の勉強", weekdays: [2, 3, 4, 5, 6], time: "19:30-20:00", createdAt: earlier,
                    resumeNote: "第4章の2節から"),
            Routine(title: "部屋をリセットする", project: "部屋のリセット", time: "21:00-21:15", createdAt: earlier),
            Routine(title: "仕事", weekdays: [2, 3, 4, 5, 6], time: "9:00-18:00", notify: false, isBlock: true, createdAt: earlier),
            Routine(title: "睡眠", time: "0:00-7:00", notify: false, isBlock: true, createdAt: earlier)
        ], projects: [exam], lists: [dinner, places], listItems: [
            item("鶏もも肉", in: dinner, group: "肉・魚", 0),
            item("玉ねぎ", in: dinner, group: "野菜", 1),
            item("にんじん", in: dinner, group: "野菜", 2),
            item("卵", in: dinner, 3),
            item("牛乳", in: dinner, 4),
            item("海の見えるカフェ", in: places, 0),
            item("美術館の企画展", in: places, 1)
        ], packages: [
            TaskPackage(name: "旅行の準備", items: ["宿を予約する", "交通手段を決める", "荷造りをする", "持ち物を確認する"], createdAt: earlier),
            TaskPackage(name: "来客の準備", items: ["部屋を片付ける", "飲み物を買う", "布団を干す"], createdAt: earlier)
        ])
    }
}
