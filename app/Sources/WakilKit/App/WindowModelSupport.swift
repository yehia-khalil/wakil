import Foundation

/// The surface calls the chain starts and does not await (9a, W14): the two sends.
public func apiSurfaceCallDetaches(_ name: String) -> Bool {
    name == "api_request" || name == "api_send"
}
