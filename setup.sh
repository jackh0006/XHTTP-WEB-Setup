#!/usr/bin/env bash
# CloudF XHTTP + website installer
#
# Designed for a server where x-ui/Xray already owns public TCP/443 using
# VLESS + XHTTP + TLS. It adds a Persian file-transfer website without
# restarting or changing Xray: Nginx handles normal HTTPS on local 8443 and
# forwards the existing XHTTP path to Xray on 127.0.0.1:443. A narrow NAT rule
# sends only externally received TCP/443 traffic to Nginx.

set -Eeuo pipefail
IFS=$'\n\t'

readonly XRAY_CONFIG='/usr/local/x-ui/bin/config.json'
readonly WEB_ROOT='/var/www/cloudf-www'
readonly HTTP_CONF='/etc/nginx/sites-available/cloudf-www'
readonly HTTP_LINK='/etc/nginx/sites-enabled/cloudf-www'
readonly HTTPS_CONF='/etc/nginx/sites-available/cloudf-www-https-proxy'
readonly HTTPS_LINK='/etc/nginx/sites-enabled/cloudf-www-https-proxy'
readonly REDIRECT_UNIT='/etc/systemd/system/cloudf-https-redirect.service'

log()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '\\nWARNING: %s\\n' "$*" >&2; }

# Install only missing operating-system prerequisites. x-ui itself is never
# installed or upgraded; this script preserves its active XHTTP listener.
install_missing_packages() {
  declare -A package_for=(
    [awk]=mawk [curl]=curl [find]=findutils [grep]=grep [ip]=iproute2
    [iptables]=iptables [jq]=jq [nginx]=nginx [openssl]=openssl [sed]=sed
    [ss]=iproute2 [systemctl]=systemd [date]=coreutils [install]=coreutils
  )
  local command
  local -a missing=()
  for command in "${!package_for[@]}"; do
    command -v "$command" >/dev/null 2>&1 || missing+=("${package_for[$command]}")
  done
  (("${#missing[@]}")) || return 0
  command -v apt-get >/dev/null 2>&1 || fail "Missing required commands (${missing[*]}) and apt-get is unavailable."
  mapfile -t missing < <(printf '%s\\n' "${missing[@]}" | sort -u)
  log "Installing missing prerequisites: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || fail 'Package index update failed; no service configuration was changed.'
  apt-get install -y --no-install-recommends "${missing[@]}" || fail 'Prerequisite installation failed; no service configuration was changed.'
}

[[ ${EUID:-999} -eq 0 ]] || fail 'Run this script as root: sudo bash cloudf-xhttp-web-setup.sh'
install_missing_packages
[[ -r "$XRAY_CONFIG" ]] || fail "Xray configuration was not found at $XRAY_CONFIG"
if ! systemctl is-active --quiet nginx; then
  log 'Starting Nginx'
  systemctl enable --now nginx || fail 'Nginx could not be started. Check whether another service already uses port 80.'
fi
systemctl is-active --quiet x-ui || fail 'x-ui is not active.'

read -r -p 'Web domain (for example: cloudf.ir or www.cloudf.ir): ' INPUT_DOMAIN
INPUT_DOMAIN=${INPUT_DOMAIN,,}
INPUT_DOMAIN=${INPUT_DOMAIN#http://}
INPUT_DOMAIN=${INPUT_DOMAIN#https://}
INPUT_DOMAIN=${INPUT_DOMAIN%%/*}
INPUT_DOMAIN=${INPUT_DOMAIN%.}
BASE_DOMAIN=${INPUT_DOMAIN#www.}
[[ $BASE_DOMAIN =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || fail 'Enter a valid DNS domain, without a protocol or path.'
WEB_DOMAIN="www.${BASE_DOMAIN}"
WAN_IF=$(ip route show default | awk '/default/ {print $5; exit}')
[[ -n $WAN_IF ]] || fail 'Could not determine the public network interface; no change was made.'

# Refuse to touch an unrelated Xray profile. The only supported arrangement is
# an existing XHTTP-over-TLS VLESS inbound on port 443.
INBOUND_COUNT=$(jq '[.inbounds[] | select(.port == 443 and .protocol == "vless" and .streamSettings.network == "xhttp" and .streamSettings.security == "tls")] | length' "$XRAY_CONFIG")
[[ $INBOUND_COUNT == 1 ]] || fail 'Expected exactly one VLESS + XHTTP + TLS inbound on port 443; no change was made.'

XRAY_PATH=$(jq -r '.inbounds[] | select(.port == 443 and .protocol == "vless" and .streamSettings.network == "xhttp" and .streamSettings.security == "tls") | .streamSettings.xhttpSettings.path // empty' "$XRAY_CONFIG")
XRAY_NAME=$(jq -r '.inbounds[] | select(.port == 443 and .protocol == "vless" and .streamSettings.network == "xhttp" and .streamSettings.security == "tls") | .streamSettings.tlsSettings.serverName // empty' "$XRAY_CONFIG")
CERT_FILE=$(jq -r '.inbounds[] | select(.port == 443 and .protocol == "vless" and .streamSettings.network == "xhttp" and .streamSettings.security == "tls") | .streamSettings.tlsSettings.certificates[0].certificateFile // empty' "$XRAY_CONFIG")
KEY_FILE=$(jq -r '.inbounds[] | select(.port == 443 and .protocol == "vless" and .streamSettings.network == "xhttp" and .streamSettings.security == "tls") | .streamSettings.tlsSettings.certificates[0].keyFile // empty' "$XRAY_CONFIG")

[[ $XRAY_PATH == /* && $XRAY_PATH != '/' ]] || fail 'The XHTTP path is absent or unsafe; no change was made.'
[[ -n $XRAY_NAME && -r $CERT_FILE && -r $KEY_FILE ]] || fail 'The existing Xray certificate or server name cannot be read; no change was made.'
[[ $XRAY_PATH =~ ^/[A-Za-z0-9._~/-]+/?$ ]] || fail 'The XHTTP path contains unsafe characters; no change was made.'
[[ $XRAY_NAME =~ ^[A-Za-z0-9.-]+$ ]] || fail 'The Xray TLS server name contains unsafe characters; no change was made.'
openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null | grep -Eq "DNS:(${BASE_DOMAIN}|${WEB_DOMAIN})(,|$)" || fail 'The existing Xray certificate does not cover the entered domain; no change was made.'
ss -ltnp | grep -qE '[:.]443 .*xray' || fail 'No Xray listener was found on TCP port 443; no change was made.'

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="/root/cloudf-web-setup-backup-${STAMP}"
mkdir -p "$BACKUP_DIR"

backup() {
  local target=$1 destination
  [[ -e $target || -L $target ]] || return 0
  destination="$BACKUP_DIR${target}"
  mkdir -p "$(dirname "$destination")"
  cp -a -- "$target" "$destination"
}

restore() {
  local target=$1
  local source="$BACKUP_DIR${target}"
  if [[ ! -e $source && ! -L $source ]]; then
    rm -rf -- "$target"
    return 0
  fi
  rm -rf -- "$target"
  mkdir -p "$(dirname "$target")"
  cp -a -- "$source" "$target"
}

restore_nginx() {
  restore "$HTTP_CONF"
  restore "$HTTP_LINK"
  restore "$HTTPS_CONF"
  restore "$HTTPS_LINK"
  if nginx -t; then
    systemctl reload nginx || warn 'The previous Nginx configuration was restored but could not be reloaded automatically.'
  else
    warn "The previous Nginx configuration was restored in $BACKUP_DIR, but still fails validation."
  fi
}

log "Creating backups in $BACKUP_DIR"
for target in "$HTTP_CONF" "$HTTP_LINK" "$HTTPS_CONF" "$HTTPS_LINK" "$REDIRECT_UNIT" "$WEB_ROOT/index.html" "$WEB_ROOT/404.html" "$WEB_ROOT/site.css" "$WEB_ROOT/robots.txt" "$WEB_ROOT/sitemap.xml" "$WEB_ROOT/about/index.html" "$WEB_ROOT/docs/index.html" "$WEB_ROOT/status/index.html" "$WEB_ROOT/privacy/index.html" "$WEB_ROOT/terms/index.html"; do backup "$target"; done

install -d -m 0755 "$WEB_ROOT" "$WEB_ROOT"/{about,docs,status,privacy,terms}

log 'Writing the Persian static website'
cat >"$WEB_ROOT/index.html" <<'HTML'
<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="CloudF؛ فضای ساده و امن برای ارسال و دریافت فایل."><meta name="theme-color" content="#0c6578"><title>CloudF | ارسال امن فایل</title><style>:root{--ink:#15242d;--muted:#5b7078;--line:#d9e6e8;--brand:#0c6578;--deep:#083d4a;--pale:#f3f8f8;--danger:#b8463f}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);font:16px/1.9 Tahoma,Arial,sans-serif;background:#fff}a{text-decoration:none;color:inherit}.wrap{max-width:1080px;margin:auto;padding:0 24px}header{position:sticky;top:0;z-index:3;border-bottom:1px solid var(--line);background:rgba(255,255,255,.94);backdrop-filter:blur(10px)}.nav{display:flex;align-items:center;gap:28px;min-height:69px}.brand{display:flex;align-items:center;gap:10px;font:700 21px Arial;color:var(--deep)}.mark{width:31px;height:31px;border-radius:9px;background:linear-gradient(145deg,#0e8091,#0a5062);position:relative}.mark:after{content:"";position:absolute;width:13px;height:13px;border:2px solid #fff;border-radius:50%;top:7px;right:7px}.navlinks{display:flex;gap:22px;list-style:none;padding:0;margin:0;color:#50666e;font-size:14px}.login-link{margin-right:auto;color:var(--brand);font-size:14px;font-weight:bold}.hero{background:radial-gradient(640px 400px at 12% 0,#dff3f4 0,transparent 67%),linear-gradient(180deg,#fff,#f7fbfb);padding:72px 0 78px;border-bottom:1px solid var(--line)}.hero-grid{display:grid;grid-template-columns:1fr 420px;gap:62px;align-items:center}.pill{display:inline-block;padding:4px 11px;border:1px solid #cde8e6;background:#e9f7f5;color:#087267;border-radius:20px;font-size:12px;font-weight:bold}.hero h1{font-size:42px;line-height:1.45;letter-spacing:-1px;margin:16px 0 12px}.hero h1 strong{color:var(--brand)}.hero p{margin:0;max-width:530px;color:var(--muted);font-size:17px}.small{margin-top:17px!important;color:#74878d!important;font-size:13px!important}.login{border:1px solid #cfe0e3;border-radius:15px;background:#fff;padding:27px;box-shadow:0 24px 50px -32px #31616b}.login h2{font-size:20px;margin:0 0 3px}.login .intro{font-size:13px;margin:0 0 21px;color:var(--muted)}label{display:block;margin:13px 0 5px;font-size:13px;color:#415861;font-weight:bold}input{display:block;width:100%;border:1px solid #bfd4d8;border-radius:8px;padding:11px 12px;font:14px Tahoma,Arial;background:#fff;outline:none;direction:ltr;text-align:left}button{width:100%;cursor:pointer;border:0;border-radius:8px;background:var(--brand);color:#fff;padding:11px;margin-top:19px;font:700 14px Tahoma,Arial}.form-note{min-height:22px;margin:13px 0 0;font-size:12.5px;color:var(--muted)}.form-note.show{color:var(--danger)}section{padding:76px 0}.intro-block{max-width:650px;margin-bottom:35px}.eyebrow{font-size:13px;font-weight:bold;color:var(--brand)}h2.section-title{font-size:29px;line-height:1.5;margin:6px 0}.intro-block p{margin:0;color:var(--muted)}.cards,.steps{display:grid;grid-template-columns:repeat(3,1fr);gap:18px}.card{border:1px solid var(--line);border-radius:13px;padding:23px;background:#fff}.icon{width:41px;height:41px;border-radius:10px;background:#e5f5f4;color:var(--brand);display:grid;place-items:center;font:bold 20px Arial}.card h3{font-size:17px;margin:14px 0 6px}.card p,.step p,.qa p{margin:0;color:var(--muted);font-size:14px}.band{background:var(--pale);border-block:1px solid var(--line)}.step{padding-top:47px;position:relative}.step b{position:absolute;top:0;color:#a6c2c7;font:700 25px Arial}.step h3{font-size:17px;margin:0 0 6px}.faq{max-width:780px}.qa{padding:17px 0;border-bottom:1px solid var(--line)}.qa h3{margin:0 0 5px;font-size:16px}.closing{background:var(--deep);color:#fff}.closing h2{font-size:28px;margin:0 0 7px}.closing p{color:#bfd5d9;margin:0}.closing a{display:inline-block;margin-top:19px;color:#fff;border-bottom:1px solid #85b6bf}.footer{background:#072e38;color:#c5d8db;padding:33px 0;font-size:13px}.footer-row{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap}.footer-links{display:flex;gap:15px}@media(max-width:800px){.hero{padding:55px 0}.hero-grid,.cards,.steps{grid-template-columns:1fr;gap:28px}.hero h1{font-size:33px}.navlinks{display:none}section{padding:57px 0}}</style></head><body><header><div class="wrap nav"><a class="brand" href="/"><span class="mark"></span>CloudF</a><nav><ul class="navlinks"><li><a href="#how">نحوه کار</a></li><li><a href="#features">ویژگی‌ها</a></li><li><a href="#faq">پرسش‌های رایج</a></li></ul></nav><a class="login-link" href="#login">ورود به حساب</a></div></header><main><section class="hero"><div class="wrap hero-grid"><div><span class="pill">انتقال فایل، بدون پیچیدگی</span><h1>فایل‌هایتان را <strong>ساده و مطمئن</strong> جابه‌جا کنید.</h1><p>CloudF فضایی برای ارسال، دریافت و مدیریت فایل‌های کاری است؛ با دسترسی سازمان‌یافته و روندی روشن برای تیم‌ها و کاربران تأییدشده.</p><p class="small">استفاده از فضای کاربری با حساب دعوت‌شده امکان‌پذیر است.</p></div><aside class="login" id="login"><h2>ورود به فضای فایل</h2><p class="intro">برای ورود، از اطلاعات حسابی که برای شما صادر شده استفاده کنید.</p><form id="access-form" novalidate><label for="username">نام کاربری</label><input id="username" autocomplete="username" placeholder="نام کاربری"><label for="password">رمز عبور</label><input id="password" type="password" autocomplete="current-password" placeholder="رمز عبور"><button type="submit">ورود</button><p class="form-note" id="access-message" aria-live="polite">حساب کاربری ندارید؟ برای دریافت دسترسی با مسئول سازمان خود تماس بگیرید.</p></form></aside></div></section><section id="features"><div class="wrap"><div class="intro-block"><span class="eyebrow">برای کار با فایل‌ها</span><h2 class="section-title">همه‌چیز در یک فضای مرتب و قابل دسترس</h2><p>طراحی ساده، دسترسی کنترل‌شده و تمرکز بر نیازهای روزمره انتقال فایل.</p></div><div class="cards"><article class="card"><div class="icon">↑</div><h3>ارسال فایل</h3><p>فایل‌های موردنیاز را در فضای کاربری خود بارگذاری و برای همکاران مجاز در دسترس قرار دهید.</p></article><article class="card"><div class="icon">↓</div><h3>دریافت آسان</h3><p>دسترسی به فایل‌های به‌اشتراک‌گذاشته‌شده از طریق حساب کاربری شما انجام می‌شود.</p></article><article class="card"><div class="icon">⌘</div><h3>مدیریت دسترسی</h3><p>هر فضای کاری برای کاربران مشخص طراحی می‌شود تا روند تبادل فایل منظم باقی بماند.</p></article></div></div></section><section class="band" id="how"><div class="wrap"><div class="intro-block"><span class="eyebrow">نحوه کار</span><h2 class="section-title">سه قدم تا شروع همکاری</h2></div><div class="steps"><article class="step"><b>۰۱</b><h3>دریافت اطلاعات دسترسی</h3><p>حساب کاربری از سوی مسئول فضای کاری یا تیم پشتیبانی ایجاد می‌شود.</p></article><article class="step"><b>۰۲</b><h3>ورود به فضای شخصی</h3><p>با نام کاربری و رمز صادرشده وارد شوید تا فایل‌های مرتبط را ببینید.</p></article><article class="step"><b>۰۳</b><h3>ارسال یا دریافت فایل</h3><p>پس از ورود، فایل‌ها را در چارچوب سطح دسترسی مشخص‌شده مدیریت کنید.</p></article></div></div></section><section id="faq"><div class="wrap faq"><div class="intro-block"><span class="eyebrow">پرسش‌های رایج</span><h2 class="section-title">پیش از ورود بدانید</h2></div><div class="qa"><h3>آیا برای استفاده باید ثبت‌نام کنم؟</h3><p>خیر. دسترسی به CloudF با حساب‌های دعوت‌شده انجام می‌شود و ثبت‌نام عمومی ندارد.</p></div><div class="qa"><h3>اگر نام کاربری یا رمز عبور ندارم چه کار کنم؟</h3><p>برای دریافت اطلاعات دسترسی با مسئول سازمان یا فرستنده دعوت‌نامه خود تماس بگیرید.</p></div><div class="qa"><h3>آیا فرم ورود اطلاعات را ارسال می‌کند؟</h3><p>خیر. این صفحه صرفاً راهنمای ورود است و اطلاعات واردشده را ذخیره یا ارسال نمی‌کند.</p></div></div></section><section class="closing"><div class="wrap"><h2>برای دریافت دسترسی سازمانی با ما در ارتباط باشید.</h2><p>درخواست‌های مربوط به ایجاد فضای کاری و اطلاعات تکمیلی بررسی می‌شوند.</p><a href="mailto:sales@cloudf.ir">sales@cloudf.ir</a></div></section></main><footer class="footer"><div class="wrap footer-row"><span>© ۲۰۲۶ CloudF. تمامی حقوق محفوظ است.</span><span class="footer-links"><a href="/about/">درباره ما</a><a href="/status/">وضعیت خدمات</a><a href="/terms/">شرایط استفاده</a><a href="/privacy/">حریم خصوصی</a></span></div></footer><script>document.getElementById('access-form').addEventListener('submit',function(e){e.preventDefault();document.getElementById('password').value='';var m=document.getElementById('access-message');m.textContent='ورود در این صفحه فعال نیست. برای دریافت حساب کاربری با مسئول سازمان خود تماس بگیرید.';m.classList.add('show')});</script></body></html>
HTML
sed -i "s/sales@cloudf\\.ir/sales@${BASE_DOMAIN}/g" "$WEB_ROOT/index.html"

cat >"$WEB_ROOT/404.html" <<'HTML'
<!doctype html><html lang="fa" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>صفحه پیدا نشد | CloudF</title><body style="margin:10%;font:18px Tahoma,Arial;color:#15242d"><h1>این صفحه پیدا نشد.</h1><p><a href="/">بازگشت به صفحه اصلی CloudF</a></p></body></html>
HTML
cat >"$WEB_ROOT/robots.txt" <<'TXT'
User-agent: *
Allow: /
TXT
cat >"$WEB_ROOT/sitemap.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://${WEB_DOMAIN}/</loc></url></urlset>
EOF

# Compact Persian auxiliary pages; the home page never leads a visitor to an
# unimplemented route.
for page in about docs status privacy terms; do
  title='اطلاعات CloudF'
  case "$page" in about) title='درباره CloudF';; docs) title='راهنمای خدمات';; status) title='وضعیت خدمات';; privacy) title='حریم خصوصی';; terms) title='شرایط استفاده';; esac
  cat >"$WEB_ROOT/$page/index.html" <<EOF
<!doctype html><html lang="fa" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><body style="max-width:760px;margin:8% auto;padding:0 24px;font:16px/2 Tahoma,Arial;color:#15242d"><h1>${title}</h1><p>اطلاعات این بخش برای کاربران CloudF منتشر شده است. برای دریافت اطلاعات تکمیلی با مسئول فضای کاری خود تماس بگیرید.</p><p><a href="/">بازگشت به صفحه اصلی</a></p></body></html>
EOF
done
find "$WEB_ROOT" -type d -exec chmod 0755 {} +
find "$WEB_ROOT" -type f -exec chmod 0644 {} +
chown -R root:root "$WEB_ROOT"

log 'Staging Nginx configuration'
cat >"$HTTP_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${BASE_DOMAIN} ${WEB_DOMAIN};
    root ${WEB_ROOT};
    index index.html;
    server_tokens off;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml application/xml;
    gzip_min_length 512;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    location = /404.html { internal; }
    error_page 404 /404.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

cat >"$HTTPS_CONF" <<EOF
server {
    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;
    server_name ${BASE_DOMAIN} ${WEB_DOMAIN};
    root ${WEB_ROOT};
    index index.html;
    server_tokens off;
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml application/xml;
    gzip_min_length 512;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    location ^~ ${XRAY_PATH} {
        proxy_pass https://127.0.0.1:443;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_server_name on;
        proxy_ssl_name ${XRAY_NAME};
        proxy_ssl_protocols TLSv1.3;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
    location = /404.html { internal; }
    error_page 404 /404.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
ln -sfn "$HTTP_CONF" "$HTTP_LINK"
ln -sfn "$HTTPS_CONF" "$HTTPS_LINK"

if ! nginx -t; then
  log 'Nginx validation failed; restoring Nginx files and leaving services unchanged'
  restore_nginx
  fail "Nginx rejected the generated configuration. Backups remain in $BACKUP_DIR"
fi

log 'Reloading Nginx after successful validation'
if ! systemctl reload nginx; then
  restore_nginx
  fail 'Nginx could not reload the generated configuration. The previous configuration was restored.'
fi
if ! curl --fail --silent --show-error --resolve "${WEB_DOMAIN}:8443:127.0.0.1" "https://${WEB_DOMAIN}:8443/" -o /tmp/cloudf-web-setup-check.html; then
  restore_nginx
  fail 'The staged HTTPS website check failed. The previous Nginx configuration was restored.'
fi
if ! grep -q 'ارسال امن فایل' /tmp/cloudf-web-setup-check.html; then
  restore_nginx
  fail 'The staged HTTPS website returned unexpected content. The previous Nginx configuration was restored.'
fi

log 'Installing the persistent public HTTPS redirect'
cat >"$REDIRECT_UNIT" <<EOF
[Unit]
Description=Redirect public HTTPS to the CloudF Nginx frontend
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/iptables -t nat -D PREROUTING -i ${WAN_IF} -p tcp --dport 443 -j REDIRECT --to-ports 8443
ExecStart=/usr/sbin/iptables -t nat -A PREROUTING -i ${WAN_IF} -p tcp --dport 443 -j REDIRECT --to-ports 8443
ExecStop=-/usr/sbin/iptables -t nat -D PREROUTING -i ${WAN_IF} -p tcp --dport 443 -j REDIRECT --to-ports 8443

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cloudf-https-redirect.service >/dev/null
systemctl restart cloudf-https-redirect.service

systemctl is-active --quiet nginx
systemctl is-active --quiet x-ui
systemctl is-active --quiet cloudf-https-redirect.service
iptables -t nat -C PREROUTING -i "$WAN_IF" -p tcp --dport 443 -j REDIRECT --to-ports 8443

log 'Completed successfully'
printf 'Website: https://%s/\nXHTTP path preserved: %s\nBackup: %s\n' "$WEB_DOMAIN" "$XRAY_PATH" "$BACKUP_DIR"
printf 'Xray was not restarted or reconfigured. Test the public URL from a separate network before relying on it.\n'
