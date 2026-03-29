# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## Local Services

### SearXNG (Web Search)

A local privacy-respecting metasearch engine running as a Docker sidecar. Aggregates results from DuckDuckGo, Brave, and Bing.

**Use `web_fetch` to query it:**

```
GET http://searxng:8080/search?q=QUERY&format=json
```

**Parameters:**

| param | description | example |
|---|---|---|
| `q` | search query (required) | `q=rust+async` |
| `format` | must be `json` | `format=json` |
| `engines` | comma-separated engine names | `engines=bing,brave` |
| `categories` | `general`, `news`, `images`, `videos` | `categories=news` |
| `language` | language code | `language=en` |
| `pageno` | page number (default: 1) | `pageno=2` |

**Response fields per result:** `title`, `url`, `content`, `engine`, `score`, `category`, `publishedDate`

**When to use SearXNG vs `web_search`:**
- **Prefer SearXNG** for general web searches — it aggregates multiple engines and returns richer results
- **Use `web_search`** as fallback if SearXNG is down
- SearXNG is internal-only (no API key needed, no rate limits)

### Whisper (Audio Transcription)

Local Whisper service running on GPU (CUDA). Automatically transcribes voice messages from Telegram and other channels — no manual action needed.

- Model: `faster-whisper-large-v3`
- Runs on NVIDIA GPU (requires `nvidia-container-toolkit` on host)
- OpenAI-compatible API at `http://whisper:8000/v1/audio/transcriptions`
- Only available on GPU-equipped hosts (gracefully skipped on CPU-only machines)

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.
