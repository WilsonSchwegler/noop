import SwiftUI

struct WatchWorkoutView: View {
    @EnvironmentObject private var manager: WatchWorkoutManager

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if manager.isRunning {
                        liveWorkout
                    } else {
                        workoutPicker
                    }
                    Text(manager.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            .navigationTitle("WarbFit")
            .task {
                manager.requestAuthorization()
            }
        }
    }

    private var workoutPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start Workout")
                .font(.headline)
            ForEach(WatchWorkoutOption.all, id: \.id) { (option: WatchWorkoutOption) in
                if option.id == "strength" {
                    NavigationLink {
                        StrengthPlanPickerView()
                            .environmentObject(manager)
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                } else if option.id == "swim" {
                    NavigationLink {
                        SwimPlanPickerView()
                            .environmentObject(manager)
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                } else {
                    Button {
                        manager.select(option)
                        manager.start()
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                }
            }
        }
    }

    private var liveWorkout: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(manager.selectedWorkout.title)
                .font(.headline)
            Text(elapsedText)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack {
                metric("HR", manager.heartRate.map { "\(Int($0.rounded()))" } ?? "--", "bpm")
                metric("Energy", "\(Int(manager.activeEnergyKcal.rounded()))", "kcal")
            }
            if showsDistance {
                metric("Distance", String(format: "%.2f", manager.distanceMeters / 1609.344), "mi")
            }
            if manager.selectedWorkout.id == "treadmill" {
                labeledEntry(
                    title: "Distance",
                    unit: "mi",
                    text: Binding(
                        get: { manager.treadmillDistanceMiles },
                        set: { manager.updateTreadmillDistanceMiles($0) }
                    )
                )
            }
            if manager.selectedWorkout.id == "stairmaster" {
                labeledEntry(
                    title: "Flights",
                    unit: "",
                    text: Binding(
                        get: { manager.stairFlights },
                        set: { manager.updateStairFlights($0) }
                    )
                )
            }
            if manager.selectedWorkout.id == "strength" {
                strengthLog
            }
            if manager.selectedWorkout.id == "swim" {
                swimPlan
            }
            HStack {
                Button(manager.isPaused ? "Resume" : "Pause") {
                    manager.togglePause()
                }
                .tint(.orange)
                Button("End") {
                    manager.end()
                }
                .tint(.red)
            }
        }
    }

    private var swimPlan: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = manager.selectedSwimPlan {
                Text(plan.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(plan.items, id: \.id) { (item: WatchSwimPlanItem) in
                    HStack {
                        Text(item.stroke.isEmpty ? "Swim" : item.stroke)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(item.sets)x \(item.distance)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Swim distance records from Apple Watch during the workout.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var strengthLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = manager.selectedStrengthPlan {
                Text(plan.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(plan.exercises, id: \.id) { (exercise: WatchStrengthExercise) in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(exercise.name) \(exercise.sets)x\(exercise.reps)")
                            .font(.caption.weight(.semibold))
                        ForEach(0..<Swift.max(1, exercise.sets), id: \.self) { (setOffset: Int) in
                            HStack {
                                Text("Set \(setOffset + 1)")
                                    .font(.caption2)
                                TextField("lb", text: weightBinding(exerciseId: exercise.id, setIndex: setOffset + 1))
                            }
                        }
                    }
                }
            } else {
                Text("Log weights on the phone app or start with a synced plan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledEntry(title: String, unit: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                TextField(unit.isEmpty ? title : unit, text: text)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var elapsedText: String {
        let seconds = max(0, Int(manager.elapsedSeconds))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var showsDistance: Bool {
        ["run", "hiking", "treadmill", "swim"].contains(manager.selectedWorkout.id)
    }

    private func weightBinding(exerciseId: String, setIndex: Int) -> Binding<String> {
        Binding {
            manager.strengthSetLogs.first { $0.exerciseId == exerciseId && $0.setIndex == setIndex }?.weight ?? ""
        } set: { value in
            manager.updateWeight(exerciseId: exerciseId, setIndex: setIndex, weight: value)
        }
    }
}

private struct StrengthPlanPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var manager: WatchWorkoutManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    startStrength(plan: nil)
                } label: {
                    Label("Start Without Plan", systemImage: "dumbbell.fill")
                }
                if manager.strengthPlans.isEmpty {
                    Text("Plans sync from the phone app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.strengthPlans, id: \.id) { (plan: WatchStrengthPlan) in
                        Button {
                            startStrength(plan: plan)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.name)
                                    .font(.headline)
                                Text("\(plan.exercises.count) exercises")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Strength")
    }

    private func startStrength(plan: WatchStrengthPlan?) {
        manager.startStrength(plan: plan)
        dismiss()
    }
}

private struct SwimPlanPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var manager: WatchWorkoutManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    startSwim(plan: nil)
                } label: {
                    Label("Start Without Plan", systemImage: "figure.pool.swim")
                }
                if manager.swimPlans.isEmpty {
                    Text("Plans sync from the phone app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.swimPlans, id: \.id) { (plan: WatchSwimPlan) in
                        Button {
                            startSwim(plan: plan)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.name)
                                    .font(.headline)
                                Text("\(plan.items.count) sets")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Swim")
    }

    private func startSwim(plan: WatchSwimPlan?) {
        manager.startSwim(plan: plan)
        dismiss()
    }
}
