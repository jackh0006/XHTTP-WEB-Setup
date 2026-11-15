# Architecture

The installer preserves the existing Xray listener and places a normal HTTPS frontend in front of it.

```mermaid
flowchart TD
    Browser -->|TCP 443| Redirect[iptables: external 443 -> local 8443]
    Redirect --> Nginx[Nginx HTTPS frontend]
    Nginx -->|normal paths| Site[/var/www/cloudf-www]
    Nginx -->|XHTTP path only, TLS loopback| Xray[Xray on 127.0.0.1:443]
    Xray --> Tunnel[Existing VLESS/XHTTP tunnel]
```

| Route | Handler | Why |
|---|---|---|
| `/` and ordinary files | Nginx | The browser sees a normal website. |
| Existing XHTTP path | Nginx → Xray | Existing clients keep their path and port. |
| Xray users and UUIDs | x-ui/Xray | The installer does not edit them. |

The site and proxy path are separate. A normal browser never needs a proxy account.
