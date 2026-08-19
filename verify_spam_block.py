import asyncio
import json
import websockets
import time

async def verify_spam():
    uri = "ws://localhost:7777"
    privkey = "nsec1..." # Not needed for simple connection/publishing usually, unless auth required. 
                         # We'll simulate raw events. 
    # Actually, to publish we need to sign. Ideally we use a library or just send pre-signed valid json if we can generate it.
    # To keep it simple and dependency-light, we will assume we can just construct a valid event JSON if we had a library.
    # BUT we need to sign it for the relay to accept it (crypto verification).
    # Since we can't easily sign in raw python without secp256k1 lib, let's look for a basic signer or rely on installed `nostr` lib if available
    # The user has `websockets` from our venv. 
    
    # We will try to rely on the relay rejecting "invalid signature" LATER than spam check? 
    # No, typically auth/sig check happens early. 
    # Let's try to install `nostr` python package or `cffi` / `secp256k1` if possible, 
    # OR simpler: just check if the relay accepts a connection and likely we can test the "read" side of spam (blocking subscriptions) if implemented?
    # Our impl blocks *publishing* (sending TO relay). 
    
    # Let's use the 'nostr' package if we can, or just manual mock.
    # Actually, simpler: I'll use the existing `nostr-rs-relay` binary or `bench` tools if they exist?
    # No, let's write a python script that uses `nostr` package.
    pass

# We will write the file content assuming 'nostr' package is available or we can pip install it.
# `pip install nostr`
    
import ssl
import time
from nostr.event import Event
from nostr.key import PrivateKey

async def run_test():
    uri = "ws://localhost:7777"
    print(f"Connecting to {uri}")
    async with websockets.connect(uri) as websocket:
        
        # 1. Test Good Message
        pk = PrivateKey()
        event = Event(pk.public_key.hex(), "Hello World Unique " + str(time.time()))
        pk.sign_event(event)
        await websocket.send(event.to_message())
        print("Sent good message.")
        # We need to listen to 'OK' command from relay (NIP-20)
        try:
            res = await asyncio.wait_for(websocket.recv(), timeout=2.0)
            print(f"Response: {res}")
        except:
             print("No immediate response (relay might not support NIP-20 or timeout)")

        # 2. Test Spam Content
        event_spam = Event(pk.public_key.hex(), "This includes Block 935037 and #bitcoinfees")
        pk.sign_event(event_spam)
        await websocket.send(event_spam.to_message())
        print("Sent SPAM content message.")
        try:
            res = await asyncio.wait_for(websocket.recv(), timeout=2.0)
            print(f"Response (should be blocked): {res}")
        except:
             print("Timeout waiting for response")

        # 3. Test Deduplication
        pk2 = PrivateKey() # New user
        content = f"Duplicate Me {time.time()}"
        
        # First send
        ev1 = Event(pk2.public_key.hex(), content)
        pk2.sign_event(ev1)
        await websocket.send(ev1.to_message())
        print("Sent Dedup Msg 1 (Should be OK)")
        try:
            res = await asyncio.wait_for(websocket.recv(), timeout=2.0)
            print(f"Response 1: {res}")
        except: pass

        # Second send (Immediate duplicate)
        ev2 = Event(pk2.public_key.hex(), content) # Exactly same content
        pk2.sign_event(ev2) # Same pubkey
        # Note: Event ID will be different if timestamp changed slightly or we reuse object?
        # Our server checks (pubkey, content). Event ID doesn't matter for this check.
        await websocket.send(ev2.to_message())
        print("Sent Dedup Msg 2 (Should be BLOCKED)")
        try:
            res = await asyncio.wait_for(websocket.recv(), timeout=2.0)
            print(f"Response 2: {res}")
        except: pass

if __name__ == "__main__":
    try:
        asyncio.run(run_test())
    except Exception as e:
        print(f"Test failed: {e}")
