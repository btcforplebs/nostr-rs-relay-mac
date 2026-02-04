import asyncio
import json
import ssl
from collections import Counter

try:
    import websockets
except ImportError:
    print("websockets not installed. Please install with: pip install websockets")
    exit(1)

# Basic NSFW keywords list (english) - can be expanded
NSFW_KEYWORDS = [
    "porn", "xxx", "nude", "sex", "18+", "nsfw"
]

async def fetch_events():
    uri = "ws://localhost:7777"
    try:
        async with websockets.connect(uri) as websocket:
            # Request last 500 text notes (kind 1)
            req_filter = {"kinds": [1], "limit": 500}
            req = ["REQ", "spam_analysis_deep", req_filter]
            await websocket.send(json.dumps(req))
            
            print(f"Connected to {uri}, requesting 500 events...")
            
            events = []
            try:
                while True:
                    response = await asyncio.wait_for(websocket.recv(), timeout=5.0)
                    msg = json.loads(response)
                    if msg[0] == "EVENT":
                        events.append(msg[2])
                    elif msg[0] == "EOSE":
                        print("End of stored events")
                        break
            except asyncio.TimeoutError:
                print("Timeout waiting for events (or limits reached)")
            
            print(f"Fetched {len(events)} events. Analyzing...")
            
            # Analysis
            pubkey_counts = Counter()
            content_counts = Counter()
            nsfw_candidates = []
            
            for event in events:
                content = event['content']
                pubkey = event['pubkey']
                
                pubkey_counts[pubkey] += 1
                content_counts[content] += 1
                
                content_lower = content.lower()
                if any(keyword in content_lower for keyword in NSFW_KEYWORDS):
                    nsfw_candidates.append((pubkey, content))

            print("\n--- Top Active Pubkeys (Potential Bots) ---")
            for pubkey, count in pubkey_counts.most_common(10):
                print(f"Pubkey: {pubkey} - Count: {count}")

            print("\n--- Most Repetitive Content ---")
            for content, count in content_counts.most_common(5):
                if count > 1:
                    print(f"Count: {count} - Content: {content[:100]}...")

            print(f"\n--- Potential NSFW Content Found: {len(nsfw_candidates)} ---")
            for pubkey, content in nsfw_candidates[:10]:
                print(f"Pubkey: {pubkey} - Content: {content[:100]}...")

    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    asyncio.run(fetch_events())
