# Reverse Proxy Deployment

9GClaw serves the SPA, REST APIs, WebSocket traffic, and long-running streaming responses from the same Node process. A reverse proxy must preserve WebSocket upgrades and avoid buffering streaming API responses, otherwise model requests can appear to hang or get dropped.

## Nginx

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name example.com;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 60s;

        proxy_buffering off;
        proxy_cache off;
        gzip off;
        add_header X-Accel-Buffering no always;
    }
}
```

If static assets are served by Nginx instead of Node, keep `/assets/*` immutable and do not cache HTML:

```nginx
location /assets/ {
    alias /path/to/edgeclaw-opc/ui/dist/assets/;
    expires 1y;
    add_header Cache-Control "public, max-age=31536000, immutable";
}

location = /index.html {
    proxy_pass http://127.0.0.1:3001;
    add_header Cache-Control "no-cache, no-store, must-revalidate";
}
```

## Caddy

```caddyfile
example.com {
    encode zstd gzip

    reverse_proxy 127.0.0.1:3001 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        flush_interval -1
        transport http {
            read_timeout 3600s
            write_timeout 3600s
        }
    }
}
```

Caddy handles WebSocket upgrades automatically. `flush_interval -1` is the important setting for streamed model responses and server-sent events.

## Notes

- Keep all runtime assets local. The bundled SPA and API docs should not depend on public CDNs.
- Do not put buffering proxies between the browser and `/ws` or streaming `/api/*` routes.
- Use one public origin for the UI and API. The frontend derives WebSocket URLs from `window.location`, so split domains require additional CORS and WebSocket configuration.
