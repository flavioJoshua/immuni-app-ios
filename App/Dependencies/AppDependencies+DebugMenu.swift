// AppDependencies+DebugMenu.swift
// Copyright (C) 2020 Presidenza del Consiglio dei Ministri.
// Please refer to the AUTHORS file for more information.
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

#if canImport(DebugMenu)
  import DebugMenu
  import ExposureNotification
  import Extensions
  import Foundation
  import Hydra
  import ImmuniExposureNotification
  import Katana
  import Models
  import PushNotification
  import Tempura

  extension AppDependencies: DebugMenuConfigurationProvider {
    var getState: () -> State { self.getAppState }

    func items(state: State) -> [DebugMenuItem] {
      let isForceUpdateToggled = self.getAppState().toggles.mustShowForceUpdate
      let isDebugNotificationToggled = self.getAppState().toggles.isPushNotificationDebugMode
      let isBackgroundTaskNotificationToggled = self.getAppState().toggles.isBackgroundTaskDebugMode

      var items: [DebugMenuItem] = [
        .init(
          title: "🔎 State Explorer",
          dispatchable: DebugMenuActions.ShowStateExplorer()
        ),
        .init(
          title: "🔓 Reset Keychain",
          dispatchable: DebugMenuActions.ResetKeychain()
        ),
        .init(
          title: "💥 Clean App",
          dispatchable: DebugMenuActions.CleanApp(bundle: self.bundle, fileManager: .default)
        ),
        .init(
          title: "⛔️ Simulate Force Update \(isForceUpdateToggled ? "not necessary" : "necessary")",
          dispatchable: ToggleForceUpdateNecessaryAndCrash()
        ),
        .init(
          title: "📧 Send App Force Update notification in 5 sec",
          dispatchable: SimulateAppForceUpdateNotification()
        ),
        .init(
          title: "🔔 Show Scheduled Notifications",
          dispatchable: ShowScheduledNotifications()
        ),
        .init(
          title: "🔔 \(isDebugNotificationToggled ? "Disable" : "Enable") Debug Notifications",
          dispatchable: ToggleDebugNotification()
        )
      ]

      if #available(iOS 13.5, *) {
        items.append(contentsOf: [
          .init(
            title: "🔑 Show TEKs",
            dispatchable: ShowDiagnosisKeys()
          ),
          .init(
            title: "🔬 Perform exposure detection",
            dispatchable: PerformExposureDetection()
          ),
          .init(
            title: "📌 Show past exposure detections",
            dispatchable: ShowPastExposureDetections()
          ),
          .init(
            title: "📫 \(isBackgroundTaskNotificationToggled ? "Deactivate" : "Activate") background task notification",
            dispatchable: ToggleBackgroundTaskDebugMode()
          )
        ])
      }

      // COVID status helpers
      let now = Date().calendarDay

      items.append(contentsOf: [
        .init(
          title: "🎮 [Status] Simulate Contact (RISK)",
          dispatchable: Logic.CovidStatus.UpdateStatusWithEvent(event: .contactDetected(date: now))
        ),

        .init(
          title: "🎮 [Status] Simulate Data Upload",
          dispatchable: Logic.CovidStatus.UpdateStatusWithEvent(event: .dataUpload(currentDate: now))
        ),

        .init(
          title: "🎮 [Status] Simulate Alert Dismissal",
          dispatchable: Logic.CovidStatus.UpdateStatusWithEvent(event: .userEvent(.alertDismissal))
        ),

        .init(
          title: "🎮 [Status] Simulate Recover Confirmed",
          dispatchable: Logic.CovidStatus.UpdateStatusWithEvent(event: .userEvent(.recoverConfirmed))
        )
      ])

      // analytics
      items.append(contentsOf: [
        .init(
          title: "[Analytics] Trigger send without exposure logic",
          dispatchable: Logic.Analytics.SendOperationalInfoWithoutExposureIfNeeded()
        ),

        .init(
          title: "[Analytics] Trigger send with exposure logic",
          dispatchable: Logic.Analytics.SendOperationalInfoWithExposureIfNeeded()
        )
      ])

      return items
    }
  }

  /// Shows the ForceUpdate screens
  private struct ToggleForceUpdateNecessaryAndCrash: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      try context.awaitDispatch(ToggleForceUpdateNecessary())
      Thread.sleep(forTimeInterval: 1) // give KatanaPersistence time to do its thing
      AppLogger.fatalError("Restart app")
    }
  }

  /// Simulates the need for a force update
  private struct ToggleForceUpdateNecessary: AppStateUpdater {
    func updateState(_ state: inout AppState) {
      state.toggles.mustShowForceUpdate.toggle()
    }
  }

  /// Simulates the notification for a force update after 5 seconds
  private struct SimulateAppForceUpdateNotification: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      // send immediately a notification
      context.dependencies.pushNotification.scheduleLocalNotification(
        LocalNotificationContent(
          title: L10n.Notifications.UpdateApp.title,
          body: L10n.Notifications.UpdateApp.description,
          userInfo: [:],
          identifier: Logic.ForceUpdate.requiredUpdateAppNotificationID
        ),
        with: LocalNotificationTrigger.timeInterval(5)
      )
    }
  }

  /// Shows the list of scheduled notifications
  private struct ShowScheduledNotifications: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let scheduled = try await(context.dependencies.pushNotification.scheduledLocalNotificationsIds())
      let scheduledMessage = scheduled.map { "- \($0)" }.joined(separator: "\n\n")

      let message = """
      Scheduled:
      \(scheduledMessage)
      """

      context.dispatch(
        Logic.Alert.Show(
          alertModel: .init(
            title: "Scheduled Notifications",
            message: message,
            preferredStyle: .alert,
            actions: [
              .init(title: "Ok", style: .default)
            ]
          )
        )
      )
    }
  }

  /// Toggles the debug mode for push notifications
  private struct ToggleDebugNotification: AppStateUpdater {
    func updateState(_ state: inout AppState) {
      state.toggles.isPushNotificationDebugMode.toggle()
    }
  }

  // MARK: - Exposure Notification

  @available(iOS 13.5, *)
  /// Shows the TEKs for the user, including today's.
  private struct ShowDiagnosisKeys: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      try await(context.dependencies.exposureNotificationManager.askAuthorizationAndStart())

      let resultTitle: String
      let resultMessage: String
      do {
        let keys = try await(context.dependencies.exposureNotificationManager.getDiagnosisKeys())

        resultTitle = "Success"
        resultMessage = "Count: \(keys.count)\n\(keys.map { $0.debugDescription }.joined(separator: ",\n"))"
      } catch {
        resultTitle = "Error"
        resultMessage = String(reflecting: error)
      }

      context.dispatch(DebugMenuActions.ShowAlert(
        model: .init(
          title: resultTitle,
          message: resultMessage,
          actions: [.init(title: "Ok")]
        )
      ))
    }
  }

  @available(iOS 13.5, *)
  /// Forcefully performs a check of Exposure Detection
  private struct PerformExposureDetection: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      try context.awaitDispatch(Show(Screen.loading, animated: true, context: LoadingLS(message: "Loading")))

      let resultTitle: String
      let resultMessage: String

      do {
        try await(context.dependencies.exposureNotificationManager.askAuthorizationAndStart())
        try context.awaitDispatch(Logic.Configuration.DownloadAndUpdateConfiguration())
        try context.awaitDispatch(Logic.ExposureDetection.PerformExposureDetectionIfNecessary(type: .foreground, forceRun: true))

        let result = context.getState().exposureDetection.previousDetectionResults.last
          ?? AppLogger.fatalError("No result recorded")

        resultTitle = "Completed"
        resultMessage = "Exposure Detection result:\n\(result)"
      } catch {
        resultTitle = "Error"
        resultMessage = String(reflecting: error)
      }

      try context.awaitDispatch(Hide(Screen.loading, animated: true))

      context.dispatch(DebugMenuActions.ShowAlert(
        model: .init(
          title: resultTitle,
          message: resultMessage,
          actions: [.init(title: "Ok")]
        )
      ))
    }
  }

  @available(iOS 13.5, *)
  /// Shows the list of past exposure detections
  private struct ShowPastExposureDetections: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let state = context.getState()

      let formattedLastDetectionDate = state.exposureDetection.lastDetectionDate
        .map { "at \(DateFormatter.default.string(from: $0))" } ?? "never"

      let message = """
      Last detection: \(formattedLastDetectionDate).
      All results: \(state.exposureDetection.previousDetectionResults.map { $0.description }.joined(separator: ",\n")))
      """

      context.dispatch(DebugMenuActions.ShowAlert(
        model: .init(
          title: "Result",
          message: message,
          actions: [.init(title: "Ok")]
        )
      ))
    }
  }

  /// Toggles the debug mode for background tasks.
  private struct ToggleBackgroundTaskDebugMode: AppStateUpdater {
    func updateState(_ state: inout AppState) {
      state.toggles.isBackgroundTaskDebugMode.toggle()
    }
  }

  // MARK: - Debug Print helpers

  private extension DateFormatter {
    static let `default`: DateFormatter = {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd@HH:mm"
      return formatter
    }()
  }

  private extension TemporaryExposureKey {
    var debugDescription: String {
      let startDate = Date(timeIntervalSince1970: Double(self.rollingStartNumber) * 600)
      let endDate = startDate.addingTimeInterval(TimeInterval(self.rollingPeriod * 600))
      return
        // swiftlint:disable:next line_length
        "<Start: \(DateFormatter.default.string(from: startDate)), End: \(DateFormatter.default.string(from: endDate)), Key: \(self.keyData.base64EncodedString())>"
    }
  }

  private extension ExposureDetectionSummaryData {
    var debugDescription: String {
      return [
        "Count: \(self.matchedKeyCount)",
        "LastExposure: \(self.daysSinceLastExposure) days ago",
        "Durations: \(self.durationByAttenuationBucket[0]) <= 50, \(self.durationByAttenuationBucket[1]) > 50",
        "MaxRisk: \(self.maximumRiskScore)"
      ].joined(separator: ", ")
    }
  }

  private extension ExposureDetectionSummary {
    var debugDescription: String {
      switch self {
      case .noMatch:
        return "none"
      case .matches(let data):
        return data.debugDescription
      }
    }
  }

  private extension ExposureInfo {
    var debugDescription: String {
      return [
        "Date: \(DateFormatter.default.string(from: self.date))",
        "Duration: \(self.duration / 60)min",
        "Attenuation: \(self.attenuationValue)",
        "Risk: \(self.transmissionRisk)",
        "Score: \(self.totalRiskScore)"
      ].joined(separator: ", ")
    }
  }
#endif
