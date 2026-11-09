import AppKit
import SwiftUI

/// Current local week over Notchy's own tasks. No calendar service, no invented events.
struct WidgetWeek: Equatable {
    struct Day: Equatable {
        let date: Date
        let isToday: Bool
        /// An incomplete task is due on this local date.
        let hasDue: Bool
    }

    let days: [Day]
    /// Incomplete tasks due on today's local date (overdue earlier today included).
    let dueToday: Int
    /// Earliest incomplete due task inside the displayed week, overdue ones included.
    let next: TaskEntry?

    static func make(containing now: Date, calendar: Calendar, tasks: [TaskEntry]) -> WidgetWeek {
        let open = tasks.filter { !$0.completed && $0.due != nil }
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        // Calendar day additions, not 86 400 s steps, so DST weeks keep their local midnights.
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map { d in
            Day(date: d, isToday: calendar.isDate(d, inSameDayAs: now),
                hasDue: open.contains { calendar.isDate($0.due!, inSameDayAs: d) })
        }
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let next = open.filter { $0.due! >= start && $0.due! < end }.min { $0.due! < $1.due! }
        return WidgetWeek(days: days, dueToday: open.filter { calendar.isDate($0.due!, inSameDayAs: now) }.count, next: next)
    }

    static func selftest() throws {
        func check(_ ok: Bool, _ msg: String) throws {
            if !ok { throw NSError(domain: "WidgetWeekSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.firstWeekday = 2
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
        }
        func ymd(_ d: Date) -> [Int] { [cal.component(.year, from: d), cal.component(.month, from: d), cal.component(.day, from: d)] }

        // Monday-first week crossing month and year.
        let nye = WidgetWeek.make(containing: at(2026, 12, 31), calendar: cal, tasks: [])
        try check(ymd(nye.days[0].date) == [2026, 12, 28] && ymd(nye.days[6].date) == [2027, 1, 3], "year crossing \(nye.days.map { ymd($0.date) })")
        try check(nye.days.filter(\.isToday).map { ymd($0.date) } == [[2026, 12, 31]], "today highlighted")
        try check(nye.dueToday == 0 && nye.next == nil && !nye.days.contains(where: \.hasDue), "empty week")

        // Locale first weekday: Sunday-first starts on Sunday.
        var sunday = cal
        sunday.firstWeekday = 1
        try check(ymd(WidgetWeek.make(containing: at(2026, 12, 31), calendar: sunday, tasks: []).days[0].date) == [2026, 12, 27], "sunday first")

        // DST end (Sun 1 Nov 2026): every day still starts at local midnight.
        let dst = WidgetWeek.make(containing: at(2026, 11, 3), calendar: sunday, tasks: [])
        try check(dst.days.map { ymd($0.date)[2] } == Array(1...7), "dst days \(dst.days.map { ymd($0.date) })")
        try check(dst.days.allSatisfy { cal.component(.hour, from: $0.date) == 0 && cal.component(.minute, from: $0.date) == 0 }, "dst midnights")

        // Dots, today count and ordering. Now: Wed 4 Nov 2026 10:00 (Monday-first week 2-8 Nov).
        let now = at(2026, 11, 4, 10)
        let overdue = TaskEntry(text: "overdue Mon", due: at(2026, 11, 2, 9))
        let todayLate = TaskEntry(text: "today", due: at(2026, 11, 4, 23, 59, 59))
        let midnight = TaskEntry(text: "thu midnight", due: at(2026, 11, 5, 0))
        let done = TaskEntry(text: "done fri", completed: true, due: at(2026, 11, 6, 9))
        let undated = TaskEntry(text: "undated")
        let lastWeek = TaskEntry(text: "last week", due: at(2026, 10, 30, 9))
        let week = WidgetWeek.make(containing: now, calendar: cal, tasks: [todayLate, done, undated, midnight, overdue, lastWeek])
        try check(week.days.map(\.hasDue) == [true, false, true, true, false, false, false], "due dots \(week.days.map(\.hasDue))")
        try check(week.dueToday == 1, "due today \(week.dueToday)")
        try check(week.next?.text == "overdue Mon", "earliest in week incl. overdue \(String(describing: week.next?.text))")
        let upcoming = WidgetWeek.make(containing: now, calendar: cal, tasks: [midnight, todayLate, done, undated, lastWeek])
        try check(upcoming.next?.text == "today", "upcoming ordering \(String(describing: upcoming.next?.text))")
        let afterMidnight = WidgetWeek.make(containing: at(2026, 11, 5, 0), calendar: cal, tasks: [todayLate, midnight])
        try check(afterMidnight.dueToday == 1 && afterMidnight.days.first(where: \.isToday)?.date == cal.startOfDay(for: at(2026, 11, 5)),
                  "local midnight changes today without shifting due-day dots")
    }
}


/// Widgets page: the local week over Notchy due tasks, and the actual device battery.
struct WidgetsView: View {
    @ObservedObject var tasks: TaskController
    @ObservedObject var devices: DeviceMonitor
    @ObservedObject var shell: ShellState
    @State private var today = Date()

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        let week = WidgetWeek.make(containing: today, calendar: calendar, tasks: tasks.store.state.tasks)
        ViewThatFits(in: .vertical) {
            content(week).fixedSize(horizontal: false, vertical: true)
            ScrollView { content(week) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // Dates recompute on launch, local midnight, wake and time zone/calendar changes; no polling.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in today = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in today = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification).receive(on: DispatchQueue.main)) { _ in today = Date() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in today = Date() }
        .onChange(of: shell.expanded) { open in if open { today = Date() } }
    }

    private func content(_ week: WidgetWeek) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            weekStrip(week)
            summary(week)
            battery
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func weekStrip(_ week: WidgetWeek) -> some View {
        HStack(spacing: 4) {
            ForEach(week.days, id: \.date) { day in
                VStack(spacing: 3) {
                    Text(day.date, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 10)).foregroundColor(Palette.secondary)
                    Text(day.date, format: .dateTime.day())
                        .font(.system(size: 13, weight: day.isToday ? .semibold : .regular).monospacedDigit())
                        .foregroundColor(day.isToday ? .black : .white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(day.isToday ? Color.white : Color.clear))
                    Circle().fill(day.hasDue ? Palette.green : Color.clear).frame(width: 4, height: 4)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
                                    + (day.isToday ? ", hari ini" : "") + (day.hasDue ? ", ada tenggat tugas" : ""))
            }
        }
    }

    @ViewBuilder private func summary(_ week: WidgetWeek) -> some View {
        Button { shell.selectedTab = ShellTab.tugas.rawValue } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(week.dueToday == 0 ? "Tidak ada tenggat hari ini" : "\(week.dueToday) tugas jatuh tempo hari ini")
                        .font(.system(size: 12, weight: .semibold))
                    if let next = week.next, let due = next.due {
                        Text("\(due < Date() ? "Lewat" : "Berikutnya") · \(next.text) · \(due.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                            .font(.system(size: 11)).foregroundColor(Palette.secondary).lineLimit(1)
                            .help(next.text)
                    } else {
                        Text("Tidak ada tenggat minggu ini").font(.system(size: 11)).foregroundColor(Palette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(ShellControlStyle(kind: .quiet))
        .help("Buka Tugas")
    }

    private var battery: some View {
        HStack(spacing: 6) {
            if let progress = devices.batteryProgress {
                RingGauge(progress: progress, size: 14, line: 2)
                    .accessibilityHidden(true)
                Text(DeviceMonitor.batteryText(progress))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Text(DeviceMonitor.powerTitle(pluggedIn: devices.isPluggedIn, charging: devices.isCharging))
                    .font(.system(size: 11)).foregroundColor(Palette.secondary)
            } else {
                Text(DeviceMonitor.batteryText(nil))
                    .font(.system(size: 12)).foregroundColor(Palette.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
