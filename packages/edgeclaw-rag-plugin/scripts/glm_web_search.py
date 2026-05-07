#!/usr/bin/env python3
"""Call the configured GLM web search API for 9GClaw RAG v1."""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.request
from typing import Any


DEFAULT_TIMEOUT_SECONDS = 15


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _int_value(value: str | None, default: int) -> int:
    if value is None or not str(value).strip():
        return default
    try:
        parsed = int(str(value).strip())
    except ValueError:
        return default
    return parsed if parsed > 0 else default


def _join_endpoint(base_url: str, endpoint: str) -> str:
    return f"{base_url.rstrip('/')}/{endpoint.lstrip('/')}"


def _json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2)


def _extract_items(response: Any) -> list[Any]:
    if isinstance(response, list):
        return response
    if not isinstance(response, dict):
        return []
    for key in ("results", "items", "webPages", "data"):
        value = response.get(key)
        if isinstance(value, list):
            return value
        if isinstance(value, dict):
            nested = _extract_items(value)
            if nested:
                return nested
    return []


def _normalize_result(item: Any, index: int) -> dict[str, Any]:
    if not isinstance(item, dict):
        text = str(item)
        return {
            "title": f"Result {index + 1}",
            "url": "",
            "snippet": text,
            "publishedAt": "",
            "source": "glm_web_search",
        }

    title = item.get("title") or item.get("name") or f"Result {index + 1}"
    url = item.get("url") or item.get("link") or item.get("href") or ""
    snippet = item.get("snippet") or item.get("summary") or item.get("content") or item.get("text") or ""
    published_at = item.get("publishedAt") or item.get("published_at") or item.get("date") or ""
    source = item.get("source") or item.get("site") or "glm_web_search"

    return {
        "title": str(title),
        "url": str(url),
        "snippet": str(snippet),
        "publishedAt": str(published_at),
        "source": str(source),
    }


def _build_context(query: str, results: list[dict[str, Any]]) -> str:
    if not results:
        return ""
    lines = [
        "## 9GClaw GLM Web Search",
        f"query={query}",
        "",
    ]
    for index, item in enumerate(results, start=1):
        published = f"; published={item['publishedAt']}" if item.get("publishedAt") else ""
        url = item.get("url") or "no-url"
        lines.extend(
            [
                f"### [{index}] {item['title']} ({url}; source={item['source']}{published})",
                item["snippet"].strip() or "(empty snippet)",
                "",
            ]
        )
    lines.append("Use these web results as current public-source evidence and cite URLs when used.")
    return "\n".join(lines).strip()


def _request_json(url: str, api_key: str, payload: dict[str, Any], timeout_seconds: int) -> tuple[Any, int, float]:
    started = time.time()
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        status = int(response.status)
        raw = response.read().decode("utf-8")
    elapsed_ms = round((time.time() - started) * 1000, 2)
    return json.loads(raw) if raw.strip() else {}, status, elapsed_ms


def search_glm_web(
    query: str,
    *,
    top_k: int | None = None,
    freshness_days: int | None = None,
    allowed_domains: list[str] | None = None,
    blocked_domains: list[str] | None = None,
) -> dict[str, Any]:
    base_url = _env("EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL")
    api_key = _env("EDGECLAW_RAG_GLM_WEB_SEARCH_API_KEY")
    default_top_k = _int_value(_env("EDGECLAW_RAG_GLM_WEB_SEARCH_TOP_K"), 8)
    timeout_seconds = _int_value(_env("EDGECLAW_RAG_GLM_WEB_SEARCH_TIMEOUT_SECONDS"), DEFAULT_TIMEOUT_SECONDS)

    if _env("EDGECLAW_RAG_ENABLED", "0") in {"0", "false", "False", "no", "NO"}:
        return _error(query, "rag_disabled", "9GClaw RAG is disabled. Set rag.enabled: true in ~/.edgeclaw/config.yaml.")
    if not base_url:
        return _error(query, "missing_config", "EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL is not configured.")

    effective_top_k = top_k if top_k and top_k > 0 else default_top_k
    payload: dict[str, Any] = {
        "query": query,
        "topK": effective_top_k,
    }
    if freshness_days and freshness_days > 0:
        payload["freshnessDays"] = freshness_days
    if allowed_domains:
        payload["allowedDomains"] = allowed_domains
    if blocked_domains:
        payload["blockedDomains"] = blocked_domains

    url = _join_endpoint(base_url, "/search")

    try:
        raw, status, elapsed_ms = _request_json(url, api_key, payload, timeout_seconds)
        results = [_normalize_result(item, index) for index, item in enumerate(_extract_items(raw))]
        citations = [
            {
                "type": "web",
                "title": item["title"],
                "url": item["url"],
                "source": item["source"],
                "publishedAt": item["publishedAt"],
            }
            for item in results
        ]
        return {
            "ok": True,
            "query": query,
            "context": _build_context(query, results),
            "results": results,
            "citations": citations,
            "debug": {
                "url": url,
                "status": status,
                "elapsedMs": elapsed_ms,
                "topK": effective_top_k,
                "resultCount": len(results),
            },
        }
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return _error(query, "http_error", f"HTTP {exc.code}: {detail or exc.reason}", {"url": url, "status": exc.code})
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, TimeoutError):
            return _error(query, "timeout", f"Request timed out after {timeout_seconds}s.", {"url": url})
        return _error(query, "request_error", str(exc.reason), {"url": url})
    except TimeoutError:
        return _error(query, "timeout", f"Request timed out after {timeout_seconds}s.", {"url": url})
    except json.JSONDecodeError as exc:
        return _error(query, "invalid_json", str(exc), {"url": url})


def _error(query: str, code: str, message: str, debug: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "ok": False,
        "query": query,
        "context": "",
        "results": [],
        "citations": [],
        "error": {"code": code, "message": message},
        "debug": debug or {},
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Search GLM web search for 9GClaw RAG.")
    parser.add_argument("--query", required=True, help="Search query.")
    parser.add_argument("--top-k", type=int, default=None, help="Maximum number of results.")
    parser.add_argument("--freshness-days", type=int, default=None, help="Optional freshness window in days.")
    parser.add_argument("--allowed-domain", action="append", default=[], help="Allowed result domain. Repeatable.")
    parser.add_argument("--blocked-domain", action="append", default=[], help="Blocked result domain. Repeatable.")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    output = search_glm_web(
        args.query,
        top_k=args.top_k,
        freshness_days=args.freshness_days,
        allowed_domains=args.allowed_domain,
        blocked_domains=args.blocked_domain,
    )
    print(_json_dumps(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
