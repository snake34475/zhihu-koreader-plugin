"""Read-only PW4 probe for Zhihu web hot, recommendation, and question feeds.

The user's own Cookie is entered with hidden input, forwarded only over SSH
stdin, used in PW4 memory, and never written to a file or printed.
"""
from __future__ import annotations

import getpass
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PW4_TOOLS = ROOT.parent / "pw4-android" / "tools"
REMOTE_LUA = "/tmp/zhihu-feed-probe.lua"
COOKIE_NAMES = {"_xsrf", "_zap", "d_c0", "BEC", "sec_token", "z_c0"}
QUESTION_ID = "2017210364081754127"

LUA = r'''require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):wrap({ language = "zh_CN" })
require("gettext").changeLang("zh_CN")
local cookie = io.read("*l") or ""
if cookie == "" or #cookie > 16384 or cookie:find("[%c]") then
    print("PROBE_INPUT result=invalid_cookie")
    return
end
local json = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local cookies = {}
for pair in cookie:gmatch("[^;]+") do
    local name, value = pair:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
    if name and value ~= "" and #value <= 4096 then cookies[name] = value end
end
local parts = {}
for name, value in pairs(cookies) do
    if name == "_xsrf" or name == "_zap" or name == "d_c0" or name == "BEC" or name == "sec_token" or name == "z_c0" then
        parts[#parts + 1] = name .. "=" .. value
    end
end
table.sort(parts)
cookie = table.concat(parts, "; ")
if not cookies.z_c0 then print("PROBE_INPUT result=missing_session_cookie") cookie = nil return end
local function get(path)
    local chunks = {}
    local headers = { ["User-Agent"] = "Zhihu-KOReader/0.3 (user-initiated reader)",
        ["Accept"] = "application/json", ["Cookie"] = cookie,
        ["Referer"] = "https://www.zhihu.com/" }
    if cookies._xsrf then headers["x-xsrftoken"] = cookies._xsrf end
    socketutil:set_timeout(12, 18)
    local ok, success, status, response_headers = pcall(http.request, {
        url = "https://www.zhihu.com" .. path, method = "GET", redirect = false,
        headers = headers, sink = ltn12.sink.table(chunks),
    })
    headers.Cookie = nil
    local body = table.concat(chunks)
    if not ok or not success then return nil, nil, response_headers, "network_error" end
    local location = response_headers and (response_headers.location or response_headers.Location) or ""
    local challenged = tostring(location):find("/account/unhuman", 1, true) ~= nil
        or body:find("/account/unhuman", 1, true) ~= nil
        or body:find("人机验证", 1, true) ~= nil or body:find("40352", 1, true) ~= nil
        or body:find("40362", 1, true) ~= nil
    if challenged then return tonumber(status), nil, response_headers, "verification_required" end
    if tonumber(status) == 401 then return tonumber(status), nil, response_headers, "login_required" end
    if tonumber(status) == 403 then
        local decoded, payload = pcall(json.decode, body)
        local code = decoded and type(payload) == "table" and type(payload.error) == "table"
            and tonumber(payload.error.code)
        return tonumber(status), nil, response_headers, (code == 40352 or code == 40362)
            and "verification_required" or "forbidden_or_signature_required"
    end
    if tonumber(status) == 429 then return tonumber(status), nil, response_headers, "rate_limited" end
    if tonumber(status) ~= 200 then return tonumber(status), nil, response_headers, "http_error" end
    local decoded, payload = pcall(json.decode, body)
    body = nil
    if not decoded or type(payload) ~= "table" then return tonumber(status), nil, response_headers, "invalid_response" end
    return tonumber(status), payload, response_headers
end
local function inspect(label, path)
    local status, payload, headers, failure = get(path)
    if not payload then
        print(label .. " status=" .. tostring(status or failure or "network_error") .. " result=" .. tostring(failure or "network_error"))
        if failure == "verification_required" or failure == "login_required" then return false end
        return true
    end
    local data = payload.data
    local paging = payload.paging
    if type(data) ~= "table" then
        print(label .. " status=200 result=invalid_response")
        return true
    end
    local targets, answers, questions, excerpts, urls = 0, 0, 0, 0, 0
    for _, item in ipairs(data) do
        if type(item) == "table" then
            local target = type(item.target) == "table" and item.target or item
            targets = targets + (item.target ~= nil and 1 or 0)
            local kind = tostring(target.type or item.type or ""):lower()
            if kind == "answer" or kind == "answeritem" then answers = answers + 1 end
            if type(target.question) == "table" and type(target.question.title) == "string" then questions = questions + 1 end
            if type(target.excerpt) == "string" and target.excerpt ~= "" then excerpts = excerpts + 1 end
            if type(target.url) == "string" or type(target.url_token) == "string"
                or type(item.action) == "table" then urls = urls + 1 end
        end
    end
    local has_next = type(paging) == "table" and type(paging.next) == "string" and paging.next ~= ""
    local is_end = type(paging) == "table" and tostring(paging.is_end) or "missing"
    print(label .. " status=200 items=" .. #data .. " targets=" .. targets .. " answers=" .. answers
        .. " question_titles=" .. questions .. " excerpts=" .. excerpts .. " url_shapes=" .. urls
        .. " has_next=" .. tostring(has_next) .. " is_end=" .. is_end)
    payload = nil
    return true
end
local status, profile, _, failure = get("/api/v4/me")
if not profile then
    print("PROBE_SESSION status=" .. tostring(status or failure or "network_error") .. " result=" .. tostring(failure or "network_error"))
    cookie, cookies = nil, nil
    return
end
local valid = profile.id ~= nil or profile.url_token ~= nil or profile.name ~= nil or profile.name_cn ~= nil
print("PROBE_SESSION status=200 profile_valid=" .. tostring(valid == true))
profile = nil
if not valid then cookie, cookies = nil, nil return end
local proceed = inspect("PROBE_WEB_HOT", "/api/v3/feed/topstory/hot-lists/total?limit=30&desktop=true")
if proceed then proceed = inspect("PROBE_RECOMMEND", "/api/v3/feed/topstory/recommend?limit=10&desktop=true") end
if proceed then proceed = inspect("PROBE_QUESTION", "/api/v4/questions/2017210364081754127/feeds?limit=10&order=default&offset=0") end
cookie, cookies = nil, nil
'''


def normalize_cookie(header: str) -> str:
    if header[:7].lower() == "cookie:":
        header = header[7:].strip()
    if not header:
        raise ValueError("no Cookie value was received; nothing was sent to the device")
    if len(header) > 16384:
        raise ValueError("Cookie exceeds 16384 characters; nothing was sent to the device")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in header):
        raise ValueError("Cookie contains a line break or control character; paste it as one line")
    jar: dict[str, str] = {}
    for pair in header.split(";"):
        if "=" not in pair:
            continue
        name, value = pair.strip().split("=", 1)
        name, value = name.strip(), value.strip()
        if name in COOKIE_NAMES and value and len(value) <= 4096:
            jar[name] = value
    if "z_c0" not in jar:
        raise ValueError("Cookie has no z_c0 session value; nothing was sent to the device")
    return "; ".join(f"{name}={jar[name]}" for name in sorted(jar))


def ensure_paramiko() -> int | None:
    try:
        import paramiko  # noqa: F401
        return None
    except Exception:
        pass
    for python in (ROOT.parent / "pw4-android" / ".venv" / "Scripts" / "python.exe",
                   ROOT.parent / "pw4-android" / ".venv" / "bin" / "python"):
        if python.is_file() and python.resolve() != Path(sys.executable).resolve():
            print("SSH dependency missing in this Python; retrying with pw4-android virtualenv.")
            return subprocess.run([str(python), str(Path(__file__).resolve())], check=False).returncode
    return None


def main() -> int:
    if not PW4_TOOLS.is_dir():
        print("ERROR: PW4 research tools folder not found", file=sys.stderr)
        return 2
    retry = ensure_paramiko()
    if retry is not None:
        return retry
    try:
        cookie = normalize_cookie(getpass.getpass(
            "Paste your browser Cookie header value (input hidden; do not paste it into chat): "))
    except ValueError as exc:
        print("ERROR: " + str(exc), file=sys.stderr)
        return 2
    sys.path.insert(0, str(PW4_TOOLS))
    try:
        from lab import connect  # type: ignore
    except Exception as exc:
        print("ERROR: Paramiko/PW4 tools unavailable (" + type(exc).__name__ + ")", file=sys.stderr)
        return 2
    client = sftp = channel = None
    try:
        client = connect()
        sftp = client.open_sftp()
        with sftp.file(REMOTE_LUA, "w") as remote_file:
            remote_file.write(LUA)
        channel = client.get_transport().open_session(timeout=8)
        channel.settimeout(8)
        channel.exec_command("cd /mnt/us/koreader && ./luajit " + REMOTE_LUA)
        channel.sendall(cookie.encode("utf-8") + b"\n")
        channel.shutdown_write()
        output = bytearray()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if channel.recv_ready():
                output.extend(channel.recv(8192))
            if channel.exit_status_ready() and not channel.recv_ready():
                break
            time.sleep(0.05)
        if not channel.exit_status_ready():
            print("ERROR: probe timed out; no credential or response body was collected")
            return 1
        for line in output.decode("utf-8", "replace").splitlines():
            if line.startswith(("PROBE_", "ERROR")):
                print(line)
        if channel.recv_exit_status() != 0:
            print("ERROR: device probe exited abnormally")
            return 1
        return 0
    except Exception as exc:
        print("ERROR: feed probe failed (" + type(exc).__name__ + ")")
        return 1
    finally:
        cookie = "\0" * len(cookie)
        if channel is not None:
            channel.close()
        if sftp is not None:
            try:
                sftp.remove(REMOTE_LUA)
            except Exception:
                pass
            sftp.close()
        if client is not None:
            client.close()


if __name__ == "__main__":
    raise SystemExit(main())
