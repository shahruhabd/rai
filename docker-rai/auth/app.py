# -*- coding: utf-8 -*-
import os, re, ssl, json, logging, datetime as dt
from flask import Flask, request, render_template, redirect, make_response, g
from ldap3 import Server, Connection, ALL, NTLM, SIMPLE, ALL_ATTRIBUTES, Tls
from ldap3.utils.conv import escape_filter_chars
import requests
import base64
from zoneinfo import ZoneInfo
import time
from functools import lru_cache
from functools import wraps

APP_TZ = os.environ.get("APP_TZ", "Asia/Almaty")
TZ = ZoneInfo(APP_TZ)

from sqlalchemy import create_engine, Column, Integer, String, DateTime, Boolean, Text, text
from sqlalchemy.orm import sessionmaker, declarative_base
# from flask_sqlalchemy import SQLAlchemy

_IDM_UID_CACHE = {}          # sam -> (uid_dep, ts)
_IDM_ALLOW_CACHE = {}        # uid_dep -> (bool_allowed, ts)
_IDM_TTL = 600               # 10 минут

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET", "change_me")

BASE_DIR = os.path.abspath(os.path.dirname(__file__))
db_path = os.path.join(BASE_DIR, "data", "users.db")

# убедимся что папка есть
os.makedirs(os.path.dirname(db_path), exist_ok=True)

app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_path}"
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

# db = SQLAlchemy(app)

# ==== LDAP ====
LDAP_SERVER_URI    = os.environ.get("LDAP_SERVER_URI")
LDAP_BIND_DN       = os.environ.get("LDAP_BIND_DN")
LDAP_BIND_PASSWORD = os.environ.get("LDAP_BIND_PASSWORD")
LDAP_SEARCH_BASE   = (os.environ.get("LDAP_SEARCH_BASE") or "").strip()
LDAP_SEARCH_BASE   = re.sub(r'\s*,\s*', ',', LDAP_SEARCH_BASE)

# ==== Cookies ====
COOKIE_NAME   = "r_ai_session"
COOKIE_DOMAIN = None
COOKIE_SECURE = os.environ.get("COOKIE_SECURE", "1") == "1"

# ==== БД ====
# Пример: PostgreSQL  postgres://user:pass@host:5432/dbname
# Либо SQLite: sqlite:////data/r_ai.db
DB_URL = "sqlite:////app/data/r_ai.db"
engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)
Base = declarative_base()

# ==== requests.Session с тайм-аутами/ретраями ====
HTTP_BASE = os.environ.get("IDM_BASE")  # базовый URL вашего AppServer
HTTP_USER = os.environ.get("IDM_USER")
HTTP_PASS = os.environ.get("IDM_PASS")
HTTP_VERIFY = os.environ.get("HTTP_VERIFY", "0") == "1"          # или путь к CA: /etc/ssl/certs/ca.crt

def verify_sso_token(token: str):
    """
    Токен от Django: urlsafe base64(JSON)
    """
    try:
        decoded = base64.urlsafe_b64decode(token.encode()).decode()
        data = json.loads(decoded)

        username = (data.get("username") or "").strip()
        expires_str = data.get("expires")

        if not username or not expires_str:
            return None, "invalid"

        expires = dt.datetime.fromisoformat(expires_str)
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=TZ)

        now = dt.datetime.now(TZ)
        if now > expires:
            return data, "expired"

        return data, "active"

    except Exception:
        logging.exception("Failed to verify SSO token")
        return None, "invalid"


@app.get("/sso-login")
def sso_login():
    token = request.args.get("session_token")
    nxt = request.args.get("next") or "/rai/ares/"

    if not token:
        return redirect("/login?next=" + nxt)

    data, status = verify_sso_token(token)
    if status != "active" or not data:
        return redirect("/login?next=" + nxt)

    username_norm = (data.get("username") or "").strip().lower()

    # --- апсерт профиля БЕЗ ALLOWED_DEPTS ---
    try:
        s = db()
        user = s.query(User).filter(User.username == username_norm).one_or_none()
        now = now_local()
        if not user:
            user = User(username=username_norm)
            s.add(user)

        # сначала берём из токена, при отсутствии — из LDAP
        attrs = {}
        try:
            _, attrs = find_user_dn_and_attrs(username_norm)
        except Exception:
            logging.exception("LDAP attrs fetch failed in sso_login")

        def from_token_or_ldap(field_token, field_ldap):
            return data.get(field_token) or attrs.get(field_ldap)

        user.employee_id       = from_token_or_ldap("employee_id", "employeeID") or user.employee_id
        user.first_name        = from_token_or_ldap("first_name", "givenName")   or user.first_name
        user.last_name         = from_token_or_ldap("last_name", "sn")           or user.last_name
        user.title             = from_token_or_ldap("title", "title")            or user.title
        user.department        = from_token_or_ldap("department", "department")  or user.department
        user.telephone_number  = attrs.get("telephoneNumber") or user.telephone_number
        user.mail              = attrs.get("mail") or user.mail
        user.last_login_at     = now
        user.last_seen_at      = now

        s.commit()
    except Exception:
        s.rollback()
        logging.exception("upsert_user_profile (SSO) failed")

    # логируем событие "login" — у тебя уже есть
    write_session_event(username_norm, "login")

    resp = make_response(redirect(nxt if nxt.startswith("/") else "/rai/ares/"))
    set_session(resp, username_norm)
    return resp

def _get_cache(dct, key):
    v = dct.get(key)
    if not v: return None
    val, ts = v
    if time.time() - ts > _IDM_TTL:
        dct.pop(key, None)
        return None
    return val

def _put_cache(dct, key, val):
    dct[key] = (val, time.time())

def resolve_uid_department_for_sam_cached(sam: str) -> str | None:
    sam_l = (sam or "").lower()
    hit = _get_cache(_IDM_UID_CACHE, sam_l)
    if hit is not None:
        return hit
    s = get_http()
    idm_authenticate(s)
    # здесь лучше иметь API-фильтр по CentralAccount, но оставляем как есть
    persons = idm_persons(s, sam_l)
    uid = None
    for p in persons:
        vals = p.get("values") or {}
        if (vals.get("PersonnelNumber") or "").lower() == sam_l:
            uid = vals.get("UID_Department")
            break
    _put_cache(_IDM_UID_CACHE, sam_l, uid)
    return uid

def is_allowed_department_cached(uid_dep: str | None) -> bool:
    if not uid_dep:
        return False
    hit = _get_cache(_IDM_ALLOW_CACHE, uid_dep)
    if hit is not None:
        return hit
    s = get_http()
    idm_authenticate(s)
    deps = idm_departments(s, uid_dep)
    allowed = False
    for d in deps:
        vals = d.get("values") or {}
        if vals.get("UID_Department") == uid_dep:
            parent = vals.get("UID_ParentDepartment")
            allowed = (uid_dep in ALLOWED_DEPTS) or (parent in ALLOWED_DEPTS)
            break
    _put_cache(_IDM_ALLOW_CACHE, uid_dep, allowed)
    return allowed


def now_local():
    return dt.datetime.now(TZ)

def get_http():
    s = getattr(g, "_http", None)
    if s is None:
        s = requests.Session()
        s.verify = HTTP_VERIFY
        s.headers.update({"Content-Type": "application/json", "Accept": "application/json"})
        g._http = s
    return s

@app.teardown_appcontext
def _close_http(_exc):
    s = getattr(g, "_http", None)
    if s is not None:
        s.close()

# ==== Модели ====

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username           = Column(String(150), unique=True, index=True, nullable=False)   # sAMAccountName
    first_name         = Column(String(150))
    last_name          = Column(String(150))
    title              = Column(String(250))
    department         = Column(String(250))
    telephone_number   = Column(String(100))
    mail               = Column(String(250))
    uid_department     = Column(String(64))   # из внешней системы
    created_at         = Column(DateTime, default=now_local)
    last_login_at      = Column(DateTime)
    last_logout_at     = Column(DateTime)
    last_seen_at       = Column(DateTime)
    is_active          = Column(Boolean, default=True)
    employee_id        = Column(String(50))

class SessionLog(Base):
    __tablename__ = "session_logs"
    id = Column(Integer, primary_key=True)
    username   = Column(String(150), index=True)
    event      = Column(String(20))      # 'login' / 'logout'
    ip         = Column(String(64))
    user_agent = Column(Text)
    created_at = Column(DateTime, default=now_local)

Base.metadata.create_all(engine)


ALLOWED_DEPTS = {
    # доступ разрешён, если UID_Department ИЛИ UID_ParentDepartment == одному из этих
    "d729a5ec-4eab-48a0-936c-fb214ff5026f", # ДБР
    "3a5cbd6a-93b5-4d82-a58f-5177adbe2fc8", # Унт
    'd3a9e75e-b17b-4fe0-8f7f-a7a0ca42097b' # Руководство
}

def get_ldap_server():
    if LDAP_SERVER_URI.lower().startswith("ldaps://"):
        tls = Tls(validate=ssl.CERT_NONE)
        return Server(LDAP_SERVER_URI, use_ssl=True, get_info=ALL, tls=tls)
    return Server(LDAP_SERVER_URI, get_info=ALL)

def service_bind():
    server = get_ldap_server()
    if "\\" in LDAP_BIND_DN:
        return Connection(server, user=LDAP_BIND_DN, password=LDAP_BIND_PASSWORD,
                          authentication=NTLM, auto_bind=True)
    else:
        return Connection(server, user=LDAP_BIND_DN, password=LDAP_BIND_PASSWORD,
                          authentication=SIMPLE, auto_bind=True)

def find_user_dn(sam: str) -> str | None:
    with service_bind() as conn:
        safe_user = escape_filter_chars(sam)
        filt = f"(sAMAccountName={safe_user})"
        if not conn.search(LDAP_SEARCH_BASE, filt, attributes=ALL_ATTRIBUTES, size_limit=1):
            return None
        if not conn.entries:
            return None
        return conn.entries[0].entry_dn

def find_user_dn_and_attrs(sam: str) -> tuple[str | None, dict]:
    conn = get_service_conn()
    safe_user = escape_filter_chars(sam)
    filt = f"(sAMAccountName={safe_user})"
    ok = conn.search(
        LDAP_SEARCH_BASE, filt,
        attributes=['givenName','sn','title','department','telephoneNumber','mail','sAMAccountName', 'employeeID'],
        size_limit=1
    )
    if not ok or not conn.entries:
        return None, {}
    e = conn.entries[0]
    attrs = {}
    for a in ['givenName','sn','title','department','telephoneNumber','mail','sAMAccountName', 'employeeID']:
        try:
            v = getattr(e, a).value
            attrs[a] = str(v) if v is not None else None
        except Exception:
            attrs[a] = None
    return e.entry_dn, attrs

def verify_user_password(user_dn: str, password: str) -> bool:
    try:
        srv = get_ldap_server_obj()
        with Connection(srv, user=user_dn, password=password, authentication=SIMPLE, auto_bind=True):
            return True
    except Exception:
        return False

# ===== Внешний IDM =====
def idm_authenticate(session: requests.Session) -> None:
    url = f"{HTTP_BASE}/AppServer/auth/apphost"
    payload = {"authString": f"Module=DialogUser;User={HTTP_USER};Password={HTTP_PASS}"}
    r = session.post(url, data=json.dumps(payload), timeout=7)  # было 10
    r.raise_for_status()

def idm_persons(session: requests.Session, pn: str) -> list[dict]:
    pn = pn.strip()
    url = f"{HTTP_BASE}/AppServer/api/entities/Person"
    params = {
        "where": f"PersonnelNumber='{pn}'",
        "loadType": "BulkReadOnly"
    }
    r = session.get(url, params=params, timeout=7)
    r.raise_for_status()
    return r.json()

def idm_departments(session: requests.Session, pn: str) -> list[dict]:
    pn = pn.strip()
    url = f"{HTTP_BASE}/AppServer/api/entities/Department"
    params = {
        "where": f"UID_Department='{pn}'",
        "loadType": "BulkReadOnly"
    }
    r = session.get(url, params=params, timeout=7)
    r.raise_for_status()
    return r.json()

def is_allowed_department(uid_dep: str | None) -> bool:
    if not uid_dep:
        return False
    s = get_http()
    idm_authenticate(s)
    deps = idm_departments(s, uid_dep)
    for d in deps:
        vals = d.get("values") or {}
        if vals.get("UID_Department") == uid_dep:
            parent = vals.get("UID_ParentDepartment")
            return (uid_dep in ALLOWED_DEPTS) or (parent in ALLOWED_DEPTS)
    # Если в базе нет такого департамента — считаем, что доступ не разрешён
    return False


@app.after_request
def no_cache(resp):
    resp.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    resp.headers["Pragma"]        = "no-cache"
    resp.headers["Expires"]       = "0"
    return resp

def set_session(resp, username: str):
    # храним в куке уже нормализованное имя
    username = (username or "").strip().lower()
    resp.set_cookie(
        COOKIE_NAME, username,
        max_age=60*60*8,
        httponly=True,
        path="/",
        secure=COOKIE_SECURE,
        samesite="Lax",
        domain=COOKIE_DOMAIN
    )

def clear_session(resp):
    resp.delete_cookie(COOKIE_NAME, domain=COOKIE_DOMAIN, path="/")


def db():
    if not hasattr(g, "_db"):
        g._db = SessionLocal()
    return g._db

@app.teardown_appcontext
def close_db(_exc):
    s = getattr(g, "_db", None)
    if s is not None:
        s.close()

def write_session_event(username: str, event: str):
    username = (username or "").strip().lower()
    try:
        rec = SessionLog(
            username=username,
            event=event,
            ip=request.headers.get("X-Forwarded-For", request.remote_addr),
            user_agent=request.headers.get("User-Agent", "")
        )
        db().add(rec)
        db().commit()
    except Exception:
        db().rollback()
        logging.exception("Failed to write session log")

def upsert_user_profile(username: str, ldap_attrs: dict, uid_dep: str | None):
    username = (username or "").strip().lower()
    s = db()
    user = s.query(User).filter(User.username == username).one_or_none()
    now = now_local()
    user.last_login_at = now
    user.last_seen_at  = now

    if not user:
        user = User(username=username)
        s.add(user)
    # ... остальное без изменений ...
    try:
        s.commit()
    except Exception:
        s.rollback()
        logging.exception("Failed to upsert user")

def ldap_attrs_for_user(user_dn: str) -> dict:
    # читаем некоторые атрибуты
    with service_bind() as conn:
        if not conn.search(user_dn, '(objectClass=*)',
                           attributes=['givenName','sn','title','department','telephoneNumber','mail','sAMAccountName'],
                           search_scope='BASE'):
            return {}
        e = conn.entries[0]
        as_dict = {}
        for a in ['givenName','sn','title','department','telephoneNumber','mail','sAMAccountName']:
            try:
                as_dict[a] = str(getattr(e, a).value) if getattr(e, a).value is not None else None
            except Exception:
                as_dict[a] = None
        return as_dict


def get_ldap_server_obj():
    srv = getattr(g, "_ldap_server", None)
    if srv is None:
        if LDAP_SERVER_URI.lower().startswith("ldaps://"):
            tls = Tls(validate=ssl.CERT_NONE)
            srv = Server(LDAP_SERVER_URI, use_ssl=True, get_info=ALL, tls=tls)
        else:
            srv = Server(LDAP_SERVER_URI, get_info=ALL)
        g._ldap_server = srv
    return srv

def get_service_conn():
    conn = getattr(g, "_ldap_service_conn", None)
    if conn is None or not conn.bound:
        srv = get_ldap_server_obj()
        if "\\" in LDAP_BIND_DN:
            conn = Connection(srv, user=LDAP_BIND_DN, password=LDAP_BIND_PASSWORD, authentication=NTLM, auto_bind=True)
        else:
            conn = Connection(srv, user=LDAP_BIND_DN, password=LDAP_BIND_PASSWORD, authentication=SIMPLE, auto_bind=True)
        g._ldap_service_conn = conn
    return conn

def close_ldap_conn(_exc=None):
    c = getattr(g, "_ldap_service_conn", None)
    if c:
        try: c.unbind()
        except: pass

app.teardown_appcontext(close_ldap_conn)


@app.post("/sync-user/")
def sync_user():
    data = request.json
    if not data:
        return {"error": "No JSON data"}, 400

    action = data.get("action")
    logging.warning(f"PROVERKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA: {action}")
    if action == "grant":
        username = (data.get("username") or "").strip().lower()
        if not username:
            return {"error": "username is required"}, 400

        employee_id = data.get("employee_id")
        first_name = data.get("first_name")
        last_name = data.get("last_name")
        department = data.get("department")
        title = data.get("title")

        try:
            logging.warning(f"Connecting to DB: {DB_URL}")
            s = db()
            user = s.query(User).filter(User.username == username).one_or_none()
            if not user:
                user = User(username=username)
                s.add(user)

            user.employee_id = employee_id or user.employee_id
            user.first_name = first_name or user.first_name
            user.last_name = last_name or user.last_name
            user.department = department or user.department
            user.title = title or user.title
            user.is_active = True

            s.commit()
            logging.warning(f"sync-user grant success: username={username}, id={user.id}")

            # Verification
            try:
                with engine.connect() as conn:
                    result = conn.execute(text("SELECT id FROM users WHERE id = :uid"), {"uid": user.id}).fetchall()
                    if result:
                        logging.warning(f"found in DB via engine. 123: {result}")
                    else:
                        logging.error(f"VERIFICATION FAILED: User {user.id} NOT found in DB via engine!")
            except Exception as ve:
                logging.error(f"Verification error: {ve}")

            return {"status": "granted"}, 200
        except Exception as e:
            s.rollback()
            logging.exception("sync-user grant failed")
            return {"error": str(e)}, 500

    elif action == "revoke":
        employee_id = data.get("employee_id")
        if not employee_id:
             return {"error": "employee_id is required"}, 400

        try:
            s = db()
            # Revoke by employee_id
            users = s.query(User).filter(User.employee_id == employee_id).all()

            if not users:
                logging.warning(f"sync-user revoke: user with employee_id {employee_id} not found")
                return {"status": "user not found, considered revoked"}, 200

            for user in users:
                user.is_active = False

            s.commit()

            # Verification
            try:
                with engine.connect() as conn:
                    results = conn.execute(text("SELECT id, username, is_active FROM users WHERE employee_id = :eid"), {"eid": employee_id}).fetchall()
                    logging.warning(f"VERIFICATION REVOKE: Users with employee_id {employee_id}: {results}")
            except Exception as ve:
                logging.error(f"Verification error: {ve}")

            return {"status": "revoked"}, 200
        except Exception as e:
            s.rollback()
            logging.exception("sync-user revoke failed")
            return {"error": str(e)}, 500

    else:
        return {"error": "Invalid action"}, 400


@app.get("/login")
def login_get():
    nxt = request.args.get("next") or "/ares/"
    return render_template("login.html", error=None, next=nxt)

@app.post("/login")
def login_post():
    username = (request.form.get("username") or "").strip()
    password = request.form.get("password") or ""
    nxt = request.form.get("next") or "/ares/"

    # 1) базовая валидация
    if not username or not password:
        return render_template("login.html", error="Укажите логин и пароль.", next=nxt), 400

    # 2) ищем DN и сразу проверяем пароль
    try:
        user_dn, attrs = find_user_dn_and_attrs(username)
    except Exception:
        logging.exception("LDAP search failed")
        return render_template("login.html", error="Ошибка LDAP-поиска пользователя.", next=nxt), 502

    invalid_msg = "Неверный логин или пароль."
    if not user_dn:
        return render_template("login.html", error=invalid_msg, next=nxt), 401

    # 3) проверяем пароль (второй и последний LDAP-звонок)
    try:
        if not verify_user_password(user_dn, password):
            return render_template("login.html", error=invalid_msg, next=nxt), 401
    except Exception:
        logging.exception("LDAP bind (password check) failed")
        return render_template("login.html", error="Ошибка проверки пароля (LDAP).", next=nxt), 502

    # 4) проверка департамента — сначала быстрый путь из БД/кэша
    username_norm = username.lower()
    uid_dep = None
    try:
        u = db().query(User).filter(User.username == username_norm).one_or_none()

        if u and not u.is_active:
            return render_template("login.html", error="Доступ к системе отключен.", next=nxt), 403

        if u and u.uid_department:
            uid_dep = u.uid_department
            # быстрый кэш
            if not is_allowed_department_cached(uid_dep):
                return render_template("login.html", error="Доступ к системе не разрешён (департамент).", next=nxt), 403
        else:
            # кешируемое обращение в IDM
            uid_dep = resolve_uid_department_for_sam_cached(attrs['employeeID'])
            if not is_allowed_department_cached(uid_dep):
                return render_template("login.html", error="Доступ к системе не разрешён (департамент).", next=nxt), 403
    except Exception:
        logging.exception("IDM check failed")
        return render_template("login.html", error="Ошибка внешней проверки доступа (IDM).", next=nxt), 502

    # 5) апсерт профиля + логирование (исправлено создание/обновление)
    try:
        s = db()
        user = s.query(User).filter(User.username == username_norm).one_or_none()
        now = now_local()
        if not user:
            user = User(username=username_norm)
            s.add(user)
        user.uid_department = uid_dep or user.uid_department
        user.employee_id = attrs.get('employeeID') or user.employee_id
        user.first_name = attrs.get('givenName') or user.first_name
        user.last_name  = attrs.get('sn') or user.last_name
        user.title      = attrs.get('title') or user.title
        user.department = attrs.get('department') or user.department
        user.telephone_number = attrs.get('telephoneNumber') or user.telephone_number
        user.mail       = attrs.get('mail') or user.mail
        user.last_login_at = now
        user.last_seen_at  = now
        s.commit()
    except Exception:
        s.rollback()
        logging.exception("upsert_user_profile failed")

    write_session_event(username_norm, "login")


    # 6) устанавливаем куку и редирект
    resp = make_response(redirect(nxt if nxt.startswith("/") else "/ares/"))
    set_session(resp, username_norm)
    return resp


@app.get("/logout")
def logout():
    username = request.cookies.get(COOKIE_NAME) or ""
    write_session_event(username, "logout")
    # обновим last_logout
    try:
        u = db().query(User).filter(User.username == username).one_or_none()
        if u:
            u.last_logout_at = now_local()
            db().commit()
    except Exception:
        db().rollback()
        logging.exception("Failed to update last_logout_at")

    resp = make_response(redirect("https://dev-finai.finreg.kz/"))
    clear_session(resp)
    return resp


@app.get("/auth")
def auth_check():
    sess = current_user()
    if sess:
        try:
            u = db().query(User).filter(User.username == sess).one_or_none()
            if u:
                u.last_seen_at = now_local()
                db().commit()
        except Exception:
            db().rollback()
        return ("OK", 200)
    logging.warning("auth_check: no valid session")
    return ("Unauthorized", 401)

# ---- настройки access control для аналитики ----
ALLOWED_ANALYTICS = {
    "timur.abilkassymov",
    "alisher.tleukenov",
    "kamila.abdulkarimova",
    "aizhan.shalabayeva",
}

ALLOWED_ANALYTICS_EMPLOYEE_IDS = {"873227577304", #Alisher
                                  "429393655759" # Timur
                                  "759126635438" # Kamila
                                  "707175518788" # Aizhan
                                  }

def current_user():
    u = request.cookies.get(COOKIE_NAME)
    return (u or "").strip().lower()

def login_required(f):
    @wraps(f)
    def wrap(*args, **kwargs):
        if not current_user():
            return redirect("/login?next=" + request.path)
        return f(*args, **kwargs)
    return wrap

def analytics_required(f):
    @wraps(f)
    def wrap(*args, **kwargs):
        u = current_user()
        if not u:
            return redirect("/login?next=" + request.path)
        if u not in ALLOWED_ANALYTICS:
            return ("Forbidden", 403)
        return f(*args, **kwargs)
    return wrap


@app.get("/whoami")
def whoami():
    u = current_user()
    return {"username": current_user(), "can_analytics": bool(u in ALLOWED_ANALYTICS)}


@app.get("/auth/whoami")
def whoami_ext():
    u = (current_user() or "").strip().lower()

    emp_id = None
    try:
        rec = db().query(User).filter(User.username == u).one_or_none()
        if rec:
            emp_id = (rec.employee_id or "").strip()
    except Exception:
        db().rollback()

    can = bool(emp_id in ALLOWED_ANALYTICS_EMPLOYEE_IDS)

    return {
        "username": u,
        "employee_id": emp_id,
        "can_analytics": can,
    }


@app.get("/analytics")
def analytics():
    u = current_user()

    # последние 100 событий
    logs = (
        db().query(SessionLog)
        .order_by(SessionLog.created_at.desc())
        .limit(100)
        .all()
    )

    # сводка по каждому пользователю: последние логин/логаут
    from sqlalchemy import func
    users = (
        db().query(User)
        .order_by(User.last_seen_at.desc().nullslast())
        .limit(100)
        .all()
    )

    return render_template(
        "analytics.html",
        me=u,
        logs=logs,
        users=users,
    )
