import Foundation

extension Notebook {
    /// Sample data for demo mode, dated around today so every screen has something to show.
    static func demo(now: Date) -> Notebook {
        let calendar = Calendar.current
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now) ?? now }
        let earlier = day(-30)
        let test = Milestone(title: "予想問題を解く", kind: .count, target: 5, current: 2, unit: "回", createdAt: earlier)
        let part7 = Milestone(title: "長文を時間内に解く", kind: .tasks, createdAt: earlier)
        let english = Project(name: "英語の勉強", goal: "本番で500点", deadline: day(41), milestones: [
            Milestone(title: "単語帳を1周する", kind: .check, isDone: true, createdAt: earlier),
            test,
            Milestone(title: "模試で450点", kind: .number, target: 450, current: 420, unit: "点", createdAt: earlier),
            part7
        ], createdAt: earlier, overview: "これはサンプルです。転職の条件に英語があるので、本番までに形式に慣れる。単語は毎日少しずつ、長文は時間を計って解く。")
        // Tasks in pieces: the pieces carry the days; the whole keeps its deadline and ★.
        let papers = TaskItem(title: "提出書類を送る", deadline: now, isMust: true, effort: .light, memo: "これはサンプルです。",
                              createdAt: earlier)
        let proposal = TaskItem(title: "提案書をつくる", deadline: day(2), effort: .heavy, project: "仕事", createdAt: earlier)
        let rereading = TaskItem(title: "長文の解き直し", effort: .medium, project: "英語の勉強", createdAt: earlier, milestoneID: part7.id)
        func piece(_ title: String, of parent: TaskItem, _ rank: Int, on date: Date? = nil, at time: String = "", done: Date? = nil) -> TaskItem {
            TaskItem(title: title, plannedAt: date, scheduledTime: time, project: parent.project,
                     createdAt: earlier.addingTimeInterval(Double(rank)), completedAt: done, parentID: parent.id, rank: rank)
        }
        return Notebook(tasks: [
            TaskItem(title: "予想問題 第4回を解く", plannedAt: now, scheduledTime: "20:30-21:30", effort: .heavy,
                     project: "英語の勉強", milestoneID: test.id),
            TaskItem(title: "長文 時間を計って10問", plannedAt: day(-1), effort: .medium, project: "英語の勉強",
                     completedAt: day(-1), milestoneID: part7.id),
            rereading,
            piece("第1段落を解き直す", of: rereading, 0, on: day(-2), done: day(-2)),
            piece("第2段落を解き直す", of: rereading, 1, on: day(-1), done: day(-1)),
            piece("第3段落を解き直す", of: rereading, 2, on: day(1)),
            piece("第4段落を解き直す", of: rereading, 3),
            TaskItem(title: "本番", plannedAt: day(41), project: "英語の勉強", isEvent: true),
            papers,
            piece("宛先を確認する", of: papers, 0, on: now),
            piece("メールに添付して送る", of: papers, 1, on: now),
            TaskItem(title: "予約の電話をする", plannedAt: now, scheduledTime: "14:00-14:15", effort: .light,
                     handoff: "受付時間を調べておいて"),
            TaskItem(title: "読みかけの本を読む", effort: .light, memo: "42ページの途中まで"),
            proposal,
            piece("構成を決める", of: proposal, 0, on: day(-1), done: day(-1)),
            piece("見出しを3つ書く", of: proposal, 1, on: now, at: "15:00-16:00"),
            piece("本文を書く", of: proposal, 2, on: day(1), at: "10:00-11:30"),
            TaskItem(title: "友達とランチ", plannedAt: now, scheduledTime: "12:00-13:30", memo: "駅前のお店", isEvent: true),
            TaskItem(title: "買い物に行く", plannedAt: day(2), isEvent: true),
            TaskItem(title: "図書館に本を返す", plannedAt: day(-1)),
            TaskItem(title: "気になる資料を読む", effort: .medium),
            // 期間タスク: some day from two days ago to ten days on.
            TaskItem(title: "歯医者の予約を取る", deadline: day(10), effort: .light, createdAt: earlier, periodStart: day(-2))
        ], ideas: [
            Idea(text: "散歩中に聞ける勉強メモを作れそう", notes: [IdeaNote(text: "通勤の15分で聞ける長さにする")])
        ], boardCards: [
            BoardCard(title: "部屋のリセット", purpose: "散らかった机が目に入ると、始める前に気力が削られるため。",
                      goal: "机の上に、いま使う物しかない状態。",
                      detail: "これはサンプルです。\n\n1. タイマーを15分にする\n2. 床の物を1か所に集める\n3. 机の上を「戻す・捨てる・保留」に分ける\n4. 保留は箱に入れて、今日は考えない\n\n▸ 15分で止める。全部やろうとしない",
                      createdAt: earlier, project: "部屋のリセット"),
            BoardCard(title: "単語のやり方", purpose: "単語は毎日少しずつが効く。", goal: "未チェックの単語をなくす。",
                      detail: "これはサンプルです。\n\n1. 日本語側を隠す\n2. 英語を見て2秒で意味を言う\n3. 出なければ即×。粘らない",
                      createdAt: earlier, project: "英語の勉強")
        ], routines: [
            Routine(title: "単語を回す", project: "英語の勉強", weekdays: [2, 3, 4, 5, 6], time: "19:00-19:30", createdAt: earlier,
                    resumeNote: "Section 3 の 120番まで"),
            Routine(title: "部屋をリセットする", project: "部屋のリセット", time: "21:00-21:15", createdAt: earlier),
            Routine(title: "仕事", weekdays: [2, 3, 4, 5, 6], time: "9:00-18:00", notify: false, isBlock: true, createdAt: earlier),
            Routine(title: "睡眠", time: "0:00-7:00", notify: false, isBlock: true, createdAt: earlier)
        ], projects: [english])
    }
}
