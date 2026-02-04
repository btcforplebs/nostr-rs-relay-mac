import Foundation

/// A service to handle client-side spam filtering for the UI
class SpamFilterService {
    
    /// Checks if a Nostr event should be filtered based on the current configuration
    /// - Parameters:
    ///   - event: The event to check
    ///   - config: The relay configuration containing filter settings
    /// - Returns: True if the event is spam and should be filtered, false otherwise
    static func shouldFilter(event: NostrEvent, config: RelayConfig) -> Bool {
        // If the global spam filter toggle is off, don't filter anything in the UI
        guard config.spamFilterEnabled else {
            return false
        }
        
        // 1. Check Blocked Pubkeys
        // We use a set for O(1) lookup in case the list gets long
        let blockedPubkeys = Set(config.blockedPubkeys)
        if blockedPubkeys.contains(event.pubkey) {
            return true
        }
        
        // 2. Check Blocked Keywords
        // We check if any of the blocked keywords appear in the event content
        for keyword in config.blockedKeywords {
            // Using localizedCaseInsensitiveContains for a more robust check (matches "SPAM" and "spam")
            if event.content.localizedCaseInsensitiveContains(keyword) {
                return true
            }
        }
        
        // 3. Other potential filters (e.g. kind-based) could be added here
        
        return false
    }
}
