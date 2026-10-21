import SwiftUI

/// Settings pane for Swarma, the local multi-agent network whose workers and
/// project scopes get cells in the notch the way stock tickers do.
struct SwarmaSettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Swarmaa") {
                Toggle("Show Swarmaa agents and swarms", isOn: $preferences.swarmaEnabled)

                Text("One cell per worker, with its quota and the task it is on, and one per project scope, with what is running, queued and done today. The list comes from the service, so cells appear and disappear as workers do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show Swarmaa instead of stock tickers", isOn: $preferences.swarmaReplacesTickers)
                    .disabled(!preferences.swarmaEnabled)
            }

            Section("Connection") {
                LabeledContent("Service URL") {
                    TextField(Preferences.defaultSwarmaServiceURL, text: $preferences.swarmaServiceURL)
                        .textFieldStyle(.roundedBorder)
                }
                if let problem = urlProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }

                LabeledContent("Token file") {
                    TextField(Preferences.defaultSwarmaTokenPath, text: $preferences.swarmaTokenPath)
                        .textFieldStyle(.roundedBorder)
                }
                Text(tokenFileExists
                     ? L10n.t("Token file found. Its contents are only ever sent to the service URL above.")
                     : L10n.t("No file at that path yet."))
                    .font(.caption)
                    .foregroundStyle(tokenFileExists ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var tokenFileExists: Bool {
        FileManager.default.fileExists(atPath: (preferences.swarmaTokenPath as NSString).expandingTildeInPath)
    }

    /// Plain http is accepted for this Mac only; anything else must be https.
    private var urlProblem: String? {
        do {
            _ = try SwarmaClient.endpoint(preferences.swarmaServiceURL, tool: "swarm_status")
            return nil
        } catch let failure as SwarmaClient.Failure {
            return failure.message
        } catch {
            return nil
        }
    }
}
