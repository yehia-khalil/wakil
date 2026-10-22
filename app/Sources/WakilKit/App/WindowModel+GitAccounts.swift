import Foundation

/// A key pair in ~/.ssh, as the Add-account sheet lists it (3a-iii).
public struct GitSSHKey: Sendable, Equatable, Identifiable {
    public var path: String
    public var comment: String
    public var type: String
    public var encrypted: Bool
    public var id: String { path }
}

/// Settings → Organisation → Git's accounts (3a-iii, Decision 44): every call is an operator-only
/// `ctx_git_*` dispatch for the active organisation, and Settings is read again after a write.
/// Each answers its refusal's own sentence, whole (Rule 8).
extension WindowModel {
    func gitAccountCall(_ name: String, _ params: [String: JSONValue]) async -> (JSONValue?, String?) {
        var p = params
        p["id"] = .string(organization)
        do {
            let reply = try await registry.dispatch(name: name, params: .object(p), origin: .ui,
                                                    caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            return (reply, nil)
        } catch {
            return (nil, statusDescribingFailure(name, error))
        }
    }

    private static func field(_ v: JSONValue?, _ key: String) -> String? {
        if case .object(let o)? = v, case .string(let s)? = o[key] { return s }
        return nil
    }

    public func gitHostSuggestions() async -> [(host: String, repositories: Int)] {
        let (reply, _) = await gitAccountCall("ctx_git_host_suggestions", [:])
        guard case .object(let o)? = reply, case .array(let rows)? = o["hosts"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let r) = row, case .string(let h)? = r["host"] else { return nil }
            return (h, r["repositories"]?.intValue ?? 0)
        }
    }

    public func gitSSHKeys() async -> [GitSSHKey] {
        let (reply, _) = await gitAccountCall("ctx_git_ssh_keys", [:])
        guard case .object(let o)? = reply, case .array(let rows)? = o["keys"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let r) = row, case .string(let path)? = r["path"] else { return nil }
            return GitSSHKey(path: path, comment: Self.field(row, "comment") ?? "", type: Self.field(row, "type") ?? "",
                             encrypted: r["encrypted"] == .bool(true))
        }
    }

    public func addGitAccount(host: String, provider: GitProvider, method: GitAccountMethod, user: String = "",
                              keyPath: String = "", username: String = "") async -> String? {
        var p: [String: JSONValue] = ["host": .string(host), "provider": .string(provider.rawValue), "method": .string(method.rawValue)]
        for (k, v) in [("user", user), ("keyPath", keyPath), ("username", username)] where !v.isEmpty { p[k] = .string(v) }
        let (_, error) = await gitAccountCall("ctx_git_account_add", p)
        await refreshSettings()
        return error
    }

    public func removeGitAccount(host: String) async -> String? {
        let (_, error) = await gitAccountCall("ctx_git_account_remove", ["host": .string(host)])
        await refreshSettings()
        return error
    }

    public func generateGitKey(host: String, comment: String) async -> (publicKey: String?, path: String?, error: String?) {
        let (reply, error) = await gitAccountCall("ctx_git_key_generate", ["host": .string(host), "comment": .string(comment)])
        return (Self.field(reply, "publicKey"), Self.field(reply, "path"), error)
    }

    public func setGitToken(host: String, token: String) async -> String? {
        await gitAccountCall("ctx_git_token_set", ["host": .string(host), "token": .string(token)]).1
    }

    public func setGitKeyPassphrase(host: String, passphrase: String) async -> String? {
        await gitAccountCall("ctx_git_key_passphrase_set", ["host": .string(host), "passphrase": .string(passphrase)]).1
    }

    /// Asks the host who the account is and, on an answer, records the name on the account's row.
    public func testGitAccount(host: String) async -> (user: String?, error: String?) {
        let (reply, error) = await gitAccountCall("ctx_git_account_test", ["host": .string(host)])
        if let error { return (nil, error) }
        let user = Self.field(reply, "user") ?? ""
        if !user.isEmpty, let a = settings?.org.gitAccounts.first(where: { $0.host == host }) {
            _ = await addGitAccount(host: host, provider: GitProvider(rawValue: a.provider) ?? .other,
                                    method: GitAccountMethod(rawValue: a.method) ?? .ssh, user: user,
                                    keyPath: a.keyPath, username: a.username)
        }
        return (user, nil)
    }

    /// Sign in (device flow): the code to type and the page; then one poll per call until approved.
    public func gitDeviceStart(provider: GitProvider) async -> (userCode: String?, page: String?, deviceCode: String?, interval: Int, error: String?) {
        let (reply, error) = await gitAccountCall("ctx_git_device_start", ["provider": .string(provider.rawValue)])
        let interval: Int = { if case .object(let o)? = reply { return o["interval"]?.intValue ?? 5 }; return 5 }()
        return (Self.field(reply, "userCode"), Self.field(reply, "verificationUri"), Self.field(reply, "deviceCode"), max(interval, 1), error)
    }

    public func gitDevicePoll(provider: GitProvider, host: String, deviceCode: String) async -> (pending: Bool, error: String?) {
        let (reply, error) = await gitAccountCall("ctx_git_device_poll", ["provider": .string(provider.rawValue), "host": .string(host),
                                                                         "deviceCode": .string(deviceCode)])
        if let error { return (false, error) }
        if case .object(let o)? = reply, o["done"] == .bool(true) { await refreshSettings() }
        if case .object(let o)? = reply { return (o["pending"] == .bool(true), nil) }
        return (false, nil)
    }

    public func gitGhLogins() async -> [(host: String, user: String)] {
        let (reply, _) = await gitAccountCall("ctx_git_gh_logins", [:])
        guard case .object(let o)? = reply, case .array(let rows)? = o["logins"] else { return [] }
        return rows.compactMap { row in
            guard let h = Self.field(row, "host"), let u = Self.field(row, "user") else { return nil }
            return (h, u)
        }
    }

    public func gitGhImport(host: String, user: String) async -> String? {
        let (_, error) = await gitAccountCall("ctx_git_gh_import", ["host": .string(host), "user": .string(user)])
        await refreshSettings()
        return error
    }
}
