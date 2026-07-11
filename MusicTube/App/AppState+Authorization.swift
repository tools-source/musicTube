import Foundation

@MainActor
extension AppState {
    func applyAuthorizedSession(_ session: YouTubeSession) {
        self.session = session
        user = session.user
        authState = .signedIn
        logger.debug("Applied authorized session for user \(session.user.email)")
    }

    func clearAuthorizationState() {
        session = nil
        user = nil
        authState = .guest
        clearRemoteState()
        syncLocalMusicProfileState()
        errorMessage = nil
        logger.info("Cleared authorized session state")
    }

    func authorizedSessionIfAvailable(forceRefresh: Bool = false) async -> YouTubeSession? {
        guard session != nil else { return nil }

        if forceRefresh == false, let session, session.isExpired == false {
            return session
        }

        logger.debug(forceRefresh ? "Refreshing authorized session" : "Restoring authorized session")
        let refreshedSession = await authService.refreshSession()

        guard let refreshedSession else {
            logger.info("Authorized session refresh did not produce a usable session")
            return nil
        }

        applyAuthorizedSession(refreshedSession)
        return refreshedSession
    }

    func authorizedAccessTokenIfAvailable(forceRefresh: Bool = false) async -> String? {
        await authorizedSessionIfAvailable(forceRefresh: forceRefresh)?.accessToken
    }

    func performAuthenticatedOperation<T>(
        _ operation: (String) async throws -> T
    ) async throws -> T? {
        guard let accessToken = await authorizedAccessTokenIfAvailable() else {
            return nil
        }

        do {
            return try await operation(accessToken)
        } catch {
            guard isAuthorizationError(error) else {
                throw error
            }

            guard let refreshedAccessToken = await authorizedAccessTokenIfAvailable(forceRefresh: true) else {
                _ = await handleAuthorizationFailureIfNeeded(for: error)
                throw error
            }

            do {
                return try await operation(refreshedAccessToken)
            } catch {
                if isAuthorizationError(error) {
                    _ = await handleAuthorizationFailureIfNeeded(for: error)
                }
                throw error
            }
        }
    }

    func handleAuthorizationFailureIfNeeded(for error: Error) async -> Bool {
        guard isAuthorizationError(error) else { return false }

        logger.error("Authorization failure detected; signing out to recover cleanly", error: error)
        await authService.signOut()
        clearAuthorizationState()
        return true
    }

}
