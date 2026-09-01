use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

/// Cache for detecting duplicate messages from the same pubkey within a time window.
pub struct DedupCache {
    /// Maps (pubkey_content_hash) -> Timestamp
    cache: Mutex<HashMap<u64, Instant>>,
    window: Duration,
}

impl DedupCache {
    pub fn new(window: Duration) -> Self {
        Self {
            cache: Mutex::new(HashMap::new()),
            window,
        }
    }

    /// Checks if a message (pubkey + content) is a duplicate within the window.
    /// Returns true if it is a duplicate (should be rejected).
    /// If not a duplicate, adds it to the cache and returns false.
    pub fn check_and_add(&self, pubkey: &str, content: &str) -> bool {
        let mut hasher = DefaultHasher::new();
        pubkey.hash(&mut hasher);
        content.hash(&mut hasher);
        let key = hasher.finish();

        let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();

        if let Some(&timestamp) = cache.get(&key) {
            if now.duration_since(timestamp) < self.window {
                return true; // Duplicate found within window
            }
        }

        // Not a duplicate or expired; update/insert
        cache.insert(key, now);
        false
    }

    /// Purges expired entries to prevent memory leaks.
    /// Should be called periodically.
    pub fn purge(&self) {
        let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        cache.retain(|_, &mut timestamp| now.duration_since(timestamp) < self.window);
    }
}
