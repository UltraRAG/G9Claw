#!/usr/bin/env python3
"""Call the configured 9GClaw local knowledge search API.

The API contract is fixed by 9GClaw v1:
POST {EDGECLAW_RAG_LOCAL_KNOWLEDGE_DATABASE_URL}
{
  "text": string,
  "top_k": number
}

The script always prints a JSON envelope so skills can pass failures back to the
model without losing context.
"""

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


def _resolve_search_endpoint(base_url: str, database_url: str) -> str:
    configured = database_url or base_url
    if configured.rstrip("/").endswith("/search"):
        return configured.rstrip("/")
    return _join_endpoint(configured, "/search")


def _json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2)


def _parse_json_object(value: str | None, field_name: str) -> dict[str, Any]:
    if not value:
        return {}
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{field_name} must be valid JSON") from exc
    if not isinstance(parsed, dict):
        raise ValueError(f"{field_name} must be a JSON object")
    return parsed


def _extract_items(response: Any) -> list[Any]:
    if isinstance(response, list):
        return response
    if not isinstance(response, dict):
        return []
    for key in ("results", "items", "documents", "data"):
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
            "id": f"result-{index + 1}",
            "title": f"Result {index + 1}",
            "content": text,
            "score": None,
            "source": "local_knowledge",
            "metadata": {},
        }

    metadata = item.get("metadata")
    if not isinstance(metadata, dict):
        metadata = {}

    entity = item.get("entity")
    if not isinstance(entity, dict):
        entity = {}

    content = (
        item.get("content")
        or item.get("text")
        or item.get("snippet")
        or item.get("body")
        or entity.get("text")
        or entity.get("content")
        or ""
    )
    title = item.get("title") or item.get("name") or metadata.get("title") or entity.get("title") or f"Result {index + 1}"
    result_id = (
        item.get("id")
        or item.get("docId")
        or item.get("documentId")
        or metadata.get("id")
        or entity.get("id")
        or f"result-{index + 1}"
    )
    source = item.get("source") or metadata.get("source") or entity.get("source") or "local_knowledge"

    return {
        "id": str(result_id),
        "title": str(title),
        "content": str(content),
        "score": item.get("score"),
        "source": str(source),
        "metadata": metadata,
    }


def _build_context(query: str, results: list[dict[str, Any]]) -> str:
    if not results:
        return ""
    lines = [
        "## 9GClaw Local Knowledge Search",
        f"query={query}",
        "",
    ]
    for index, item in enumerate(results, start=1):
        score = item.get("score")
        score_text = f" score={score}" if score is not None else ""
        lines.extend(
            [
                f"### [{index}] {item['title']} (id={item['id']}; source={item['source']}{score_text})",
                item["content"].strip() or "(empty content)",
                "",
            ]
        )
    lines.append("Use these local knowledge results as retrieved evidence, not as unverified model memory.")
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


def search_local_knowledge(
    query: str,
    *,
    top_k: int | None = None,
    filters: dict[str, Any] | None = None,
) -> dict[str, Any]:
    base_url = _env("EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL")
    api_key = _env("EDGECLAW_RAG_LOCAL_KNOWLEDGE_API_KEY")
    database_url = _env("EDGECLAW_RAG_LOCAL_KNOWLEDGE_DATABASE_URL") or _env("EDGECLAW_RAG_LOCAL_KNOWLEDGE_MILVUS_URI")
    model_name = _env("EDGECLAW_RAG_LOCAL_KNOWLEDGE_MODEL_NAME")
    default_top_k = _int_value(_env("EDGECLAW_RAG_LOCAL_KNOWLEDGE_TOP_K"), 8)
    timeout_seconds = _int_value(_env("EDGECLAW_RAG_LOCAL_KNOWLEDGE_TIMEOUT_SECONDS"), DEFAULT_TIMEOUT_SECONDS)

    if _env("EDGECLAW_RAG_ENABLED", "0") in {"0", "false", "False", "no", "NO"}:
        return _error(query, "rag_disabled", "9GClaw RAG is disabled. Set rag.enabled: true in ~/.edgeclaw/config.yaml.")
    if not base_url and not database_url:
        return _error(
            query,
            "missing_config",
            "EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL or EDGECLAW_RAG_LOCAL_KNOWLEDGE_DATABASE_URL is not configured.",
        )

    effective_top_k = top_k if top_k and top_k > 0 else default_top_k
    payload = {
        "text": query,
        "top_k": effective_top_k,
    }
    if filters and isinstance(filters.get("output_fields"), list):
        payload["output_fields"] = filters["output_fields"]
    url = _resolve_search_endpoint(base_url, database_url)
    error_debug = {
        "url": url,
        "topK": effective_top_k,
        "modelName": model_name,
        "modelNameConfigured": bool(model_name),
        "databaseUrlConfigured": bool(database_url),
    }

    try:
        raw, status, elapsed_ms = _request_json(url, api_key, payload, timeout_seconds)
        results = [_normalize_result(item, index) for index, item in enumerate(_extract_items(raw))]
        citations = [
            {
                "type": "local_knowledge",
                "id": item["id"],
                "title": item["title"],
                "source": item["source"],
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
                "modelName": model_name,
                "modelNameConfigured": bool(model_name),
                "databaseUrlConfigured": bool(database_url),
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
    parser = argparse.ArgumentParser(description="Search 9GClaw local knowledge.")
    parser.add_argument("--query", required=True, help="Search query.")
    parser.add_argument("--top-k", type=int, default=None, help="Maximum number of results.")
    parser.add_argument("--filters-json", default=None, help="Optional JSON object passed as filters.")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        filters = _parse_json_object(args.filters_json, "--filters-json")
        output = search_local_knowledge(args.query, top_k=args.top_k, filters=filters)
    except ValueError as exc:
        output = _error(args.query, "invalid_arguments", str(exc))
    print(_json_dumps(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
