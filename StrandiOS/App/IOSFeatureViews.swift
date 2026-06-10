import SwiftUI
import UIKit
import MapKit
import StrandDesign

private extension Notification.Name {
    static let noopClearHRChartSelection = Notification.Name("noopClearHRChartSelection")
}

private extension View {
    @ViewBuilder
    func noopRefreshableWhen(_ condition: Bool, action: @escaping @Sendable () async -> Void) -> some View {
        if condition {
            self.refreshable(action: action)
        } else {
            self
        }
    }

    func dismissNOOPKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func clearNOOPChartSelection() {
        NotificationCenter.default.post(name: .noopClearHRChartSelection, object: nil)
    }
}

private enum NOOPSleepDisplay {
    static func intervals(health: [IOSSleepInterval], whoop: [IOSSleepInterval]) -> [IOSSleepInterval] {
        asleepHours(in: whoop) > 0 ? whoop : health
    }

    static func hours(healthHours: Double,
                      whoopHours: Double,
                      healthIntervals: [IOSSleepInterval],
                      whoopIntervals: [IOSSleepInterval]) -> Double {
        if whoopHours > 0 { return whoopHours }
        let intervalHours = asleepHours(in: whoopIntervals)
        if intervalHours > 0 { return intervalHours }
        return healthHours
    }

    static func efficiency(healthEfficiency: Double,
                           whoopEfficiency: Double,
                           healthIntervals: [IOSSleepInterval],
                           whoopIntervals: [IOSSleepInterval]) -> Double {
        whoopEfficiency > 0 ? whoopEfficiency : healthEfficiency
    }

    static func stages(health: [IOSSleepStageSummary],
                       whoop: [IOSSleepStageSummary],
                       healthIntervals: [IOSSleepInterval],
                       whoopIntervals: [IOSSleepInterval]) -> [IOSSleepStageSummary] {
        if !whoop.isEmpty { return whoop }
        if !whoopIntervals.isEmpty { return summarize(whoopIntervals) }
        if !health.isEmpty { return health }
        return summarize(healthIntervals)
    }

    private static func asleepHours(in intervals: [IOSSleepInterval]) -> Double {
        intervals.reduce(0) { total, interval in
            guard interval.stage != "Awake" else { return total }
            return total + interval.end.timeIntervalSince(interval.start) / 3600.0
        }
    }

    private static func summarize(_ intervals: [IOSSleepInterval]) -> [IOSSleepStageSummary] {
        var totals: [String: Double] = [:]
        for interval in intervals {
            let hours = interval.end.timeIntervalSince(interval.start) / 3600.0
            totals[interval.stage, default: 0] += hours
        }
        return ["Core", "Deep", "REM", "Awake"].compactMap { name in
            guard let hours = totals[name], hours > 0.01 else { return nil }
            return IOSSleepStageSummary(name: name, hours: hours)
        }
    }
}

struct FeatureDetailView: View {
    let feature: IOSFeature

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()
            content
        }
        .navigationTitle(feature == .today ? "NOOP" : feature.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(feature == .today ? .hidden : .visible, for: .navigationBar)
    }

    @ViewBuilder private var content: some View {
        switch feature {
        case .today: TodayIOSView()
        case .live: LiveIOSView()
        case .workouts: WorkoutsIOSView()
        case .more: MoreIOSView()
        }
    }
}

struct TodayIOSView: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner
    @EnvironmentObject private var health: IOSHealthStore
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    @EnvironmentObject private var pedometer: IOSPedometerStore
    @State private var selectedDate = Date()
    @State private var calendarMonth = Date()
    @State private var showingCalendar = false
    @State private var recoveryScoresByDay: [String: Double] = [:]

    var body: some View {
        let dailyStrain = effectiveDailyStrain
        let recoveryScore = effectiveRecoveryScore
        let adjustedLoad = recoveryAdjustedLoad
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DayPickerHeader(selectedDate: $selectedDate) {
                    calendarMonth = selectedDate
                    showingCalendar = true
                    loadRecoveryScores(for: selectedDate)
                }
                if Calendar.current.isDateInToday(selectedDate), scanner.isRefreshingMetrics {
                    MetricsRefreshBanner()
                }
                HStack(spacing: 10) {
                    NavigationLink {
                        RecoveryExplanationView()
                    } label: {
                        RingScoreCard(
                            title: "Recovery",
                            value: recoveryScore,
                            valueText: recoveryScore.map { "\(Int($0.rounded()))" } ?? "--",
                            unit: "%",
                            progress: recoveryScore.map { $0 / 100.0 } ?? 0,
                            color: recoveryScore.map(StrandPalette.recoveryColor) ?? StrandPalette.textTertiary
                        )
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        StrainExplanationView()
                    } label: {
                        RingScoreCard(
                            title: "Strain",
                            value: dailyStrain,
                            valueText: dailyStrain.map { String(format: "%.1f", $0) } ?? "--",
                            unit: "/21",
                            progress: dailyStrain.map { $0 / 21.0 } ?? 0,
                            color: dailyStrain == nil ? StrandPalette.textTertiary : StrandPalette.metricCyan,
                            secondaryTitle: "Adj load",
                            secondaryValueText: adjustedLoad.map { String(format: "%.1f", $0) },
                            secondaryProgress: adjustedLoad.map { $0 / 21.0 },
                            secondaryColor: adjustedLoad == nil ? nil : StrandPalette.metricPurple
                        )
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 10) {
                    NavigationLink {
                        SleepDetailView()
                    } label: {
                        ScoreCard(title: "Sleep", value: String(format: "%.1f", effectiveSleepHours), unit: "h", color: StrandPalette.metricCyan)
                    }
                    .buttonStyle(.plain)
                    ScoreCard(title: "Steps", value: "\(displaySteps)", unit: "", color: StrandPalette.strain066)
                }
                if let calories = scanner.metrics.calories, calories > 0 {
                    ScoreCard(title: "Calories", value: "\(Int(calories.rounded()))", unit: "kcal", color: StrandPalette.metricAmber)
                }
                NavigationLink {
                    HeartRateDayView(samples: scanner.metrics.todayHRSamples, intervals: heartRateIntervals)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("HEART RATE")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer()
                            Text(heartRateHeaderText)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(StrandPalette.metricRose)
                        }
                        HospitalHRChart(samples: scanner.metrics.todayHRSamples, intervals: heartRateIntervals)
                            .frame(height: 118)
                        HRIntervalLegend(intervals: heartRateIntervals)
                    }
                    .padding(12)
                    .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                TodayWorkoutList(
                    workouts: workoutsForSelectedDate,
                    detectedWorkouts: scanner.metrics.workouts
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .noopRefreshableWhen(Calendar.current.isDateInToday(selectedDate)) {
            await scanner.refreshDeviceMetricsNow(date: selectedDate)
            await MainActor.run {
                pedometer.refresh(date: selectedDate) { date, steps in
                    scanner.recordPhoneSteps(steps, for: date)
                }
            }
        }
        .onAppear {
            loadRecoveryScores(for: selectedDate)
            pedometer.refresh(date: selectedDate) { date, steps in
                scanner.recordPhoneSteps(steps, for: date)
            }
        }
        .onChange(of: selectedDate) { date in
            if Calendar.current.isDateInToday(date) {
                scanner.refreshDeviceMetrics(date: date)
                pedometer.refresh(date: date) { date, steps in
                    scanner.recordPhoneSteps(steps, for: date)
                }
            } else {
                scanner.loadLoggedMetricsForDay(date)
            }
            loadRecoveryScores(for: date)
        }
        .sheet(isPresented: $showingCalendar) {
            RecoveryCalendarSheet(
                selectedDate: $selectedDate,
                visibleMonth: $calendarMonth,
                recoveryScoresByDay: recoveryScoresByDay,
                onMonthChanged: loadRecoveryScores
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var workoutsForSelectedDate: [IOSLoggedWorkout] {
        recorder.workouts.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: selectedDate) }
    }

    private var effectiveDailyStrain: Double? {
        guard Calendar.current.isDateInToday(selectedDate) else {
            return scanner.metrics.strain
        }
        let computed = IOSStrainEstimator.awakeDayStrain(metricSamples: awakeDayHRSamples)
        let bestWorkout = workoutsForSelectedDate.compactMap(\.effectiveStrain).max()
        return [computed, scanner.metrics.strain, bestWorkout]
            .compactMap { $0 }
            .max()
    }

    private var effectiveRecoveryScore: Double? {
        scanner.metrics.recovery
    }

    private var displaySteps: Int {
        Calendar.current.isDateInToday(selectedDate)
            ? (pedometer.displayedSteps ?? scanner.metrics.steps)
            : scanner.metrics.steps
    }

    private var heartRateHeaderText: String {
        if Calendar.current.isDateInToday(selectedDate) {
            return scanner.heartRate.map { "\($0) bpm" } ?? "-- bpm"
        }
        guard !scanner.metrics.todayHRSamples.isEmpty else { return "-- bpm" }
        let avg = scanner.metrics.todayHRSamples.reduce(0) { $0 + $1.bpm } / scanner.metrics.todayHRSamples.count
        return "avg \(avg) bpm"
    }

    private var recoveryAdjustedLoad: Double? {
        IOSStrainEstimator.recoveryAdjustedLoad(strain: effectiveDailyStrain, recovery: effectiveRecoveryScore)
    }

    private var awakeDayHRSamples: [IOSMetricHRSample] {
        let sleepIntervals = NOOPSleepDisplay.intervals(
            health: health.sleepIntervals,
            whoop: scanner.metrics.whoopSleepIntervals
        )
        let selectedDayStart = Int(Calendar.current.startOfDay(for: selectedDate).timeIntervalSince1970)
        let morningCutoff = selectedDayStart + 14 * 3600
        let wakeTs = sleepIntervals
            .filter { $0.stage != "Awake" }
            .filter {
                let end = Int($0.end.timeIntervalSince1970)
                return end >= selectedDayStart && end <= morningCutoff
            }
            .map { Int($0.end.timeIntervalSince1970) }
            .max()
        let startTs = max(selectedDayStart, wakeTs ?? selectedDayStart)
        var byTs: [Int: Int] = [:]
        for sample in dailyCalculationSamples where sample.ts >= startTs {
            byTs[sample.ts] = sample.bpm
        }
        for workout in workoutsForSelectedDate {
            for sample in workout.hrSamples where sample.ts >= startTs {
                byTs[sample.ts] = sample.bpm
            }
        }
        if let active = recorder.active, Calendar.current.isDate(active.startedAt, inSameDayAs: selectedDate) {
            for sample in active.hrSamples where sample.ts >= startTs {
                byTs[sample.ts] = sample.bpm
            }
        }
        return byTs.keys.sorted().enumerated().map { index, ts in
            IOSMetricHRSample(id: index, ts: ts, bpm: byTs[ts] ?? 0)
        }
    }

    private var dailyCalculationSamples: [IOSMetricHRSample] {
        scanner.metrics.dailyHRSamples.isEmpty ? scanner.metrics.todayHRSamples : scanner.metrics.dailyHRSamples
    }

    private var heartRateIntervals: [HRChartInterval] {
        var intervals: [HRChartInterval] = []
        let sleepIntervals = NOOPSleepDisplay.intervals(
            health: health.sleepIntervals,
            whoop: scanner.metrics.whoopSleepIntervals
        )
        if let sleepStart = sleepIntervals.map(\.start).min(),
           let sleepEnd = sleepIntervals.map(\.end).max(),
           sleepEnd > sleepStart {
            intervals.append(HRChartInterval(start: sleepStart, end: sleepEnd, title: "Sleep", color: StrandPalette.metricCyan))
        }
        intervals.append(contentsOf: workoutsForSelectedDate.map {
            HRChartInterval(start: $0.startedAt, end: $0.endedAt, title: $0.typeName, color: StrandPalette.strain066)
        })
        intervals.append(contentsOf: scanner.metrics.workouts.map {
            HRChartInterval(start: $0.start, end: $0.end, title: "Workout", color: StrandPalette.metricAmber)
        })
        return intervals
    }

    private func loadRecoveryScores(for date: Date) {
        let month = Calendar.current.dateInterval(of: .month, for: date)
        guard let start = month?.start, let end = month?.end.addingTimeInterval(-1) else { return }
        Task { @MainActor in
            var scores = await scanner.recoveryScores(from: start, to: end)
            if Calendar.current.isDate(date, inSameDayAs: selectedDate),
               let recovery = scanner.metrics.recovery {
                scores[Self.dayString(selectedDate)] = recovery
            }
            recoveryScoresByDay = scores
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var effectiveSleepHours: Double {
        NOOPSleepDisplay.hours(
            healthHours: health.sleepHours,
            whoopHours: scanner.metrics.whoopSleepHours,
            healthIntervals: health.sleepIntervals,
            whoopIntervals: scanner.metrics.whoopSleepIntervals
        )
    }

}

private struct LiveIOSView: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LiveSummaryCard()
                HStack(spacing: 10) {
                    ActionButton(title: scanner.isConnected ? "Disconnect" : "Scan", icon: scanner.isConnected ? "xmark" : "dot.radiowaves.left.and.right", color: scanner.isConnected ? StrandPalette.statusCritical : StrandPalette.accent) {
                        scanner.isConnected ? scanner.disconnect() : scanner.start()
                    }
                    ActionButton(title: "Buzz", icon: "iphone.radiowaves.left.and.right", color: StrandPalette.metricPurple) {
                        scanner.buzz()
                    }
                    .disabled(!scanner.isBondReady)
                }
                LogPanel(lines: scanner.logLines)
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await scanner.refreshDeviceMetricsNow() }
    }
}

private struct ActivityIOSView: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ScoreCard(title: "Strain", value: scanner.metrics.strain.map { String(format: "%.1f", $0) } ?? "--", unit: "/21", color: StrandPalette.strainColor(scanner.metrics.strain ?? 0))
                    ScoreCard(title: "Motion", value: "\(scanner.metrics.activityPoints)", unit: "pts", color: StrandPalette.metricAmber)
                }
                HStack(spacing: 10) {
                    ScoreCard(title: "Exercise", value: "\(scanner.metrics.exerciseMinutes)", unit: "min", color: StrandPalette.strain066)
                    ScoreCard(title: "Workouts", value: "\(scanner.metrics.workouts.count)", unit: "", color: StrandPalette.metricCyan)
                }
                SourceRow(name: "Activity Source", status: "WHOOP HR and gravity samples from local device store", icon: "waveform.path.ecg", color: StrandPalette.accent)
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await scanner.refreshDeviceMetricsNow() }
    }
}

private struct WorkoutsIOSView: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    @State private var notesDraft = ""
    @State private var showingPlanEditor = false
    @State private var showingPlans = false
    @State private var selectingType: IOSWorkoutType?
    @State private var editingPlan: IOSWorkoutPlan?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let active = recorder.active {
                    ActiveWorkoutCard(active: active, notes: $notesDraft)
                        .onAppear { notesDraft = active.notes }
                        .onChange(of: notesDraft) { recorder.updateNotes($0) }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("START WORKOUT")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                        HStack(spacing: 10) {
                            CompactActionButton(title: "Create Plan", icon: "plus", color: StrandPalette.metricCyan) {
                                showingPlanEditor = true
                            }
                            CompactActionButton(title: "View Plans", icon: "list.bullet.rectangle", color: StrandPalette.accent) {
                                showingPlans = true
                            }
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(IOSWorkoutType.all) { type in
                                WorkoutTypeButton(type: type) {
                                    start(type)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("WORKOUT LOG")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    if recorder.workouts.isEmpty {
                        SourceRow(name: "No logged workouts", status: "Start a workout above, then finish it to save HR, strain, and notes.", icon: "list.bullet.clipboard.fill", color: StrandPalette.textTertiary)
                    } else {
                        ForEach(recorder.workouts) { workout in
                            LoggedWorkoutRow(workout: workout) {
                                recorder.delete(workout)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("AUTO-DETECTED")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    if scanner.metrics.workouts.isEmpty {
                        SourceRow(name: "No WHOOP-detected workouts", status: "These appear after historical HR and motion data sync from the strap.", icon: "figure.run", color: StrandPalette.textTertiary)
                    } else {
                        ForEach(scanner.metrics.workouts) { workout in
                            SourceRow(
                                name: workout.title,
                                status: "\(workout.start.formatted(date: .abbreviated, time: .shortened)) · \(workout.durationMinutes) min · avg \(workout.avgHR) bpm · max \(workout.maxHR) bpm",
                                icon: "figure.run",
                                color: StrandPalette.strain066
                            )
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .refreshable { await scanner.refreshDeviceMetricsNow() }
        .sheet(isPresented: $showingPlanEditor) {
            WorkoutPlanEditorView()
                .environmentObject(recorder)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPlans) {
            PlansLibraryView(editingPlan: $editingPlan)
                .environmentObject(recorder)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingPlan) { plan in
            WorkoutPlanEditorView(existingPlan: plan)
                .environmentObject(recorder)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectingType) { type in
            PlanSelectionView(type: type) { plan in
                recorder.start(type, plan: plan)
                notesDraft = ""
                selectingType = nil
                if !scanner.isConnected {
                    scanner.start()
                }
            } startEmpty: {
                recorder.start(type)
                notesDraft = ""
                selectingType = nil
                if !scanner.isConnected {
                    scanner.start()
                }
            }
            .environmentObject(recorder)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func start(_ type: IOSWorkoutType) {
        let plans = recorder.plans(for: type)
        if !plans.isEmpty || type.id == "strength" || type.id == "swim" {
            selectingType = type
            return
        }
        recorder.start(type)
        notesDraft = ""
        if !scanner.isConnected {
            scanner.start()
        }
    }
}

private struct ActiveWorkoutCard: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    let active: IOSActiveWorkout
    @Binding var notes: String
    @FocusState private var notesFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Label(active.type.name, systemImage: active.type.icon)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(recorder.elapsedString(for: active.durationSeconds))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(StrandPalette.accent)
            }

            HStack(spacing: 10) {
                ScoreCard(title: "Live HR", value: scanner.heartRate.map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.zone3)
                let activeStrain = recorder.strain(for: active.hrSamples)
                ScoreCard(title: "Strain", value: activeStrain.map { String(format: "%.1f", $0) } ?? "--", unit: activeStrain == nil ? "" : "/21", color: StrandPalette.strainColor(activeStrain ?? 0))
            }
            HStack(spacing: 10) {
                ScoreCard(title: "Avg HR", value: active.avgHR.map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.metricCyan)
                ScoreCard(title: "Max HR", value: active.maxHR.map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.metricRose)
            }
            if active.type.id == "run" || active.type.id == "hiking" {
                OutdoorWorkoutMetricsView(active: active)
            }
            if active.type.id == "treadmill" {
                ManualWorkoutField(title: "TREADMILL DISTANCE", placeholder: "Distance ran", unit: "mi", text: Binding(
                    get: { active.treadmillDistance },
                    set: { recorder.updateTreadmillDistance($0) }
                ))
            }
            if active.type.id == "stairmaster" {
                ManualWorkoutField(title: "STAIRMASTER", placeholder: "Flights climbed", unit: "flights", text: Binding(
                    get: { active.stairFlights },
                    set: { recorder.updateStairFlights($0) }
                ))
            }

            HRLineChart(samples: active.hrSamples)
                .frame(height: 160)
                .onTapGesture {
                    notesFocused = false
                    dismissNOOPKeyboard()
                }

            if let plan = active.plan {
                ActivePlanView(active: active, plan: plan)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("NOTES")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StrandPalette.textTertiary)
                TextEditor(text: $notes)
                    .focused($notesFocused)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                notesFocused = false
                                dismissNOOPKeyboard()
                            }
                        }
                    }
            }

            HStack(spacing: 10) {
                ActionButton(title: "Finish", icon: "checkmark", color: StrandPalette.accent) {
                    recorder.finish()
                }
                .disabled(active.hrSamples.isEmpty)
                ActionButton(title: "Discard", icon: "trash", color: StrandPalette.statusCritical) {
                    recorder.discard()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            notesFocused = false
            dismissNOOPKeyboard()
            clearNOOPChartSelection()
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(StrandPalette.hairline, lineWidth: 1) }
    }
}

private struct PlanSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    let type: IOSWorkoutType
    let start: (IOSWorkoutPlan) -> Void
    let startEmpty: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ActionButton(title: "Start Without Plan", icon: type.icon, color: StrandPalette.accent) {
                        startEmpty()
                    }
                    ForEach(recorder.plans(for: type)) { plan in
                        Button {
                            start(plan)
                        } label: {
                            PlanSummaryContent(plan: plan, showDelete: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Select Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct CompactActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct PlansLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    @Binding var editingPlan: IOSWorkoutPlan?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if recorder.plans.isEmpty {
                        SourceRow(name: "No plans yet", status: "Create a strength or swim plan to reuse during workouts.", icon: "list.bullet.rectangle", color: StrandPalette.textTertiary)
                    } else {
                        ForEach(recorder.plans) { plan in
                            HStack(spacing: 10) {
                                Button {
                                    editingPlan = plan
                                    dismiss()
                                } label: {
                                    PlanSummaryContent(plan: plan, showDelete: false)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    recorder.deletePlan(plan)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(StrandPalette.statusCritical)
                                        .frame(width: 42, height: 42)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct OutdoorWorkoutMetricsView: View {
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    let active: IOSActiveWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ScoreCard(title: "Distance", value: String(format: "%.2f", active.distanceMeters / 1609.344), unit: "mi", color: StrandPalette.metricCyan)
                ScoreCard(title: "Pace", value: active.paceSecondsPerMile.map(Self.paceText) ?? "--", unit: "/mi", color: StrandPalette.strain066)
            }
            RouteMapView(points: active.routePoints)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(StrandPalette.hairline, lineWidth: 1) }
            SourceRow(name: "Route", status: recorder.locationStatus, icon: "location.fill", color: StrandPalette.metricCyan)
        }
    }

    private static func paceText(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ManualWorkoutField: View {
    let title: String
    let placeholder: String
    let unit: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(StrandPalette.textTertiary)
            HStack(spacing: 10) {
                TextField(placeholder, text: $text)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(unit)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

private struct RouteMapView: View {
    let points: [IOSRoutePoint]

    var body: some View {
        if points.count >= 2 {
            RouteMapRepresentable(points: points)
        } else {
            ZStack {
                StrandPalette.surfaceInset
                VStack(spacing: 8) {
                    Image(systemName: "map.fill")
                        .font(.title2.weight(.semibold))
                    Text("Route starts after GPS points arrive")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

private struct RouteMapRepresentable: UIViewRepresentable {
    let points: [IOSRoutePoint]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        let coordinates = simplified(points).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard coordinates.count >= 2 else { return }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        map.addOverlay(polyline)
        let padded = polyline.boundingMapRect.insetBy(
            dx: -max(100, polyline.boundingMapRect.width * 0.2),
            dy: -max(100, polyline.boundingMapRect.height * 0.2)
        )
        map.setVisibleMapRect(padded, animated: false)
    }

    private func simplified(_ points: [IOSRoutePoint]) -> [IOSRoutePoint] {
        guard points.count > 250 else { return points }
        let stride = max(1, points.count / 250)
        var reduced = points.enumerated().compactMap { index, point in
            index.isMultiple(of: stride) ? point : nil
        }
        if reduced.last != points.last, let last = points.last {
            reduced.append(last)
        }
        return reduced
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.systemTeal
            renderer.lineWidth = 4
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
    }
}

private struct PlanSummaryRow: View {
    let plan: IOSWorkoutPlan
    let delete: () -> Void

    var body: some View {
        PlanSummaryContent(plan: plan, showDelete: true, delete: delete)
    }
}

private struct PlanSummaryContent: View {
    let plan: IOSWorkoutPlan
    var showDelete = false
    var delete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: plan.kind == .strength ? "dumbbell.fill" : "figure.pool.swim")
                .font(.headline.weight(.semibold))
                .foregroundStyle(plan.kind == .strength ? StrandPalette.strain066 : StrandPalette.metricCyan)
                .frame(width: 32, height: 32)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            if showDelete, let delete {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StrandPalette.statusCritical)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
    }

    private var summary: String {
        switch plan.kind {
        case .strength:
            let sets = plan.strengthExercises.reduce(0) { $0 + max(1, $1.sets) }
            return "\(plan.strengthExercises.count) exercises · \(sets) sets"
        case .swim:
            let sets = plan.swimItems.reduce(0) { $0 + max(1, $1.sets) }
            return "\(plan.swimItems.count) strokes · \(sets) sets"
        }
    }
}

private struct ActivePlanView: View {
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    let active: IOSActiveWorkout
    let plan: IOSWorkoutPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.kind == .strength ? "STRENGTH PLAN" : "SWIM PLAN")
                .font(.caption.weight(.bold))
                .foregroundStyle(StrandPalette.textTertiary)
            Text(plan.name)
                .font(.headline.weight(.bold))
                .foregroundStyle(StrandPalette.textPrimary)

            switch plan.kind {
            case .strength:
                ForEach(plan.strengthExercises) { exercise in
                    StrengthExerciseLogView(active: active, exercise: exercise)
                }
            case .swim:
                ForEach(plan.swimItems) { item in
                    SourceRow(
                        name: item.stroke,
                        status: "\(item.sets) sets · \(item.distance)",
                        icon: "figure.pool.swim",
                        color: StrandPalette.metricCyan
                    )
                }
            }
        }
        .padding(12)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct StrengthExerciseLogView: View {
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    let active: IOSActiveWorkout
    let exercise: IOSStrengthPlanExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(exercise.name) · \(exercise.sets)x\(exercise.reps)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            ForEach(1...max(1, exercise.sets), id: \.self) { setIndex in
                HStack(spacing: 10) {
                    Text("Set \(setIndex)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 48, alignment: .leading)
                    TextField("Weight", text: weightBinding(setIndex))
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("lb")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    if let previous = previousWeight(setIndex) {
                        Text("Last \(previous)")
                            .font(.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(minWidth: 70, alignment: .leading)
                    }
                }
            }
        }
        .padding(10)
        .background(StrandPalette.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func weightBinding(_ setIndex: Int) -> Binding<String> {
        Binding {
            active.strengthSetLogs.first { $0.exerciseId == exercise.id && $0.setIndex == setIndex }?.weight ?? ""
        } set: { value in
            recorder.updateSetWeight(exerciseId: exercise.id, setIndex: setIndex, weight: value)
        }
    }

    private func previousWeight(_ setIndex: Int) -> String? {
        guard let planId = active.plan?.id else { return nil }
        return recorder.previousWeight(planId: planId, exerciseId: exercise.id, setIndex: setIndex, before: active.startedAt)
    }
}

private struct WorkoutPlanEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    let existingPlan: IOSWorkoutPlan?
    @State private var kind: IOSWorkoutPlanKind = .strength
    @State private var planName = ""
    @State private var strengthExercises: [IOSStrengthPlanExercise] = [
        IOSStrengthPlanExercise(name: "", sets: 3, reps: 10)
    ]
    @State private var swimItems: [IOSSwimPlanItem] = [
        IOSSwimPlanItem(stroke: "", sets: 4, distance: "50 yd")
    ]

    init(existingPlan: IOSWorkoutPlan? = nil) {
        self.existingPlan = existingPlan
        if let existingPlan {
            _kind = State(initialValue: existingPlan.kind)
            _planName = State(initialValue: existingPlan.name)
            _strengthExercises = State(initialValue: existingPlan.strengthExercises.isEmpty ? [IOSStrengthPlanExercise(name: "", sets: 3, reps: 10)] : existingPlan.strengthExercises)
            _swimItems = State(initialValue: existingPlan.swimItems.isEmpty ? [IOSSwimPlanItem(stroke: "", sets: 4, distance: "50 yd")] : existingPlan.swimItems)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Plan type", selection: $kind) {
                        ForEach(IOSWorkoutPlanKind.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind == .strength ? "DAY NAME" : "PLAN NAME")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                        TextField(kind == .strength ? "Push" : "Freestyle Endurance", text: $planName)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }

                    if kind == .strength {
                        StrengthPlanEditor(exercises: $strengthExercises)
                    } else {
                        SwimPlanEditor(items: $swimItems)
                    }
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(existingPlan == nil ? "Create Plan" : "Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        if existingPlan == nil {
                            recorder.addPlan(plan)
                        } else {
                            recorder.updatePlan(plan)
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        let nameOK = !planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch kind {
        case .strength:
            return nameOK && strengthExercises.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .swim:
            return nameOK && swimItems.contains { !$0.stroke.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private var plan: IOSWorkoutPlan {
        let cleanName = planName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .strength:
            return IOSWorkoutPlan(
                id: existingPlan?.id ?? UUID(),
                kind: .strength,
                name: cleanName,
                strengthExercises: strengthExercises
                    .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { IOSStrengthPlanExercise(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), sets: max(1, $0.sets), reps: max(1, $0.reps)) },
                createdAt: existingPlan?.createdAt ?? Date()
            )
        case .swim:
            return IOSWorkoutPlan(
                id: existingPlan?.id ?? UUID(),
                kind: .swim,
                name: cleanName,
                swimItems: swimItems
                    .filter { !$0.stroke.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { IOSSwimPlanItem(id: $0.id, stroke: $0.stroke.trimmingCharacters(in: .whitespacesAndNewlines), sets: max(1, $0.sets), distance: $0.distance.trimmingCharacters(in: .whitespacesAndNewlines)) },
                createdAt: existingPlan?.createdAt ?? Date()
            )
        }
    }
}

private struct StrengthPlanEditor: View {
    @Binding var exercises: [IOSStrengthPlanExercise]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EXERCISES")
                .font(.caption.weight(.bold))
                .foregroundStyle(StrandPalette.textTertiary)
            ForEach($exercises) { $exercise in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Exercise", text: $exercise.name)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
                    HStack(spacing: 10) {
                        Stepper("Sets \(exercise.sets)", value: $exercise.sets, in: 1...12)
                        Stepper("Reps \(exercise.reps)", value: $exercise.reps, in: 1...50)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(10)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10))
            }
            ActionButton(title: "Add Exercise", icon: "plus", color: StrandPalette.strain066) {
                exercises.append(IOSStrengthPlanExercise(name: "", sets: 3, reps: 10))
            }
        }
    }
}

private struct SwimPlanEditor: View {
    @Binding var items: [IOSSwimPlanItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SWIM SETS")
                .font(.caption.weight(.bold))
                .foregroundStyle(StrandPalette.textTertiary)
            ForEach($items) { $item in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Stroke", text: $item.stroke)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
                    HStack(spacing: 10) {
                        Stepper("Sets \(item.sets)", value: $item.sets, in: 1...30)
                        TextField("Distance", text: $item.distance)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(10)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10))
            }
            ActionButton(title: "Add Swim Set", icon: "plus", color: StrandPalette.metricCyan) {
                items.append(IOSSwimPlanItem(stroke: "", sets: 4, distance: "50 yd"))
            }
        }
    }
}

private struct WorkoutTypeButton: View {
    let type: IOSWorkoutType
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: type.icon)
                    .font(.title2.weight(.semibold))
                Text(type.name)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 92)
            .padding(8)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct LoggedWorkoutRow: View {
    let workout: IOSLoggedWorkout
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.typeName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(workout.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(durationText)")
                        .font(.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StrandPalette.statusCritical)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                ScoreCard(title: "Strain", value: workout.effectiveStrain.map { String(format: "%.1f", $0) } ?? "--", unit: "/21", color: StrandPalette.strainColor(workout.effectiveStrain ?? 0))
                ScoreCard(title: "Avg HR", value: workout.avgHR.map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.metricCyan)
                ScoreCard(title: "Max HR", value: workout.maxHR.map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.metricRose)
            }
            if workout.typeId == "run" || workout.typeId == "hiking" {
                HStack(spacing: 10) {
                    ScoreCard(title: "Distance", value: workout.distanceMeters.map { String(format: "%.2f", $0 / 1609.344) } ?? "--", unit: "mi", color: StrandPalette.metricCyan)
                    ScoreCard(title: "Pace", value: workout.paceSecondsPerMile.map(Self.paceText) ?? "--", unit: "/mi", color: StrandPalette.strain066)
                }
                RouteMapView(points: workout.routePoints)
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if workout.typeId == "treadmill", let distance = workout.treadmillDistance {
                SourceRow(name: "Treadmill Distance", status: "\(distance) mi", icon: "figure.run", color: StrandPalette.metricCyan)
            }
            if workout.typeId == "stairmaster", let flights = workout.stairFlights {
                SourceRow(name: "Flights Climbed", status: flights, icon: "figure.stairs", color: StrandPalette.metricAmber)
            }

            HRLineChart(samples: workout.hrSamples)
                .frame(height: 100)

            if !workout.notes.isEmpty {
                Text(workout.notes)
                    .font(.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
    }

    private var durationText: String {
        let minutes = max(1, Int((workout.durationSeconds / 60).rounded()))
        return "\(minutes) min"
    }

    private static func paceText(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct HRLineChart: View {
    let samples: [IOSWorkoutHRSample]

    var body: some View {
        InteractiveHRChart(
            samples: samples.map { HRChartSample(id: $0.id.uuidString, ts: $0.ts, bpm: $0.bpm) },
            emptyText: "Heart-rate graph starts after two samples"
        )
    }
}

private struct SleepIOSView: View {
    @EnvironmentObject private var health: IOSHealthStore
    @EnvironmentObject private var scanner: IOSWhoopScanner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ScoreCard(title: "Sleep", value: String(format: "%.1f", effectiveSleepHours), unit: "h", color: StrandPalette.metricCyan)
                    ScoreCard(title: "Recovery", value: scanner.metrics.recovery.map { "\(Int($0.rounded()))" } ?? "--", unit: "%", color: scanner.metrics.recovery.map(StrandPalette.recoveryColor) ?? StrandPalette.textTertiary)
                }
                NavigationLink {
                    SleepDetailView()
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SLEEP TIMELINE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                        SleepStageTimeline(intervals: effectiveSleepIntervals)
                            .frame(height: 118)
                    }
                    .padding(12)
                    .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                ForEach(effectiveSleepStages) { stage in
                    SourceRow(name: stage.name, status: String(format: "%.1f hours", stage.hours), icon: "moon.stars.fill", color: sleepColor(stage.name))
                }
                SourceRow(name: "WHOOP Sleep", status: scanner.metrics.whoopSleepStatus, icon: "waveform.path.ecg", color: StrandPalette.metricCyan)
                SourceRow(name: "Recovery Inputs", status: scanner.metrics.recoveryStatus, icon: "waveform.path.ecg", color: StrandPalette.metricPurple)
                SourceRow(name: "WHOOP HRV", status: scanner.metrics.hrvRMSSD.map { "\(Int($0.rounded())) ms RMSSD" } ?? "Waiting for WHOOP R-R intervals", icon: "waveform.path.ecg", color: StrandPalette.metricPurple)
                SourceRow(name: "WHOOP Resting HR", status: scanner.metrics.restingHR.map { "\($0) bpm" } ?? "Waiting for WHOOP heart-rate samples", icon: "heart.fill", color: StrandPalette.metricRose)
                SourceRow(name: "Raw SpO2 Ratio", status: scanner.metrics.sleepSpO2RawRatio.map { String(format: "%.3f red/IR ADC", $0) } ?? "Waiting for WHOOP raw SpO2 samples", icon: "drop.fill", color: StrandPalette.metricCyan)
                SourceRow(name: "Skin Temp ADC", status: scanner.metrics.sleepSkinTempRaw.map { String(format: "%.0f raw ADC", $0) } ?? "Waiting for WHOOP skin-temp samples", icon: "thermometer.medium", color: StrandPalette.metricAmber)
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .refreshable {
            await scanner.refreshDeviceMetricsNow()
        }
    }

    private func sleepColor(_ name: String) -> Color {
        switch name {
        case "Deep": return StrandPalette.sleepDeep
        case "REM": return StrandPalette.sleepREM
        case "Awake": return StrandPalette.sleepAwake
        default: return StrandPalette.sleepLight
        }
    }

    private var effectiveSleepHours: Double {
        NOOPSleepDisplay.hours(
            healthHours: health.sleepHours,
            whoopHours: scanner.metrics.whoopSleepHours,
            healthIntervals: health.sleepIntervals,
            whoopIntervals: scanner.metrics.whoopSleepIntervals
        )
    }

    private var effectiveSleepStages: [IOSSleepStageSummary] {
        NOOPSleepDisplay.stages(
            health: health.sleepStages,
            whoop: scanner.metrics.whoopSleepStages,
            healthIntervals: health.sleepIntervals,
            whoopIntervals: scanner.metrics.whoopSleepIntervals
        )
    }

    private var effectiveSleepIntervals: [IOSSleepInterval] {
        NOOPSleepDisplay.intervals(
            health: health.sleepIntervals,
            whoop: scanner.metrics.whoopSleepIntervals
        )
    }

}

private struct AlarmIOSView: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner
    @State private var wakeTime = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var status = "Connect your WHOOP and set a wake time."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DatePicker("Wake time", selection: $wakeTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

            ActionButton(title: "Arm Strap Alarm", icon: "alarm.fill", color: StrandPalette.metricCyan) {
                let next = nextWakeDate(from: wakeTime)
                scanner.armAlarm(at: next)
                status = "Alarm request sent for \(next.formatted(date: .omitted, time: .shortened)). Use Test Buzz to confirm haptics."
            }
            .disabled(!scanner.isBondReady)

            ActionButton(title: "Test Buzz", icon: "iphone.radiowaves.left.and.right", color: StrandPalette.accent) {
                scanner.buzz(loops: 2)
            }
            .disabled(!scanner.isBondReady)

            Text(status)
                .font(.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
        }
        .padding(16)
    }

    private func nextWakeDate(from date: Date) -> Date {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        var next = calendar.date(bySettingHour: comps.hour ?? 7, minute: comps.minute ?? 0, second: 0, of: Date()) ?? Date()
        if next <= Date() {
            next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
        }
        return next
    }
}

private struct MoreIOSView: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner
    @AppStorage("noop.ios.backgroundBLE") private var backgroundBLE = true
    @AppStorage("noop.ios.wristSide") private var wristSide = "left"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink {
                    SleepIOSView()
                } label: {
                    SourceRow(name: "Sleep", status: "\(String(format: "%.1f", scanner.metrics.whoopSleepHours)) h · WHOOP-derived stages", icon: "moon.stars.fill", color: StrandPalette.metricCyan)
                }
                .buttonStyle(.plain)

                NavigationLink {
                    AlarmIOSView()
                } label: {
                    SourceRow(name: "Wake Alarm", status: "Set WHOOP haptic alarm", icon: "alarm.fill", color: StrandPalette.metricCyan)
                }
                .buttonStyle(.plain)

                Picker("WHOOP wrist", selection: $wristSide) {
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                }
                .pickerStyle(.segmented)
                .padding(10)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                Toggle("Background Bluetooth", isOn: $backgroundBLE)
                ActionButton(title: "Refresh WHOOP Metrics", icon: "externaldrive.fill", color: StrandPalette.accent) {
                    Task { await scanner.refreshDeviceMetricsNow() }
                }
                SourceRow(name: "WHOOP Wrist", status: "Set to \(wristSide.capitalized). Motion is handled from WHOOP gravity magnitude.", icon: "hand.raised.fill", color: StrandPalette.metricPurple)
                SourceRow(name: "Data Sources", status: "Recovery, strain, sleep, steps, workouts, HRV, RHR, respiration, raw SpO2, and skin-temp use WHOOP data stored locally.", icon: "lock.shield.fill", color: StrandPalette.accent)
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .refreshable { await scanner.refreshDeviceMetricsNow() }
    }
}

private struct LiveSummaryCard: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIVE STATUS").font(.caption.weight(.bold)).foregroundStyle(StrandPalette.textTertiary)
                    Text(scanner.connectionState)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(scanner.deviceName ?? "WHOOP 4.0")
                        .font(.subheadline)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    scanner.isConnected ? scanner.disconnect() : scanner.start()
                } label: {
                    Image(systemName: scanner.isConnected ? "xmark" : "dot.radiowaves.left.and.right")
                        .font(.title2.weight(.semibold))
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(scanner.isConnected ? StrandPalette.statusCritical : StrandPalette.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(!scanner.canScan && !scanner.isConnected)
            }

            HStack(spacing: 10) {
                ScoreCard(title: "HR", value: scanner.heartRate.map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.zone3)
                ScoreCard(title: "Battery", value: scanner.batteryPercent.map { "\($0)" } ?? "--", unit: "%", color: StrandPalette.accent)
                ScoreCard(title: "R-R", value: "\(scanner.rrIntervals.count)", unit: "", color: StrandPalette.metricPurple)
            }
        }
        .padding(14)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(StrandPalette.hairline, lineWidth: 1) }
    }
}

private struct DayPickerHeader: View {
    @Binding var selectedDate: Date
    let openCalendar: () -> Void

    var body: some View {
        HStack {
            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)

            Spacer()
            Button(action: openCalendar) {
                HStack(spacing: 8) {
                    Text(dateText)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Image(systemName: "calendar")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceRaised, in: Capsule())
                .overlay { Capsule().stroke(StrandPalette.hairline, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            Spacer()

            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .disabled(Calendar.current.isDateInToday(selectedDate))
            .opacity(Calendar.current.isDateInToday(selectedDate) ? 0.35 : 1)
        }
        .foregroundStyle(StrandPalette.textPrimary)
    }

    private var dateText: String {
        if Calendar.current.isDateInToday(selectedDate) { return "Today" }
        if Calendar.current.isDateInYesterday(selectedDate) { return "Yesterday" }
        return selectedDate.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct MetricsRefreshBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(StrandPalette.accent)
                .scaleEffect(0.86)
            VStack(alignment: .leading, spacing: 2) {
                Text("Updating metrics")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Raw WHOOP samples are being summarized now.")
                    .font(.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(StrandPalette.surfaceRaised, in: Capsule())
        .overlay { Capsule().stroke(StrandPalette.hairline, lineWidth: 1) }
    }
}

private struct RecoveryCalendarSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDate: Date
    @Binding var visibleMonth: Date
    let recoveryScoresByDay: [String: Double]
    let onMonthChanged: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    shiftMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)

                Spacer()
                Text(monthTitle)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()

                Button {
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .disabled(isNextMonthInFuture)
                .opacity(isNextMonthInFuture ? 0.35 : 1)
            }

            HStack(spacing: 0) {
                ForEach(Calendar.current.shortStandaloneWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol.prefix(1))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(calendarDays, id: \.self) { date in
                    if let date {
                        Button {
                            selectedDate = date
                            dismiss()
                        } label: {
                            dayCell(date)
                        }
                        .buttonStyle(.plain)
                        .disabled(date > Date())
                        .opacity(date > Date() ? 0.35 : 1)
                    } else {
                        Color.clear.frame(height: 42)
                    }
                }
            }

            HStack(spacing: 10) {
                legendDot("Green", color: StrandPalette.recoveryColor(80))
                legendDot("Yellow", color: StrandPalette.recoveryColor(50))
                legendDot("Red", color: StrandPalette.recoveryColor(20))
                Spacer()
            }
        }
        .padding(18)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onAppear {
            onMonthChanged(visibleMonth)
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let score = recoveryScoresByDay[dayString(date)]
        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
        let color = score.map(StrandPalette.recoveryColor) ?? StrandPalette.textTertiary
        return ZStack {
            Circle()
                .fill(score == nil ? StrandPalette.surfaceRaised : color.opacity(0.9))
                .overlay {
                    Circle().stroke(isSelected ? StrandPalette.textPrimary : StrandPalette.hairline, lineWidth: isSelected ? 2 : 1)
                }
            VStack(spacing: 0) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(score == nil ? StrandPalette.textSecondary : .black)
                if let score {
                    Text("\(Int(score.rounded()))")
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(.black.opacity(0.75))
                }
            }
        }
        .frame(height: 42)
    }

    private var calendarDays: [Date?] {
        let calendar = Calendar.current
        guard let month = calendar.dateInterval(of: .month, for: visibleMonth),
              let days = calendar.range(of: .day, in: .month, for: visibleMonth) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: month.start)
        let leading = max(0, firstWeekday - calendar.firstWeekday)
        let dates = days.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: month.start)
        }
        return Array(repeating: nil, count: leading) + dates
    }

    private var monthTitle: String {
        visibleMonth.formatted(.dateTime.month(.wide).year())
    }

    private var isNextMonthInFuture: Bool {
        guard let next = Calendar.current.date(byAdding: .month, value: 1, to: visibleMonth) else { return true }
        return Calendar.current.startOfDay(for: next) > Calendar.current.startOfDay(for: Date())
    }

    private func shiftMonth(_ value: Int) {
        visibleMonth = Calendar.current.date(byAdding: .month, value: value, to: visibleMonth) ?? visibleMonth
        onMonthChanged(visibleMonth)
    }

    private func legendDot(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct LoadGuidanceCard: View {
    let guidance: IOSLoadGuidance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(guidance.title, systemImage: "gauge.with.dots.needle.bottom.50percent")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(color)
                Spacer()
                if let acwr = guidance.acwr {
                    Text(String(format: "%.2f", acwr))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(color)
                }
            }
            Text(guidance.detail)
                .font(.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            if let low = guidance.targetLow, let high = guidance.targetHigh {
                Text("Suggested strain target: \(String(format: "%.1f", low))-\(String(format: "%.1f", high))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.35), lineWidth: 1) }
    }

    private var color: Color {
        switch guidance.colorKey {
        case "good": return StrandPalette.accent
        case "bad": return StrandPalette.statusCritical
        case "watch": return StrandPalette.metricAmber
        default: return StrandPalette.textTertiary
        }
    }
}

private struct TodayWorkoutList: View {
    let workouts: [IOSLoggedWorkout]
    let detectedWorkouts: [IOSDeviceWorkout]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKOUTS")
                .font(.caption.weight(.bold))
                .foregroundStyle(StrandPalette.textTertiary)
            if workouts.isEmpty && detectedWorkouts.isEmpty {
                SourceRow(name: "No workouts", status: "Logged and WHOOP-detected workouts appear here.", icon: "figure.run", color: StrandPalette.textTertiary)
            } else {
                ForEach(workouts) { workout in
                    NavigationLink {
                        WorkoutDetailView(workout: workout)
                    } label: {
                        TodayWorkoutRow(workout: workout)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(detectedWorkouts) { workout in
                    SourceRow(
                        name: workout.title,
                        status: "\(workout.durationMinutes) min · avg \(workout.avgHR) bpm · max \(workout.maxHR) bpm",
                        icon: "figure.run",
                        color: StrandPalette.strain066
                    )
                }
            }
        }
    }
}

private struct TodayWorkoutRow: View {
    let workout: IOSLoggedWorkout

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.clipboard.fill")
                .font(.headline)
                .foregroundStyle(StrandPalette.strain066)
                .frame(width: 34, height: 34)
                .background(StrandPalette.strain066.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.typeName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(durationText) · avg \(workout.avgHR.map(String.init) ?? "--") bpm · strain \(workout.effectiveStrain.map { String(format: "%.1f", $0) } ?? "--")")
                    .font(.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
    }

    private var durationText: String {
        let minutes = max(1, Int((workout.durationSeconds / 60).rounded()))
        return "\(minutes) min"
    }
}

private struct WorkoutDetailView: View {
    let workout: IOSLoggedWorkout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ScoreCard(title: "Strain", value: workout.effectiveStrain.map { String(format: "%.1f", $0) } ?? "--", unit: "/21", color: StrandPalette.strainColor(workout.effectiveStrain ?? 0))
                    ScoreCard(title: "Duration", value: "\(max(1, Int((workout.durationSeconds / 60).rounded())))", unit: "min", color: StrandPalette.strain066)
                }
                HStack(spacing: 10) {
                    ScoreCard(title: "Avg HR", value: workout.avgHR.map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.metricCyan)
                    ScoreCard(title: "Max HR", value: workout.maxHR.map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.metricRose)
                }
                HRLineChart(samples: workout.hrSamples)
                    .frame(height: 220)
                if workout.typeId == "run" || workout.typeId == "hiking" {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            ScoreCard(title: "Distance", value: workout.distanceMeters.map { String(format: "%.2f", $0 / 1609.344) } ?? "--", unit: "mi", color: StrandPalette.metricCyan)
                            ScoreCard(title: "Pace", value: workout.paceSecondsPerMile.map(Self.paceText) ?? "--", unit: "/mi", color: StrandPalette.strain066)
                        }
                        RouteMapView(points: workout.routePoints)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(StrandPalette.hairline, lineWidth: 1) }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("NOTES")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(workout.notes.isEmpty ? "No notes logged." : workout.notes)
                        .font(.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .navigationTitle(workout.typeName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func paceText(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ScoreCard: View {
    let title: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 27, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RingScoreCard: View {
    let title: String
    let value: Double?
    let valueText: String
    let unit: String
    let progress: Double
    let color: Color
    var secondaryTitle: String? = nil
    var secondaryValueText: String? = nil
    var secondaryProgress: Double? = nil
    var secondaryColor: Color? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(StrandPalette.textTertiary)
            ZStack {
                Circle()
                    .stroke(StrandPalette.surfaceInset, lineWidth: 13)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                    .stroke(color, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let secondaryProgress, let secondaryColor {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(1, max(0, secondaryProgress))))
                        .stroke(secondaryColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(18)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(valueText)
                        .font(.system(size: 31, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(value == nil ? StrandPalette.textTertiary : color)
                        .minimumScaleFactor(0.55)
                    Text(unit)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 12)
            }
            .frame(width: 136, height: 136)
            if let secondaryTitle, let secondaryValueText, let secondaryColor {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(secondaryTitle.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(secondaryValueText)
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(secondaryColor)
                    Text("/21")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 206)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(StrandPalette.hairline, lineWidth: 1) }
    }
}

private struct HospitalHRChart: View {
    let samples: [IOSMetricHRSample]
    var intervals: [HRChartInterval] = []
    var compactPreview = true
    var visibleWindowHoursOverride: Int? = nil
    var allowsPinchZoom = false

    var body: some View {
        InteractiveHRChart(
            samples: samples.map { HRChartSample(id: "\($0.id)", ts: $0.ts, bpm: $0.bpm) },
            emptyText: "Waiting for WHOOP HR",
            intervals: intervals,
            averagePerMinute: true,
            visibleWindowHours: visibleWindowHoursOverride ?? (compactPreview ? 12 : nil),
            allowsSelection: !compactPreview,
            allowsPinchZoom: allowsPinchZoom
        )
    }
}

private struct HRChartSample: Identifiable, Equatable {
    let id: String
    let ts: Int
    let bpm: Int
}

private struct HRChartInterval: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    let title: String
    let color: Color

    var startTs: Int { Int(start.timeIntervalSince1970) }
    var endTs: Int { Int(end.timeIntervalSince1970) }
}

private struct HRChartLayout {
    let plotRect: CGRect
    let firstTs: Int
    let lastTs: Int
    let minY: Double
    let maxY: Double

    func x(for ts: Int) -> CGFloat {
        guard lastTs > firstTs else { return plotRect.minX }
        let normalized = Double(ts - firstTs) / Double(lastTs - firstTs)
        return plotRect.minX + CGFloat(normalized) * plotRect.width
    }

    func y(for bpm: Int) -> CGFloat {
        let normalized = (Double(bpm) - minY) / (maxY - minY)
        return plotRect.minY + CGFloat(1 - normalized) * plotRect.height
    }

    func ts(forX x: CGFloat) -> Int {
        guard plotRect.width > 0 else { return firstTs }
        let normalized = Double((x - plotRect.minX) / plotRect.width)
        return firstTs + Int((Double(lastTs - firstTs) * normalized).rounded())
    }
}

private struct InteractiveHRChart: View {
    let samples: [HRChartSample]
    let emptyText: String
    var intervals: [HRChartInterval] = []
    var averagePerMinute = false
    var visibleWindowHours: Int?
    var allowsSelection = true
    var allowsPinchZoom = false
    @State private var selectedSample: HRChartSample?
    @State private var baseZoom: CGFloat = 1
    @State private var pinchScale: CGFloat = 1
    @State private var zoomCenterTs: Int?

    var body: some View {
        GeometryReader { proxy in
            let chartSamples = plottedSamples
            let layout = chartLayout(in: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(StrandPalette.surfaceInset)
                if chartSamples.count < 2 {
                    Text(emptyText)
                        .font(.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    intervalOverlays(layout: layout)
                    grid(in: layout.plotRect)
                        .stroke(StrandPalette.metricRose.opacity(0.12), lineWidth: 0.7)
                    yAxisLabels(layout: layout)
                    xAxisLabels(layout: layout)
                    Path { path in
                        let points = chartPoints(samples: chartSamples, layout: layout)
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(StrandPalette.metricRose, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .shadow(color: StrandPalette.metricRose.opacity(0.18), radius: 2)

                    if averagePerMinute {
                        Text("1-min avg")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(StrandPalette.surfaceRaised.opacity(0.82), in: Capsule())
                            .position(x: layout.plotRect.maxX - 34, y: layout.plotRect.minY + 12)
                    }

                    if allowsPinchZoom {
                        zoomBadge(layout: layout)
                    }

                    if let selectedSample {
                        selectionOverlay(sample: selectedSample, layout: layout)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(allowsSelection ? DragGesture(minimumDistance: 0)
                .onChanged { value in
                    updateSelection(near: value.location, samples: chartSamples, layout: layout)
                } : nil)
            .simultaneousGesture(allowsPinchZoom ? MagnificationGesture()
                .onChanged { value in
                    if zoomCenterTs == nil {
                        zoomCenterTs = selectedSample?.ts ?? ((fullDomain?.first ?? 0) + (fullDomain?.last ?? 0)) / 2
                    }
                    pinchScale = value
                }
                .onEnded { value in
                    baseZoom = clampedZoom(baseZoom * value)
                    pinchScale = 1
                    if baseZoom <= 1.01 {
                        baseZoom = 1
                        zoomCenterTs = nil
                    }
                } : nil)
            .onReceive(NotificationCenter.default.publisher(for: .noopClearHRChartSelection)) { _ in
                selectedSample = nil
            }
        }
    }

    private func chartLayout(in size: CGSize) -> HRChartLayout {
        let chartSamples = plottedSamples
        guard let first = chartSamples.first?.ts, let last = chartSamples.last?.ts, last > first else {
            return HRChartLayout(plotRect: .zero, firstTs: 0, lastTs: 1, minY: 40, maxY: 120)
        }
        let minBPM = chartSamples.map(\.bpm).min() ?? 40
        let maxBPM = chartSamples.map(\.bpm).max() ?? 120
        let minY = Double(max(40, minBPM - 8))
        let maxY = max(minY + 25, Double(maxBPM + 8))
        let plotRect = CGRect(
            x: 42,
            y: 12,
            width: max(1, size.width - 54),
            height: max(1, size.height - 38)
        )
        return HRChartLayout(plotRect: plotRect, firstTs: first, lastTs: last, minY: minY, maxY: maxY)
    }

    private var plottedSamples: [HRChartSample] {
        let ordered = samples.sorted { $0.ts < $1.ts }
        let windowed: [HRChartSample]
        if let visibleWindowHours, let last = ordered.last?.ts {
            let start = last - visibleWindowHours * 3600
            windowed = ordered.filter { $0.ts >= start }
        } else if allowsPinchZoom,
                  let first = ordered.first?.ts,
                  let last = ordered.last?.ts,
                  last > first {
            let zoom = clampedZoom(baseZoom * pinchScale)
            if zoom <= 1.01 {
                windowed = ordered
            } else {
                let fullSpan = last - first
                let span = max(10 * 60, Int((Double(fullSpan) / Double(zoom)).rounded()))
                let center = min(last, max(first, zoomCenterTs ?? selectedSample?.ts ?? ((first + last) / 2)))
                let start = min(max(first, center - span / 2), max(first, last - span))
                let end = min(last, start + span)
                windowed = ordered.filter { $0.ts >= start && $0.ts <= end }
            }
        } else {
            windowed = ordered
        }
        guard averagePerMinute else { return windowed }
        let buckets = Dictionary(grouping: windowed) { $0.ts / 60 }
        return buckets.keys.sorted().compactMap { minute in
            guard let samples = buckets[minute], !samples.isEmpty else { return nil }
            let avg = Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)
            return HRChartSample(id: "minute-\(minute)", ts: minute * 60 + 30, bpm: Int(avg.rounded()))
        }
    }

    private func grid(in rect: CGRect) -> Path {
        Path { path in
            for index in 0...4 {
                let y = rect.minY + (CGFloat(index) / 4) * rect.height
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            for index in 0...4 {
                let x = rect.minX + (CGFloat(index) / 4) * rect.width
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
        }
    }

    private func chartPoints(samples: [HRChartSample], layout: HRChartLayout) -> [CGPoint] {
        return samples.map { sample in
            CGPoint(x: layout.x(for: sample.ts), y: layout.y(for: sample.bpm))
        }
    }

    private func intervalOverlays(layout: HRChartLayout) -> some View {
        ZStack(alignment: .leading) {
            ForEach(intervals.filter { $0.endTs > layout.firstTs && $0.startTs < layout.lastTs }) { interval in
                let startX = layout.x(for: max(interval.startTs, layout.firstTs))
                let endX = layout.x(for: min(interval.endTs, layout.lastTs))
                let width = max(3, endX - startX)
                RoundedRectangle(cornerRadius: 4)
                    .fill(interval.color.opacity(0.15))
                    .frame(width: width, height: layout.plotRect.height)
                    .overlay(alignment: .topLeading) {
                        if width > 46 {
                            Text(interval.title)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(interval.color.opacity(0.95))
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.top, 3)
                        }
                    }
                    .position(x: startX + width / 2, y: layout.plotRect.midY)
            }
        }
    }

    private func yAxisLabels(layout: HRChartLayout) -> some View {
        ZStack {
            axisLabel("\(Int(layout.maxY.rounded()))")
                .position(x: 21, y: layout.plotRect.minY + 2)
            axisLabel("\(Int(((layout.maxY + layout.minY) / 2).rounded()))")
                .position(x: 21, y: layout.plotRect.midY)
            axisLabel("\(Int(layout.minY.rounded()))")
                .position(x: 21, y: layout.plotRect.maxY - 2)
            Text("bpm")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(StrandPalette.textTertiary)
                .position(x: 21, y: layout.plotRect.maxY + 16)
        }
    }

    private func xAxisLabels(layout: HRChartLayout) -> some View {
        ZStack {
            axisLabel(timeText(layout.firstTs))
                .position(x: layout.plotRect.minX, y: layout.plotRect.maxY + 16)
            axisLabel(timeText((layout.firstTs + layout.lastTs) / 2))
                .position(x: layout.plotRect.midX, y: layout.plotRect.maxY + 16)
            axisLabel(timeText(layout.lastTs))
                .position(x: layout.plotRect.maxX, y: layout.plotRect.maxY + 16)
        }
    }

    private func selectionOverlay(sample: HRChartSample, layout: HRChartLayout) -> some View {
        let point = CGPoint(x: layout.x(for: sample.ts), y: layout.y(for: sample.bpm))
        let labelX = min(max(point.x, layout.plotRect.minX + 48), layout.plotRect.maxX - 48)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: point.x, y: layout.plotRect.minY))
                path.addLine(to: CGPoint(x: point.x, y: layout.plotRect.maxY))
            }
            .stroke(StrandPalette.textSecondary.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            Circle()
                .fill(StrandPalette.metricRose)
                .frame(width: 10, height: 10)
                .position(point)
            Text("\(sample.bpm) bpm  \(timeText(sample.ts))")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(StrandPalette.surfaceRaised, in: Capsule())
                .overlay { Capsule().stroke(StrandPalette.hairline, lineWidth: 1) }
                .position(x: labelX, y: max(layout.plotRect.minY + 14, point.y - 22))
        }
    }

    private func zoomBadge(layout: HRChartLayout) -> some View {
        let zoom = clampedZoom(baseZoom * pinchScale)
        let text = zoom <= 1.05 ? "Pinch to zoom" : String(format: "%.1fx", zoom)
        return Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(StrandPalette.surfaceRaised.opacity(0.82), in: Capsule())
            .position(x: layout.plotRect.maxX - 42, y: layout.plotRect.minY + 32)
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(StrandPalette.textTertiary)
    }

    private func updateSelection(near point: CGPoint, samples: [HRChartSample], layout: HRChartLayout) {
        guard layout.plotRect.insetBy(dx: -8, dy: -8).contains(point) else {
            selectedSample = nil
            return
        }
        let target = layout.ts(forX: point.x)
        zoomCenterTs = target
        selectedSample = samples.min { lhs, rhs in
            abs(lhs.ts - target) < abs(rhs.ts - target)
        }
    }

    private var fullDomain: (first: Int, last: Int)? {
        let ordered = samples.sorted { $0.ts < $1.ts }
        guard let first = ordered.first?.ts, let last = ordered.last?.ts, last > first else { return nil }
        return (first, last)
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(48, max(1, value))
    }

    private func timeText(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .omitted, time: .shortened)
    }
}

private struct HRIntervalLegend: View {
    let intervals: [HRChartInterval]

    var body: some View {
        if !visibleIntervals.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleIntervals) { interval in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(interval.color)
                                .frame(width: 10, height: 10)
                            Text(interval.title)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(timeRange(interval))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(interval.color.opacity(0.12), in: Capsule())
                        .overlay { Capsule().stroke(interval.color.opacity(0.35), lineWidth: 1) }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var visibleIntervals: [HRChartInterval] {
        intervals.sorted { $0.start < $1.start }
    }

    private func timeRange(_ interval: HRChartInterval) -> String {
        "\(interval.start.formatted(date: .omitted, time: .shortened))-\(interval.end.formatted(date: .omitted, time: .shortened))"
    }
}

private struct HeartRateDayView: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner
    let samples: [IOSMetricHRSample]
    let intervals: [HRChartInterval]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HospitalHRChart(
                    samples: samples,
                    intervals: intervals,
                    compactPreview: false,
                    visibleWindowHoursOverride: nil,
                    allowsPinchZoom: true
                )
                    .frame(height: 240)
                HRIntervalLegend(intervals: intervals)
                HStack(spacing: 10) {
                    ScoreCard(title: "Average", value: average.map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.metricCyan)
                    ScoreCard(title: "Max", value: samples.map(\.bpm).max().map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.metricRose)
                }
                HStack(spacing: 10) {
                    ScoreCard(title: "Min", value: samples.map(\.bpm).min().map { "\($0)" } ?? "--", unit: "bpm", color: StrandPalette.accent)
                    ScoreCard(title: "Daily HRV", value: scanner.metrics.hrvRMSSD.map { "\(Int($0.rounded()))" } ?? "--", unit: "ms", color: StrandPalette.metricPurple)
                }
                if let restingHR = scanner.metrics.restingHR {
                    ScoreCard(title: "Resting HR", value: "\(restingHR)", unit: "bpm", color: StrandPalette.metricAmber)
                }
            }
            .padding(16)
            .padding(.bottom, 96)
            .contentShape(Rectangle())
            .onTapGesture {
                clearNOOPChartSelection()
            }
        }
        .navigationTitle("Heart Rate")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var average: Int? {
        guard !samples.isEmpty else { return nil }
        return Int((Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)).rounded())
    }
}

private struct RecoveryExplanationView: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ExplanationHeader(
                    title: "Recovery",
                    value: scanner.metrics.recovery.map { "\(Int($0.rounded()))%" } ?? "--",
                    color: scanner.metrics.recovery.map(StrandPalette.recoveryColor) ?? StrandPalette.textTertiary
                )
                ExplanationBlock(
                    title: "How it is calculated",
                    text: "Recovery is a local NOOP score from WHOOP sleep data. It compares overnight HRV and resting HR against your own baseline, then adjusts with sleep quality, respiratory rate, recent load, and raw SpO2/skin-temp deviations when those signals are available."
                )
                ExplanationBlock(
                    title: "What matters most",
                    text: "HRV is the strongest driver. Lower resting HR, better sleep, stable respiration, supported recent load, and no unusual raw SpO2 or skin-temp drift all push recovery higher. Missing optional signals are skipped instead of blocking the score."
                )
                SourceRow(name: "Current inputs", status: scanner.metrics.recoveryStatus, icon: "waveform.path.ecg", color: StrandPalette.metricPurple)
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StrainExplanationView: View {
    @EnvironmentObject private var scanner: IOSWhoopScanner
    @EnvironmentObject private var recorder: IOSWorkoutRecorder
    @EnvironmentObject private var health: IOSHealthStore

    var body: some View {
        let rawStrain = effectiveDailyStrain
        let adjustedLoad = IOSStrainEstimator.recoveryAdjustedLoad(strain: rawStrain, recovery: scanner.metrics.recovery)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ExplanationHeader(
                    title: "Strain",
                    value: rawStrain.map { String(format: "%.1f /21", $0) } ?? "--",
                    color: rawStrain == nil ? StrandPalette.textTertiary : StrandPalette.metricCyan
                )
                ExplanationBlock(
                    title: "Daily strain stream",
                    text: "The Today strain circle is calculated from the WHOOP heart-rate samples collected after your main overnight sleep ends. NOOP builds one awake-day stream from stored WHOOP samples, live WHOOP samples, active workout samples, and saved workout samples for today. Samples with the same timestamp are merged so a workout is not double-counted. Sleep intervals are used only to find the wake-up point, then sleep time is excluded from daily strain."
                )
                ExplanationBlock(
                    title: "Workout strain stream",
                    text: "When you start a workout, NOOP also opens a separate workout stream. That workout strain is isolated to the workout start and finish time, so it only describes that session. The daily strain circle is different: it uses the full awake-day stream, so the workout period is naturally included along with the heart-rate load from before and after the workout."
                )
                ExplanationBlock(
                    title: "Heart-rate load",
                    text: "NOOP converts each heart-rate interval into heart-rate reserve load. Heart-rate reserve compares your current BPM with an estimated resting heart rate and estimated max heart rate, so 130 BPM is treated differently depending on how hard that is relative to your range. For higher-intensity periods, NOOP uses Edwards-style heart-rate-zone TRIMP weighting. For lighter awake activity below the Edwards zones, it uses a Banister-style continuous TRIMP curve so walking, chores, and easy movement can add small amounts of strain instead of being ignored."
                )
                ExplanationBlock(
                    title: "0-21 score",
                    text: "After the app sums TRIMP load across the day, it maps that load onto a 0-21 logarithmic strain scale. The logarithmic shape matters: early movement raises strain quickly, but each additional point requires more work than the last. This is why going from 1 to 3 is much easier than going from 12 to 14."
                )
                ExplanationBlock(
                    title: "Display fallback",
                    text: "For the Today card, NOOP shows the highest trustworthy value available: the computed awake-day strain, any stored device-derived daily strain, or the highest saved workout strain. That guardrail prevents the daily circle from showing less than a workout it contains. If daily strain exactly matches a workout, it usually means the non-workout heart-rate load was low, the daily WHOOP stream is still catching up, or the workout is currently the strongest complete strain value available."
                )
                ExplanationBlock(
                    title: "Adjusted load",
                    text: "Raw strain stays blue and always represents the actual HR-load score. The purple adjusted-load number estimates how costly that same strain is today after considering recovery. When recovery is high, adjusted load stays close to raw strain. When recovery is low, the app treats your available capacity as lower, so the same workout or daily load is shown as more expensive."
                )
                HStack(spacing: 10) {
                    ScoreCard(title: "Raw", value: rawStrain.map { String(format: "%.1f", $0) } ?? "--", unit: "/21", color: StrandPalette.metricCyan)
                    ScoreCard(title: "Adj Load", value: adjustedLoad.map { String(format: "%.1f", $0) } ?? "--", unit: "/21", color: StrandPalette.metricPurple)
                }
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .navigationTitle("Strain")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var workoutsForToday: [IOSLoggedWorkout] {
        recorder.workouts.filter { Calendar.current.isDateInToday($0.startedAt) }
    }

    private var effectiveDailyStrain: Double? {
        let computed = IOSStrainEstimator.awakeDayStrain(metricSamples: awakeDayHRSamples)
        let bestWorkout = workoutsForToday.compactMap(\.effectiveStrain).max()
        return [computed, scanner.metrics.strain, bestWorkout]
            .compactMap { $0 }
            .max()
    }

    private var awakeDayHRSamples: [IOSMetricHRSample] {
        let sleepIntervals = NOOPSleepDisplay.intervals(
            health: health.sleepIntervals,
            whoop: scanner.metrics.whoopSleepIntervals
        )
        let selectedDayStart = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let morningCutoff = selectedDayStart + 14 * 3600
        let wakeTs = sleepIntervals
            .filter { $0.stage != "Awake" }
            .filter {
                let end = Int($0.end.timeIntervalSince1970)
                return end >= selectedDayStart && end <= morningCutoff
            }
            .map { Int($0.end.timeIntervalSince1970) }
            .max()
        let startTs = max(selectedDayStart, wakeTs ?? selectedDayStart)
        var byTs: [Int: Int] = [:]
        for sample in dailyCalculationSamples where sample.ts >= startTs {
            byTs[sample.ts] = sample.bpm
        }
        for workout in workoutsForToday {
            for sample in workout.hrSamples where sample.ts >= startTs {
                byTs[sample.ts] = sample.bpm
            }
        }
        if let active = recorder.active, Calendar.current.isDateInToday(active.startedAt) {
            for sample in active.hrSamples where sample.ts >= startTs {
                byTs[sample.ts] = sample.bpm
            }
        }
        return byTs.keys.sorted().enumerated().map { index, ts in
            IOSMetricHRSample(id: index, ts: ts, bpm: byTs[ts] ?? 0)
        }
    }

    private var dailyCalculationSamples: [IOSMetricHRSample] {
        scanner.metrics.dailyHRSamples.isEmpty ? scanner.metrics.todayHRSamples : scanner.metrics.dailyHRSamples
    }
}

private struct ExplanationHeader: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(StrandPalette.hairline, lineWidth: 1) }
    }
}

private struct ExplanationBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(StrandPalette.textTertiary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SleepDetailView: View {
    @EnvironmentObject private var health: IOSHealthStore
    @EnvironmentObject private var scanner: IOSWhoopScanner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SleepStageTimeline(intervals: effectiveSleepIntervals)
                    .frame(height: 190)
                    .padding(12)
                    .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 10) {
                    ScoreCard(title: "Start", value: sleepStart, unit: "", color: StrandPalette.metricCyan)
                    ScoreCard(title: "End", value: sleepEnd, unit: "", color: StrandPalette.metricCyan)
                }
                HStack(spacing: 10) {
                    ScoreCard(title: "Asleep", value: String(format: "%.1f", effectiveSleepHours), unit: "h", color: StrandPalette.metricCyan)
                    ScoreCard(title: "Efficiency", value: "\(Int((effectiveSleepEfficiency * 100).rounded()))", unit: "%", color: StrandPalette.recoveryColor(effectiveSleepEfficiency * 100))
                }
                ScoreCard(title: "Sleep HRV", value: scanner.metrics.sleepHRVRMSSD.map { "\(Int($0.rounded()))" } ?? "--", unit: "ms", color: StrandPalette.metricPurple)
                ForEach(effectiveSleepStages) { stage in
                    SourceRow(name: stage.name, status: String(format: "%.1f hours", stage.hours), icon: "moon.stars.fill", color: sleepStageColor(stage.name))
                }
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sleepStart: String {
        guard let start = effectiveSleepIntervals.map(\.start).min() else { return "--" }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private var sleepEnd: String {
        guard let end = effectiveSleepIntervals.map(\.end).max() else { return "--" }
        return end.formatted(date: .omitted, time: .shortened)
    }

    private var effectiveSleepHours: Double {
        NOOPSleepDisplay.hours(
            healthHours: health.sleepHours,
            whoopHours: scanner.metrics.whoopSleepHours,
            healthIntervals: health.sleepIntervals,
            whoopIntervals: scanner.metrics.whoopSleepIntervals
        )
    }

    private var effectiveSleepEfficiency: Double {
        NOOPSleepDisplay.efficiency(
            healthEfficiency: health.sleepEfficiency,
            whoopEfficiency: scanner.metrics.whoopSleepEfficiency,
            healthIntervals: health.sleepIntervals,
            whoopIntervals: scanner.metrics.whoopSleepIntervals
        )
    }

    private var effectiveSleepStages: [IOSSleepStageSummary] {
        NOOPSleepDisplay.stages(
            health: health.sleepStages,
            whoop: scanner.metrics.whoopSleepStages,
            healthIntervals: health.sleepIntervals,
            whoopIntervals: scanner.metrics.whoopSleepIntervals
        )
    }

    private var effectiveSleepIntervals: [IOSSleepInterval] {
        NOOPSleepDisplay.intervals(
            health: health.sleepIntervals,
            whoop: scanner.metrics.whoopSleepIntervals
        )
    }
}

private struct SleepStageTimeline: View {
    let intervals: [IOSSleepInterval]
    @State private var selectedInterval: IOSSleepInterval?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(StrandPalette.surfaceInset)
                if intervals.isEmpty {
                    Text("No sleep intervals yet")
                        .font(.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stageRows(size: proxy.size)
                    ForEach(intervals) { interval in
                        segment(for: interval, size: proxy.size)
                    }
                    if let selectedInterval {
                        selectedOverlay(for: selectedInterval, size: proxy.size)
                    }
                    VStack {
                        Spacer()
                        HStack {
                            Text(startLabel)
                            Spacer()
                            Text(endLabel)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(10)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        selectInterval(at: value.location, size: proxy.size)
                    }
            )
        }
    }

    private func stageRows(size: CGSize) -> some View {
        let stages = ["Awake", "REM", "Core", "Deep"]
        let laneHeight = max(16, (size.height - 34) / 4.0)
        return ZStack(alignment: .leading) {
            ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                let y = 10 + CGFloat(index) * laneHeight
                Path { path in
                    path.move(to: CGPoint(x: 48, y: y + laneHeight))
                    path.addLine(to: CGPoint(x: size.width - 8, y: y + laneHeight))
                }
                .stroke(StrandPalette.hairline.opacity(0.55), lineWidth: 0.7)
                Text(stage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(sleepStageColor(stage))
                    .frame(width: 42, alignment: .leading)
                    .position(x: 27, y: y + laneHeight / 2)
            }
        }
    }

    private func segment(for interval: IOSSleepInterval, size: CGSize) -> some View {
        let range = timelineRange
        let total = max(1, range.end.timeIntervalSince(range.start))
        let leftPad: CGFloat = 50
        let rightPad: CGFloat = 8
        let plotWidth = max(1, size.width - leftPad - rightPad)
        let x = leftPad + interval.start.timeIntervalSince(range.start) / total * plotWidth
        let width = max(3, interval.end.timeIntervalSince(interval.start) / total * plotWidth)
        let lane = laneIndex(interval.stage)
        let laneHeight = max(16, (size.height - 34) / 4.0)
        let y = 10 + CGFloat(lane) * laneHeight
        return RoundedRectangle(cornerRadius: 5)
            .fill(sleepStageColor(interval.stage))
            .frame(width: width, height: max(10, laneHeight - 6))
            .position(x: x + width / 2, y: y + laneHeight / 2)
    }

    private func selectedOverlay(for interval: IOSSleepInterval, size: CGSize) -> some View {
        let range = timelineRange
        let total = max(1, range.end.timeIntervalSince(range.start))
        let leftPad: CGFloat = 50
        let rightPad: CGFloat = 8
        let plotWidth = max(1, size.width - leftPad - rightPad)
        let x = leftPad + interval.start.timeIntervalSince(range.start) / total * plotWidth
        let width = max(3, interval.end.timeIntervalSince(interval.start) / total * plotWidth)
        let labelX = min(max(x + width / 2, leftPad + 58), size.width - 58)
        let minutes = max(1, Int(interval.end.timeIntervalSince(interval.start) / 60))
        return VStack(spacing: 2) {
            Text(interval.stage)
                .font(.caption2.weight(.bold))
            Text("\(minutes) min")
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(StrandPalette.hairline, lineWidth: 1) }
        .position(x: labelX, y: 22)
    }

    private var timelineRange: (start: Date, end: Date) {
        let start = intervals.map(\.start).min() ?? Date()
        let end = intervals.map(\.end).max() ?? Date().addingTimeInterval(1)
        return (start, max(end, start.addingTimeInterval(1)))
    }

    private var startLabel: String {
        timelineRange.start.formatted(date: .omitted, time: .shortened)
    }

    private var endLabel: String {
        timelineRange.end.formatted(date: .omitted, time: .shortened)
    }

    private func laneIndex(_ stage: String) -> Int {
        switch stage {
        case "Awake": return 0
        case "REM": return 1
        case "Core": return 2
        default: return 3
        }
    }

    private func selectInterval(at point: CGPoint, size: CGSize) {
        let range = timelineRange
        let total = max(1, range.end.timeIntervalSince(range.start))
        let leftPad: CGFloat = 50
        let rightPad: CGFloat = 8
        let plotWidth = max(1, size.width - leftPad - rightPad)
        guard point.x >= leftPad, point.x <= size.width - rightPad else {
            selectedInterval = nil
            return
        }
        let ts = range.start.timeIntervalSince1970 + Double((point.x - leftPad) / plotWidth) * total
        selectedInterval = intervals.first {
            ts >= $0.start.timeIntervalSince1970 && ts <= $0.end.timeIntervalSince1970
        }
    }
}

private func sleepStageColor(_ name: String) -> Color {
    switch name {
    case "Deep": return StrandPalette.sleepDeep
    case "REM": return StrandPalette.sleepREM
    case "Awake": return StrandPalette.sleepAwake
    default: return StrandPalette.sleepLight
    }
}

private struct SourceRow: View {
    let name: String
    let status: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(status).font(.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct LogPanel: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BLE LOG").font(.caption.weight(.bold)).foregroundStyle(StrandPalette.textTertiary)
            if lines.isEmpty {
                Text("No Bluetooth events yet.").font(.footnote).foregroundStyle(StrandPalette.textSecondary)
            } else {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .font(.caption.monospaced())
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10))
    }
}
