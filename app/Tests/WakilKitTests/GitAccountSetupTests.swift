import Foundation
import Testing
@testable import WakilKit

@Suite struct GitAccountSetupTests {
    @Test func eachProviderOffersOnlyWhatItSupports() {
        #expect(gitAccountMethods(provider: .github, signInAvailable: false) == [.ssh, .token])
        #expect(gitAccountMethods(provider: .github, signInAvailable: true) == [.signin, .ssh, .token])
        #expect(gitAccountMethods(provider: .gitlab, signInAvailable: true) == [.signin, .ssh, .token])
        #expect(gitAccountMethods(provider: .bitbucket, signInAvailable: true) == [.ssh, .token])
        #expect(gitAccountMethods(provider: .other, signInAvailable: true) == [.ssh, .token])
    }

    @Test func aHostNamesItsProvider() {
        #expect(GitProvider(host: "github.com") == .github)
        #expect(GitProvider(host: "gitlab.com") == .gitlab)
        #expect(GitProvider(host: "bitbucket.org") == .bitbucket)
        #expect(GitProvider(host: "git.example.com") == .other)
    }

    @Test func thePagesToOpen() {
        #expect(GitProvider.github.sshKeyPage?.absoluteString == "https://github.com/settings/ssh/new")
        #expect(GitProvider.gitlab.sshKeyPage?.absoluteString == "https://gitlab.com/-/user_settings/ssh_keys")
        #expect(GitProvider.bitbucket.sshKeyPage?.absoluteString == "https://bitbucket.org/account/settings/ssh-keys/")
        #expect(GitProvider.other.sshKeyPage == nil)
        #expect(GitProvider.github.tokenPage?.absoluteString == "https://github.com/settings/tokens/new?scopes=repo")
        #expect(GitProvider.bitbucket.tokenPage?.absoluteString == "https://bitbucket.org/account/settings/api-tokens/")
    }

    @Test func thePullStrategyIsAnOrganisationField() {
        #expect(WindowModel.OrganisationField.pullStrategy.rawValue == "pullStrategy")
    }

    @Test func theTreeCarriesTheLastCloneFolder() throws {
        let json = #"{"id":"o","lastCloneFolder":"/c"}"#
        let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(json.utf8))
        #expect(org.lastCloneFolder == "/c")
    }

    // 3a-iii walk redesign: one account per host, so a connected provider is shown as taken.
    @Test func aConnectedProviderIsTaken() {
        let accounts = [SettingsGitAccount(host: "github.com", provider: "github", method: "ssh", user: "octo")]
        #expect(gitAccountTaken(provider: .github, accounts: accounts)?.user == "octo")
        #expect(gitAccountTaken(provider: .gitlab, accounts: accounts) == nil)
        #expect(gitAccountTaken(provider: .other, accounts: accounts) == nil)
    }

    @Test func eachMethodSaysWhatItMeans() {
        #expect(GitAccountMethod.ssh.summary(provider: .github)
                == "Wakil makes a key for this organisation only; you add it to GitHub once")
        #expect(GitAccountMethod.token.summary(provider: .github)
                == "Paste a personal access token that can repo")
        #expect(GitAccountMethod.signin.summary(provider: .gitlab)
                == "Approve Wakil in your browser; nothing to copy")
        #expect(GitAccountMethod.ssh.summary(provider: .other)
                == "Wakil makes a key for this organisation only; you add it to the host once")
    }

    @Test func anAccountCardNamesTheProviderTheUserAndTheMethod() {
        let card = gitAccountCard(SettingsGitAccount(host: "github.com", provider: "github", method: "ssh", user: "octo"))
        #expect(card == GitAccountCard(title: "GitHub", host: "github.com", user: "octo", method: "SSH key"))
        let other = gitAccountCard(SettingsGitAccount(host: "git.initech.example", provider: "other", method: "token"))
        #expect(other == GitAccountCard(title: "git.initech.example", host: "", user: "Not tested yet", method: "Token"))
    }

    @Test func aKeyTheHostDoesNotKnowYetSaysWhatToDo() {
        #expect(gitTestFailureText("git@github.com: Permission denied (publickey).", provider: .github)
                == "GitHub didn't accept the key yet. Add it on GitHub, then test again")
        #expect(gitTestFailureText("ssh: connect to host x port 22: Operation timed out", provider: .other)
                == "ssh: connect to host x port 22: Operation timed out")
    }
}

