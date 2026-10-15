import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct CompanionWidgets: WidgetBundle {
    var body: some Widget {
        AlarmLiveActivity()
    }
}

/// The Live Activity that AlarmKit shows for a running timer.
struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<CompanionAlarmMetadata>.self) { context in
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(context.attributes))
                        .font(.headline)
                    Countdown(state: context.state)
                        .font(.largeTitle.monospacedDigit())
                }
                Spacer()
                Button(intent: StopAlarmIntent(alarmID: context.state.alarmID)) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Stop")
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(title(context.attributes))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: context.state).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button("Stop", intent: StopAlarmIntent(alarmID: context.state.alarmID))
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                Countdown(state: context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }

    private func title(_ attributes: AlarmAttributes<CompanionAlarmMetadata>) -> String {
        attributes.metadata?.title ?? "Timer"
    }
}

private struct Countdown: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now ... countdown.fireDate, countsDown: true)
        case .paused(let paused):
            let remaining = max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)
            Text(Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)))
        case .alert:
            Text("Now")
        @unknown default:
            Text("")
        }
    }
}
