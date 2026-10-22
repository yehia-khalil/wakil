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

    @Test func anAccountRowReads() {
        #expect(gitAccountRowText(SettingsGitAccount(host: "github.com", provider: "github", method: "ssh", user: "dev-umbrella"))
                == "github.com · SSH · dev-umbrella")
        #expect(gitAccountRowText(SettingsGitAccount(host: "bitbucket.org", provider: "bitbucket", method: "token"))
                == "bitbucket.org · Token")
        #expect(gitAccountRowText(SettingsGitAccount(host: "gitlab.com", provider: "gitlab", method: "signin", user: "u"))
                == "gitlab.com · Signed in · u")
    }

    @Test func thePullStrategyIsAnOrganisationField() {
        #expect(WindowModel.OrganisationField.pullStrategy.rawValue == "pullStrategy")
    }

    @Test func theTreeCarriesTheLastCloneFolder() throws {
        let json = #"{"id":"o","lastCloneFolder":"/c"}"#
        let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(json.utf8))
        #expect(org.lastCloneFolder == "/c")
    }
}
