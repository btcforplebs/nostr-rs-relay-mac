import asyncio
import json
import ssl
try:
    import websockets
except ImportError:
    print("websockets not installed. Please install with: pip install websockets")
    exit(1)

async def fetch_events():
    uri = "ws://localhost:7777"
    try:
        async with websockets.connect(uri) as websocket:
            # Request last 50 text notes (kind 1)
            req_filter = {"kinds": [1], "limit": 50}
            req = ["REQ", "spam_analysis_2", req_filter]
            await websocket.send(json.dumps(req))
            
            print(f"Connected to {uri}, requesting events...")
            
            events = []
            try:
                while True:
                    response = await asyncio.wait_for(websocket.recv(), timeout=5.0)
                    msg = json.loads(response)
                    if msg[0] == "EVENT":
                        content = msg[2]['content']
                        pubkey = msg[2]['pubkey']
                        # Simple heuristic for the observed spam
                        is_spam = "bitcoinfees" in content or "Block" in content
                        prefix = "[SPAM?] " if is_spam else ""
                        print(f"{prefix}Pubkey: {pubkey[:8]}... Content: {content[:100]}...")
                        events.append(msg[2])
                    elif msg[0] == "EOSE":
                        print("End of stored events")
                        break
            except asyncio.TimeoutError:
                print("Timeout waiting for events")
            
            print(f"Fetched {len(events)} events.")

    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    asyncio.run(fetch_events())
