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
from urllib.parse import urlparse


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


def _resolve_search_endpoint(configured_url: str) -> str:
    parsed = urlparse(configured_url)
    if parsed.path and parsed.path != "/":
        return configured_url.rstrip("/")
    return f"{configured_url.rstrip('/')}/search"


def _is_zai_web_search_endpoint(url: str) -> bool:
    parsed = urlparse(url)
    return parsed.path.rstrip("/").endswith("/web_search")


def _json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2)


def _extract_items(response: Any) -> list[Any]:
    if isinstance(response, list):
        return response
    if not isinstance(response, dict):
        return []
    for key in ("search_result", "results", "items", "webPages", "data"):
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
    published_at = item.get("publishedAt") or item.get("published_at") or item.get("publish_date") or item.get("date") or ""
    source = item.get("source") or item.get("site") or item.get("media") or "glm_web_search"

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


def _zai_recency_filter(freshness_days: int | None) -> str:
    if not freshness_days or freshness_days <= 0:
        return "noLimit"
    if freshness_days <= 1:
        return "oneDay"
    if freshness_days <= 7:
        return "oneWeek"
    if freshness_days <= 31:
        return "oneMonth"
    if freshness_days <= 366:
        return "oneYear"
    return "noLimit"


def _zai_payload(
    query: str,
    *,
    count: int,
    freshness_days: int | None,
    allowed_domains: list[str] | None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "search_engine": "search-prime",
        "search_query": query,
        "count": max(1, min(count, 50)),
        "search_recency_filter": _zai_recency_filter(freshness_days),
    }
    if allowed_domains:
        payload["search_domain_filter"] = allowed_domains[0]
    return payload


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
    url = _resolve_search_endpoint(base_url)
    is_zai = _is_zai_web_search_endpoint(url)
    if is_zai:
        payload = _zai_payload(
            query,
            count=effective_top_k,
            freshness_days=freshness_days,
            allowed_domains=allowed_domains,
        )
    else:
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

    error_debug = {
        "url": url,
        "provider": "zai" if is_zai else "generic",
        "topK": payload.get("count", effective_top_k),
    }

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
                "provider": "zai" if is_zai else "generic",
                "status": status,
                "elapsedMs": elapsed_ms,
                "topK": payload.get("count", effective_top_k),
                "resultCount": len(results),
            },
        }
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return _error(query, "http_error", f"HTTP {exc.code}: {detail or exc.reason}", {**error_debug, "status": exc.code})
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, TimeoutError):
            return _error(query, "timeout", f"Request timed out after {timeout_seconds}s.", error_debug)
        return _error(query, "request_error", str(exc.reason), error_debug)
    except TimeoutError:
        return _error(query, "timeout", f"Request timed out after {timeout_seconds}s.", error_debug)
    except json.JSONDecodeError as exc:
        return _error(query, "invalid_json", str(exc), error_debug)


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
