"""Verify and hand off the user's own Zhihu browser session to a PW4.

The Cookie is entered with hidden input, sent over SSH stdin, and only a
whitelisted subset is staged in the PW4 RAM-backed /tmp for ten minutes.
"""
from __future__ import annotations

import getpass
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PW4_TOOLS = ROOT.parent / "pw4-android" / "tools"
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
cookie = nil
local body = table.concat(chunks)
local location = response_headers and (response_headers.location or response_headers.Location) or ""
local challenged = tostring(location):find("/account/unhuman", 1, true) ~= nil
    or body:find("/account/unhuman", 1, true) ~= nil
    or body:find("人机验证", 1, true) ~= nil
    or body:find("40352", 1, true) ~= nil
    or body:find("40362", 1, true) ~= nil
if challenged then
    print("PROBE_SESSION_VERIFY status=" .. tostring(status or "unknown") .. " result=verification_required")
    body = nil
    return
end
if not ok or not success then
    print("PROBE_SESSION_VERIFY status=network_error")
    body = nil
    return
end
if tonumber(status) ~= 200 then
    print("PROBE_SESSION_VERIFY status=" .. tostring(status) .. " result=login_required_or_denied")
    body = nil
    return
end
local decoded, profile = pcall(json.decode, body)
local valid = decoded and type(profile) == "table"
    and (profile.id ~= nil or profile.url_token ~= nil or profile.name ~= nil or profile.name_cn ~= nil)
print("PROBE_SESSION_VERIFY status=200 profile_valid=" .. tostring(valid == true))
body, profile = nil, nil
'''


def normalize_cookie(header: str) -> str:
    if header[:7].lower() == "cookie:":
        header = header[7:].strip()
    if not header or len(header) > 16384 or any(ord(ch) < 32 or ord(ch) == 127 for ch in header):
        raise ValueError("empty, oversized, or multiline Cookie")
    jar: dict[str, str] = {}
    for pair in header.split(";"):
        if "=" not in pair:
            continue
        name, value = pair.strip().split("=", 1)
        name, value = name.strip(), value.strip()
        if name in COOKIE_NAMES and value and len(value) <= 4096:
            jar[name] = value
    if "z_c0" not in jar:
        raise ValueError("Cookie has no z_c0 session value")
    return "; ".join(f"{name}={jar[name]}" for name in sorted(jar))


def ensure_paramiko() -> int | None:
    try:
        import paramiko  # noqa: F401
        return None
    except Exception:
        pass
    candidates = [
        ROOT.parent / "pw4-android" / ".venv" / "Scripts" / "python.exe",
        ROOT.parent / "pw4-android" / ".venv" / "bin" / "python",
    ]
    for python in candidates:
        if python.is_file() and python.resolve() != Path(sys.executable).resolve():
            print("SSH dependency missing in this Python; retrying with pw4-android virtualenv.")
            result = subprocess.run([str(python), str(Path(__file__).resolve())], check=False)
            return result.returncode
    print("ERROR: paramiko is not installed for this Python; no Cookie was requested or sent.", file=sys.stderr)
    print("Run with pw4-android/.venv/Scripts/python.exe, or install it using: py -m pip install paramiko",
          file=sys.stderr)
    return 2


def main() -> int:
    if not PW4_TOOLS.is_dir():
        print("ERROR: PW4 research tools folder not found", file=sys.stderr)
        return 2
    sys.path.insert(0, str(PW4_TOOLS))
    try:
        from lab import connect  # type: ignore
    except Exception as exc:
        print("ERROR: Paramiko/PW4 tools unavailable (" + type(exc).__name__ + ")", file=sys.stderr)
        return 2

    dependency_result = ensure_paramiko()
    if dependency_result is not None:
        return dependency_result

    cookie = getpass.getpass("Paste your browser Cookie header value (input hidden; do not paste it into chat): ").strip()
    try:
        cookie = normalize_cookie(cookie)
    except ValueError as exc:
        print("ERROR: " + str(exc) + "; nothing was sent to the device")
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

        stdout = bytearray()
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            if channel.recv_ready():
                stdout.extend(channel.recv(4096))
            if channel.exit_status_ready() and not channel.recv_ready():
                break
            time.sleep(0.05)
        if not channel.exit_status_ready():
            print("ERROR: session check timed out; no response body was collected")
            return 1
        lines = [line for line in stdout.decode("utf-8", "replace").splitlines()
                 if line.startswith("PROBE_SESSION_VERIFY ")]
        for line in lines:
            print(line)
        if channel.recv_exit_status() != 0:
            print("ERROR: device session check exited abnormally")
            return 1
        if lines != ["PROBE_SESSION_VERIFY status=200 profile_valid=true"]:
            return 0

        try:
            try:
                sftp.remove(REMOTE_IMPORT + ".tmp")
            except OSError:
                pass
            with sftp.file(REMOTE_IMPORT + ".tmp", "w") as import_file:
                import_file.write(str(int(time.time())) + "\n" + cookie + "\n")
            sftp.chmod(REMOTE_IMPORT + ".tmp", 0o600)
            try:
                sftp.remove(REMOTE_IMPORT)
            except OSError:
                pass
            sftp.rename(REMOTE_IMPORT + ".tmp", REMOTE_IMPORT)
            print("PROBE_SESSION handoff=ready expires_seconds=" + str(IMPORT_TTL_SECONDS))
        except Exception as exc:
            print("PROBE_SESSION handoff=failed error=" + type(exc).__name__)
            return 1
        return 0
    except Exception as exc:
        print("ERROR: session import probe failed (" + type(exc).__name__ + ")")
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
            try:
                sftp.remove(REMOTE_IMPORT + ".tmp")
            except Exception:
                pass
            sftp.close()
        if client is not None:
            client.close()


if __name__ == "__main__":
    raise SystemExit(main())
