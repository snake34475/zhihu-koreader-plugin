"""Verify and hand off the user's own Zhihu browser session to a PW4.

Cookie input is hidden, sent only through SSH stdin, and staged on the Kindle's
RAM-backed /tmp for ten minutes. No Cookie is written to this computer.
"""
from __future__ import annotations

import base64
import getpass
import os
import subprocess
import sys
import tempfile
import time


DEVICE_HOST = os.environ.get("ZHIHU_DEVICE_HOST", "192.168.31.104")
DEVICE_PORT = os.environ.get("ZHIHU_DEVICE_PORT", "2222")
REMOTE_LUA = "/tmp/zhihu-cookie-import-verify.lua"
REMOTE_IMPORT = "/tmp/zhihu-cookie-import"
IMPORT_TTL_SECONDS = 600
COOKIE_NAMES = {"_xsrf", "_zap", "d_c0", "BEC", "sec_token", "z_c0"}

LUA = r'''require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):wrap({ language = "zh_CN" })
require("gettext").changeLang("zh_CN")
local cookie = io.read("*l") or ""
cookie = cookie:gsub("^%s*Cookie:%s*", "")
if cookie == "" or #cookie > 16384 or cookie:find("[%c]") then
    print("PROBE_SESSION_VERIFY result=invalid_cookie")
    return
end
local json = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local chunks = {}
local headers = {
    ["User-Agent"] = "Zhihu-KOReader/0.3 (user-initiated reader)",
    ["Accept"] = "application/json",
    ["Cookie"] = cookie,
}
socketutil:set_timeout(12, 18)
local ok, success, status, response_headers = pcall(http.request, {
    url = "https://www.zhihu.com/api/v4/me", method = "GET", redirect = false,
    headers = headers, sink = ltn12.sink.table(chunks),
})
headers.Cookie = nil
local body = table.concat(chunks)
local location = response_headers and (response_headers.location or response_headers.Location) or ""
local challenged = tostring(location):find("/account/unhuman", 1, true) ~= nil
    or body:find("/account/unhuman", 1, true) ~= nil
    or body:find("人机验证", 1, true) ~= nil
    or body:find("40352", 1, true) ~= nil
    or body:find("40362", 1, true) ~= nil
if challenged then
    print("PROBE_SESSION_VERIFY status=" .. tostring(status or "unknown") .. " result=verification_required")
    return
end
if not ok or not success then
    print("PROBE_SESSION_VERIFY status=network_error")
    return
end
if tonumber(status) ~= 200 then
    print("PROBE_SESSION_VERIFY status=" .. tostring(status) .. " result=login_required_or_denied")
    return
end
local decoded, profile = pcall(json.decode, body)
local valid = decoded and type(profile) == "table"
    and (profile.id ~= nil or profile.url_token ~= nil or profile.name ~= nil or profile.name_cn ~= nil)
if not valid then
    print("PROBE_SESSION_VERIFY status=200 profile_valid=false")
    return
end

local import_path = "/tmp/zhihu-cookie-import"
local temporary_path = import_path .. ".tmp"
os.remove(temporary_path)
local file = io.open(temporary_path, "wb")
if not file then
    print("PROBE_SESSION handoff=failed")
    return
end
local written = file:write(tostring(os.time()), "\n", cookie, "\n")
local closed = file:close()
local chmod_ok = false
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
    pcall(ffi.cdef, "int chmod(const char *pathname, unsigned int mode);")
    local called, result = pcall(function() return ffi.C.chmod(temporary_path, 384) end)
    chmod_ok = called and result == 0
end
if not written or not closed or not chmod_ok then
    os.remove(temporary_path)
    print("PROBE_SESSION handoff=failed")
    return
end
os.remove(import_path)
if not os.rename(temporary_path, import_path) then
    os.remove(temporary_path)
    print("PROBE_SESSION handoff=failed")
    return
end
print("PROBE_SESSION_VERIFY status=200 profile_valid=true")
print("PROBE_SESSION handoff=ready expires_seconds=600")
cookie, body, profile = nil, nil, nil
'''


def normalize_cookie(header: str) -> str:
    if header[:7].lower() == "cookie:":
        header = header[7:].strip()
    if not header or len(header) > 16384 or any(ord(ch) < 32 or ord(ch) == 127 for ch in header):
        raise ValueError("Cookie 为空、过长或包含换行")
    jar: dict[str, str] = {}
    for pair in header.split(";"):
        if "=" not in pair:
            continue
        name, value = pair.strip().split("=", 1)
        name, value = name.strip(), value.strip()
        if name in COOKIE_NAMES and value and len(value) <= 4096:
            jar[name] = value
    if "z_c0" not in jar:
        raise ValueError("Cookie 中没有 z_c0 登录凭据")
    return "; ".join(f"{name}={jar[name]}" for name in sorted(jar))


def make_empty_password_askpass() -> str:
    descriptor, path = tempfile.mkstemp(prefix="zhihu-ssh-askpass-")
    with os.fdopen(descriptor, "w", encoding="utf-8") as script:
        script.write("#!/bin/sh\nexit 0\n")
    os.chmod(path, 0o700)
    return path


def main() -> int:
    try:
        port = int(DEVICE_PORT)
        if not 1 <= port <= 65535:
            raise ValueError
    except ValueError:
        print("ERROR: ZHIHU_DEVICE_PORT must be between 1 and 65535", file=sys.stderr)
        return 2

    cookie = getpass.getpass("Paste browser Cookie header value (input hidden; do not paste it into chat): ").strip()
    try:
        cookie = normalize_cookie(cookie)
    except ValueError as exc:
        print("ERROR: " + str(exc) + "; nothing was sent to the Kindle")
        return 2

    encoded_lua = base64.b64encode(LUA.encode("utf-8")).decode("ascii")
    remote_command = (
        "umask 077; printf '%s' '" + encoded_lua + "' | base64 -d > " + REMOTE_LUA
        + " && cd /mnt/us/koreader && ./luajit " + REMOTE_LUA
    )
    askpass = make_empty_password_askpass()
    env = os.environ.copy()
    env.update({"SSH_ASKPASS": askpass, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"})
    command = [
        "ssh", "-p", str(port), "-o", "PubkeyAuthentication=no",
        "-o", "PreferredAuthentications=password", "-o", "NumberOfPasswordPrompts=1",
        "-o", "ConnectTimeout=8", f"root@{DEVICE_HOST}", remote_command,
    ]
    try:
        result = subprocess.run(command, input=(cookie + "\n").encode("utf-8"),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=45, env=env, check=False)
    except subprocess.TimeoutExpired:
        print("ERROR: timed out while checking the Kindle session; no response body was collected")
        return 1
    except OSError as exc:
        print("ERROR: could not start OpenSSH (" + type(exc).__name__ + ")")
        return 1
    finally:
        try:
            os.unlink(askpass)
        except OSError:
            pass
        cookie = "\0" * len(cookie)

    stdout = result.stdout.decode("utf-8", "replace")
    lines = [line for line in stdout.splitlines()
             if line.startswith("PROBE_SESSION_VERIFY ") or line.startswith("PROBE_SESSION ")]
    for line in lines:
        print(line)
    if result.returncode != 0:
        print("ERROR: SSH failed; check that the Kindle is reachable and its host key is trusted")
        return 1
    if lines != ["PROBE_SESSION_VERIFY status=200 profile_valid=true",
                 "PROBE_SESSION handoff=ready expires_seconds=600"]:
        return 1
    print("Next: KOReader → 知乎 → 设置 → 导入电脑临时传入的浏览器会话")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
