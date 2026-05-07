#!/usr/bin/env python3
import json
import os
import threading
import unittest
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock

import glm_web_search
import local_knowledge_search


class _Handler(BaseHTTPRequestHandler):
    response_status = 200
    response_body = {"results": []}
    last_request = None

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        type(self).last_request = {
            "path": self.path,
            "headers": dict(self.headers),
            "body": json.loads(body) if body else {},
        }
        self.send_response(type(self).response_status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(type(self).response_body).encode("utf-8"))

    def log_message(self, *_args):
        return


class ServerFixture:
    def __enter__(self):
        _Handler.response_status = 200
        _Handler.response_body = {"results": []}
        _Handler.last_request = None
        self.server = HTTPServer(("127.0.0.1", 0), _Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        host, port = self.server.server_address
        self.base_url = f"http://{host}:{port}"
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()


class RagScriptTests(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(os.environ, {}, clear=True)
        self.env.start()
        os.environ["EDGECLAW_RAG_ENABLED"] = "1"

    def tearDown(self):
        self.env.stop()

    def test_local_search_success(self):
        with ServerFixture() as fixture:
            _Handler.response_body = {
                "results": [
                    {
                        "id": "doc-1",
                        "title": "Report",
                        "content": "Local evidence",
                        "score": 0.91,
                        "source": "military-kb",
                    }
                ]
            }
            os.environ["EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL"] = fixture.base_url
            os.environ["EDGECLAW_RAG_LOCAL_KNOWLEDGE_MILVUS_URI"] = "http://milvus.example.com:19530"
            os.environ["EDGECLAW_RAG_LOCAL_KNOWLEDGE_API_KEY"] = "secret"

            result = local_knowledge_search.search_local_knowledge("air defense", top_k=3)

        self.assertTrue(result["ok"])
        self.assertIn("Local evidence", result["context"])
        self.assertEqual(result["citations"][0]["id"], "doc-1")
        self.assertEqual(_Handler.last_request["path"], "/search")
        self.assertEqual(_Handler.last_request["body"]["topK"], 3)
        self.assertEqual(_Handler.last_request["body"]["milvusUri"], "http://milvus.example.com:19530")
        self.assertEqual(_Handler.last_request["headers"]["Authorization"], "Bearer secret")

    def test_web_search_success(self):
        with ServerFixture() as fixture:
            _Handler.response_body = {
                "results": [
                    {
                        "title": "News",
                        "url": "https://example.com/news",
                        "snippet": "Current evidence",
                        "publishedAt": "2026-05-06",
                    }
                ]
            }
            os.environ["EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL"] = fixture.base_url

            result = glm_web_search.search_glm_web("current risk", top_k=2, freshness_days=7)

        self.assertTrue(result["ok"])
        self.assertIn("Current evidence", result["context"])
        self.assertEqual(result["citations"][0]["url"], "https://example.com/news")
        self.assertEqual(_Handler.last_request["body"]["freshnessDays"], 7)

    def test_default_top_k_comes_from_environment(self):
        with ServerFixture() as fixture:
            os.environ["EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL"] = fixture.base_url
            os.environ["EDGECLAW_RAG_LOCAL_KNOWLEDGE_TOP_K"] = "11"
            local_result = local_knowledge_search.search_local_knowledge("local query")
            local_top_k = _Handler.last_request["body"]["topK"]

            os.environ["EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL"] = f"{fixture.base_url}/api/paas/v4/web_search"
            os.environ["EDGECLAW_RAG_GLM_WEB_SEARCH_TOP_K"] = "10"
            web_result = glm_web_search.search_glm_web("web query")
            web_count = _Handler.last_request["body"]["count"]

        self.assertTrue(local_result["ok"])
        self.assertEqual(local_top_k, 11)
        self.assertTrue(web_result["ok"])
        self.assertEqual(web_count, 10)

    def test_zai_web_search_endpoint_success(self):
        with ServerFixture() as fixture:
            _Handler.response_body = {
                "search_result": [
                    {
                        "title": "Z.AI News",
                        "link": "https://example.com/zai",
                        "content": "Z.AI current evidence",
                        "media": "example.com",
                        "publish_date": "2026-05-07",
                    }
                ]
            }
            os.environ["EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL"] = f"{fixture.base_url}/api/paas/v4/web_search"
            os.environ["EDGECLAW_RAG_GLM_WEB_SEARCH_API_KEY"] = "web-secret"

            result = glm_web_search.search_glm_web(
                "current risk",
                top_k=80,
                freshness_days=7,
                allowed_domains=["example.com"],
                blocked_domains=["ignored.example.com"],
            )

        self.assertTrue(result["ok"])
        self.assertEqual(result["debug"]["provider"], "zai")
        self.assertEqual(result["debug"]["topK"], 50)
        self.assertEqual(result["citations"][0]["url"], "https://example.com/zai")
        self.assertEqual(_Handler.last_request["path"], "/api/paas/v4/web_search")
        self.assertEqual(_Handler.last_request["headers"]["Authorization"], "Bearer web-secret")
        self.assertEqual(_Handler.last_request["body"]["search_engine"], "search-prime")
        self.assertEqual(_Handler.last_request["body"]["search_query"], "current risk")
        self.assertEqual(_Handler.last_request["body"]["count"], 50)
        self.assertEqual(_Handler.last_request["body"]["search_recency_filter"], "oneWeek")
        self.assertEqual(_Handler.last_request["body"]["search_domain_filter"], "example.com")
        self.assertNotIn("blockedDomains", _Handler.last_request["body"])

    def test_missing_config_returns_json_error(self):
        result = local_knowledge_search.search_local_knowledge("query")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "missing_config")

    def test_empty_results_are_successful(self):
        with ServerFixture() as fixture:
            os.environ["EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL"] = fixture.base_url

            result = local_knowledge_search.search_local_knowledge("query")

        self.assertTrue(result["ok"])
        self.assertEqual(result["results"], [])
        self.assertEqual(result["citations"], [])
        self.assertEqual(result["context"], "")

    def test_timeout_returns_json_error(self):
        timeout = urllib.error.URLError(TimeoutError("timed out"))
        with mock.patch("glm_web_search._request_json", side_effect=timeout):
            os.environ["EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL"] = "http://127.0.0.1:1"
            result = glm_web_search.search_glm_web("query")

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "timeout")

    def test_http_error_returns_json_error(self):
        with ServerFixture() as fixture:
            _Handler.response_status = 401
            _Handler.response_body = {"error": "unauthorized"}
            os.environ["EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL"] = fixture.base_url

            result = glm_web_search.search_glm_web("query")

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "http_error")

    def test_invalid_json_returns_json_error(self):
        with mock.patch("local_knowledge_search._request_json", side_effect=json.JSONDecodeError("bad", "x", 0)):
            os.environ["EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL"] = "http://127.0.0.1:1"
            result = local_knowledge_search.search_local_knowledge("query")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "invalid_json")


if __name__ == "__main__":
    unittest.main()
