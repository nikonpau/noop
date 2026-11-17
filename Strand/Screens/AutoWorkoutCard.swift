import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Auto-detected workout prompt (Today screen)
//
// A single Today card driven by "Auto-detect workouts" (default ON) when
// `Repository.autoDetectCandidate()` finds a recent sustained-elevated HR window that isn't
// already saved and wasn't previously dismissed.
//
// Automatic mode (default, "Save detected workouts automatically"): the window is saved right
// away with a guessed sport, and the card just confirms it with a one-tap "Not a workout" undo.
// Suggest mode (switch off): the card asks, Save creates the manual-style workout, X dismisses it
// durably. Design-Reset compliant — a flat NoopCard using NoopMetrics / StrandPalette /
// StrandFont, no gold, matching the other Today cards.

struct AutoWorkoutCard: View {

    @EnvironmentObject var repo: Repository

    /// Whether the toggle is on. Read here too so the card disappears the instant it's switched off.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectEnabled = true

    /// Whether a detected window is saved without asking. OFF falls back to the tap-to-save card.
    @AppStorage(PuffinExperiment.autoSaveDetectedWorkoutsKey) private var autoSaveEnabled = true

    /// The workout saved automatically this session, kept so the confirmation card can undo it.
    @State private var autoSaved: AutoSavedWorkout?

    /// The current suggestion, loaded in `.task`. nil → nothing to show.
    @State private var candidate: DetectedWorkout?
    /// Hide immediately on Save/X without waiting for the next reload (avoids a flash of the old card).
    @State private var handledThisSession = false
    /// Guards the Save button while the write is in flight.
    @State private var saving = false

    var body: some View {
        Group {
            if autoDetectEnabled, !handledThisSession, let w = candidate {
                card(for: w)
            } else if autoDetectEnabled, let saved = autoSaved {
                savedCard(for: saved)
            }
        }
        // Re-scan whenever the data refreshes (a sync bumps refreshSeq) or the toggle flips on.
        .task(id: AutoWorkoutLoadKey(seq: repo.refreshSeq, enabled: autoDetectEnabled)) {
            await reload()
        }
    }

    @ViewBuilder
    private func card(for w: DetectedWorkout) -> some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Looks like a workout")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button {
                        dismiss(w)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(NoopMetrics.space1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss this workout suggestion")
                }

                Text(promptText(w))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: NoopMetrics.space3) {
                    Button {
                        save(w)
                    } label: {
                        Label("Save it", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(saving)

                    Button("Not a workout") { dismiss(w) }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Confirmation after an automatic save: sport, duration, avg HR, with a one-tap undo.
    @ViewBuilder
    private func savedCard(for s: AutoSavedWorkout) -> some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Workout saved automatically")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button {
                        autoSaved = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(NoopMetrics.space1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide this message")
                }

                Text("\(WorkoutSource.displaySport(s.row.sport)), \(s.window.durationMin) min (avg HR \(s.window.avgBpm))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: NoopMetrics.space3) {
                    Button("Not a workout") { undo(s) }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "Looks like a workout [yesterday ]around 14:05–14:32 (avg HR 148, 27 min). Save it?"
    /// Three whole-phrase variants (today / yesterday / dated, #719) so translators see complete
    /// sentences rather than a stitched day-label fragment.
    private func promptText(_ w: DetectedWorkout) -> String {
        let startDate = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        let start = Self.timeFmt.string(from: startDate)
        let end = Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(w.endSec)))
        let cal = Calendar.current
        if cal.isDateInToday(startDate) {
            return String(localized: "Looks like a workout around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
        }
        if cal.isDateInYesterday(startDate) {
            return String(localized: "Looks like a workout yesterday around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
        }
        return String(localized: "Looks like a workout on \(Self.dateFmt.string(from: startDate)) around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
    }

    private func reload() async {
        guard autoDetectEnabled else { candidate = nil; return }
        let next = await repo.autoDetectCandidate()
        if autoSaveEnabled, let w = next {
            autoSave(w)
            return
        }
        // A fresh scan resets the session guard so a NEW window can surface after one is handled.
        if next != candidate { handledThisSession = false }
        candidate = next
    }

    /// Save with no tap. Runs in its own Task so the refresh it triggers (which bumps `refreshSeq` and
    /// cancels the `.task` that called us) can't cut the write short; `saving` blocks a second scan
    /// from writing the same window twice.
    private func autoSave(_ w: DetectedWorkout) {
        guard !saving else { return }
        saving = true
        Task {
            if let row = await repo.autoSaveDetectedWorkout(w) {
                autoSaved = AutoSavedWorkout(row: row, window: w)
                await repo.refresh()
            }
            saving = false
        }
    }

    /// Undo an automatic save: remember the window as dismissed (so it is never re-detected), then
    /// delete the row.
    private func undo(_ s: AutoSavedWorkout) {
        saving = true
        Task {
            repo.dismissDetectedSuggestion(s.window)
            await repo.deleteWorkout(s.row)
            autoSaved = nil
            await repo.refresh()
            saving = false
        }
    }

    private func save(_ w: DetectedWorkout) {
        saving = true
        handledThisSession = true
        Task {
            _ = await repo.saveDetectedWorkout(w)
            await repo.refresh()   // surfaces the new workout + drops it from re-suggestion
            saving = false
        }
    }

    private func dismiss(_ w: DetectedWorkout) {
        repo.dismissDetectedSuggestion(w)
        handledThisSession = true
        candidate = nil
    }

    /// HH:mm in the user's locale/timezone.
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var timeFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    /// Localized medium date ("Jun 23, 2026") for a bout older than yesterday.
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Reload key: a new sync (seq) or a toggle flip re-runs detection.
private struct AutoWorkoutLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
}

/// The workout the card saved on its own, plus the detector window it came from (needed to undo).
private struct AutoSavedWorkout: Equatable {
    let row: WorkoutRow
    let window: DetectedWorkout
}
