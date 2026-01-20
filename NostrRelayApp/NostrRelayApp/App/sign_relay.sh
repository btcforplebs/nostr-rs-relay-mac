#!/bin/bash

# This script signs the nested 'nostr-rs-relay' Go binary with Hardened Runtime support.
# It uses the same identity and entitlements as the host app.

HAVEN_PATH="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/nostr-rs-relay"
ENTITLEMENTS="${PROJECT_DIR}/NostrRelayApp/App/NostrRelayApp.entitlements"

if [ -f "$HAVEN_PATH" ]; then
    echo "🔒 Signing nostr-rs-relay binary for Hardened Runtime..."
    
    # Sign with the expanded identity from Xcode environment
    /usr/bin/codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "${EXPANDED_CODE_SIGN_IDENTITY_NAME}" "$HAVEN_PATH"
    
    if [ $? -eq 0 ]; then
        echo "✅ Successfully signed nostr-rs-relay binary."
    else
        echo "❌ Failed to sign nostr-rs-relay binary."
        exit 1
    fi
else
    echo "⚠️ Warning: nostr-rs-relay binary not found at $HAVEN_PATH. Skip signing."
fi
