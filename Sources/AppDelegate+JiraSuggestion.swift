import AppKit

extension AppDelegate {
    /// One-time prompt offering to install the Jira CLI when the user has
    /// any Jira identity present but no `jira` binary. Once dismissed with
    /// "Don't Ask Again" we never prompt again. Skipped silently if jira is
    /// already on the path or no Jira identity is configured.
    func suggestJiraCLIIfNeeded() {
        guard !JiraTicketDetector.isJiraCLIAvailable else { return }
        guard !UserDefaults.standard.bool(forKey: "jiraCLISuggestionSkipped") else { return }
        guard JiraTicketDetector.isJiraAvailable else { return }

        let alert = NSAlert()
        alert.messageText = "Install Jira CLI?"
        alert.informativeText = "The Jira CLI (go-jira) lets claude-terminal show ticket titles in the sidebar when your branch includes a Jira key.\n\nInstall with: brew install go-jira"
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Don't Ask Again")
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            UserDefaults.standard.set(true, forKey: "jiraCLISuggestionSkipped")
        }
    }
}
