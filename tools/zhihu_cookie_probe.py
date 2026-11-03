"""One-shot, memory-only test of a user's own Zhihu browser cookie on a PW4.

The cookie is read with getpass, sent over the existing SSH connection via
stdin, used only for two read-only requests, and never written to disk/logs.
"""
from __future__ import annotations

import getpass
import io
import re
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PW4_TOOLS = ROOT.parent / "pw4-android" / "tools"
REMOTE_LUA = "/tmp/zhihu-cookie-probe.lua"
REMOTE_IMPORT = "/tmp/zhihu-cookie-import"
IMPORT_TTL_SECONDS = 600

LUA = r'''require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):wrap({ language = "zh_CN" })
require("gettext").changeLang("zh_CN")
local answer_id = io.read("*l") or ""
local cookie = io.read("*l") or ""
cookie = cookie:gsub("^%s*Cookie:%s*", "")
if not answer_id:match("^%d+$") or cookie == "" or #cookie > 16384 or cookie:find("[\r\n]") then
    print("PROBE_INPUT invalid_cookie_header")
    return
end
local cookie_names = { _xsrf = true, _zap = true, d_c0 = true, BEC = true, sec_token = true, z_c0 = true }
local jar, cookie_parts = {}, {}
for pair in cookie:gmatch("[^;]+") do
    local name, value = pair:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
    if name and cookie_names[name] and value ~= "" and #value <= 4096 then jar[name] = value end
end
if not jar.z_c0 then print("PROBE_INPUT missing_session_cookie") cookie = nil return end
for name, value in pairs(jar) do cookie_parts[#cookie_parts + 1] = name .. "=" .. value end
table.sort(cookie_parts)
cookie = table.concat(cookie_parts, "; ")
local json = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
package.path = "/mnt/us/koreader/plugins/zhihu.koplugin/?.lua;" .. package.path
local Renderer = require("zhihu_renderer")
local function get(url)
    local chunks = {}
    local headers = {
        ["User-Agent"] = "Zhihu-KOReader/0.3 (user-initiated reader)",
        ["Accept"] = "application/json",
        ["Cookie"] = cookie,
    }
    socketutil:set_timeout(12, 18)
    local ok, success, status, response_headers = pcall(http.request, {
        url = url, method = "GET", redirect = false, headers = headers,
        sink = ltn12.sink.table(chunks),
    })
    headers.Cookie = nil
    if not ok or not success then return nil, nil, nil end
    return tonumber(status), table.concat(chunks), response_headers
end
local function challenged(status, body, headers)
    local location = headers and (headers.location or headers.Location) or ""
    return (status and status >= 300 and status < 400 and tostring(location):find("/account/unhuman", 1, true) ~= nil)
        or body:find("/account/unhuman", 1, true) ~= nil
        or body:find("人机验证", 1, true) ~= nil
        or body:find("40352", 1, true) ~= nil
        or body:find("40362", 1, true) ~= nil
end
local hot_url = "https://api.zhihu.com/topstory/hot-list?limit=50"
local hot_status, hot_body, hot_headers = get(hot_url)
if not hot_status then print("PROBE_HOT status=network_error") return end
if challenged(hot_status, hot_body, hot_headers) then
    print("PROBE_HOT status=" .. hot_status .. " result=verification_required")
    cookie, hot_body = nil, nil
    return
end
if hot_status ~= 200 then
    print("PROBE_HOT status=" .. hot_status .. " result=denied_or_unavailable")
    cookie, hot_body = nil, nil
    return
end
local ok, hot = pcall(json.decode, hot_body)
if not ok or type(hot) ~= "table" or type(hot.data) ~= "table" then
    print("PROBE_HOT status=200 result=invalid_response")
    cookie, hot_body, hot = nil, nil, nil
    return
end
print("PROBE_HOT status=200 items=" .. #hot.data)
hot_body, hot = nil, nil
local me_status, me_body, me_headers = get("https://www.zhihu.com/api/v4/me")
if not me_status then print("PROBE_SESSION_VERIFY status=network_error") cookie = nil return end
if challenged(me_status, me_body, me_headers) then
    print("PROBE_SESSION_VERIFY status=" .. me_status .. " result=verification_required")
    cookie, me_body = nil, nil
    return
end
if me_status ~= 200 then
    print("PROBE_SESSION_VERIFY status=" .. me_status .. " result=login_required_or_denied")
    cookie, me_body = nil, nil
    return
end
local mok, profile = pcall(json.decode, me_body)
local profile_valid = mok and type(profile) == "table"
    and (profile.id ~= nil or profile.url_token ~= nil or profile.name ~= nil or profile.name_cn ~= nil)
print("PROBE_SESSION_VERIFY status=200 profile_valid=" .. tostring(profile_valid == true))
me_body, profile = nil, nil
if not profile_valid then cookie = nil return end
local include = "content,excerpt,paid_info,content_need_truncated,force_login_when_click_read_more"
local answer_url = "https://www.zhihu.com/api/v4/answers/" .. answer_id
    .. "?include=" .. socket_url.escape(include)
local answer_status, answer_body, answer_headers = get(answer_url)
if not answer_status then print("PROBE_ANSWER status=network_error") cookie, answer_body = nil, nil return end
if challenged(answer_status, answer_body, answer_headers) then
    print("PROBE_ANSWER status=" .. answer_status .. " result=verification_required")
    cookie, answer_body = nil, nil
    return
end
if answer_status ~= 200 then
    print("PROBE_ANSWER status=" .. answer_status .. " result=denied_or_unavailable")
    cookie, answer_body = nil, nil
    return
end
local aok, result = pcall(json.decode, answer_body)
if not aok or type(result) ~= "table" then
    print("PROBE_ANSWER status=200 result=invalid_response")
    cookie, answer_body, result = nil, nil, nil
    return
end
local answer = result
local content = answer and type(answer.content) == "string" and answer.content or ""
local excerpt = answer and type(answer.excerpt) == "string" and answer.excerpt or ""
local paid = answer and (answer.is_paid == true or answer.is_payed == true or answer.is_purchased == false)
local paid_info = answer and type(answer.paid_info) == "table" and answer.paid_info or {}
paid = paid or paid_info.is_paid == true or paid_info.is_payed == true or paid_info.is_purchased == false
    or paid_info.has_purchased == false or paid_info.need_pay == true or (tonumber(paid_info.price) or 0) > 0
local truncated = answer and (answer.content_need_truncated == true or answer.force_login_when_click_read_more == true)
local plain_content = Renderer.text(content)
local plain_excerpt = Renderer.text(excerpt)
local excerpt_prefix = plain_excerpt ~= "" and plain_content:sub(1, #plain_excerpt) == plain_excerpt
print("PROBE_ANSWER status=200 content_bytes=" .. #content .. " plain_bytes=" .. #plain_content
    .. " excerpt_bytes=" .. #excerpt
    .. " content_present=" .. tostring(content ~= "")
    .. " answer_id_match=" .. tostring(tostring(answer.id or "") == answer_id)
    .. " paid_marker=" .. tostring(paid == true)
    .. " truncated_marker=" .. tostring(truncated == true) .. " excerpt_prefix=" .. tostring(excerpt_prefix))
answer_body, result, content, excerpt, answer = nil, nil, nil, nil, nil

local comments_url = "https://www.zhihu.com/api/v4/comment_v5/answers/" .. answer_id
    .. "/root_comment?order_by=score&limit=20&offset="
local comment_status, comment_body, comment_headers = get(comments_url)
if not comment_status then print("PROBE_COMMENTS status=network_error") cookie = nil return end
if challenged(comment_status, comment_body, comment_headers) then
    print("PROBE_COMMENTS status=" .. comment_status .. " result=verification_required")
    cookie, comment_body = nil, nil
    return
end
if comment_status ~= 200 then
    print("PROBE_COMMENTS status=" .. comment_status .. " result=denied_or_unavailable")
    cookie, comment_body = nil, nil
    return
end
local cok, comments = pcall(json.decode, comment_body)
if not cok or type(comments) ~= "table" or type(comments.data) ~= "table" or type(comments.paging) ~= "table" then
    print("PROBE_COMMENTS status=200 result=invalid_response")
    cookie, comment_body, comments = nil, nil, nil
    return
end
local nonempty = 0
for _, item in ipairs(comments.data) do
    if type(item) == "table" and type(item.content) == "string" and item.content ~= "" then nonempty = nonempty + 1 end
end
print("PROBE_COMMENTS status=200 items=" .. #comments.data .. " nonempty=" .. nonempty
    .. " is_end=" .. tostring(comments.paging.is_end)
    .. " next_cursor=" .. tostring(type(comments.paging.next) == "string" and comments.paging.next ~= ""))
local next_cursor = comments.paging.next
local comments_end = comments.paging.is_end == true
comment_body, comments = nil, nil
if not comments_end then
    local base = "https://www.zhihu.com/api/v4/comment_v5/answers/" .. answer_id .. "/root_comment"
    local next_url
    if type(next_cursor) == "string" and #next_cursor <= 2048
        and not next_cursor:find("[%c%s#]") then
        local full_prefix = base .. "?"
        if next_cursor:sub(1, #full_prefix) == full_prefix then
            next_url = next_cursor
        elseif next_cursor:sub(1, 1) == "?" then
            next_url = base .. next_cursor
        end
    end
    if not next_url then
        print("PROBE_COMMENTS_PAGE2 result=invalid_cursor")
        cookie = nil
        return
    end
    local page2_status, page2_body, page2_headers = get(next_url)
    if not page2_status then print("PROBE_COMMENTS_PAGE2 status=network_error") cookie = nil return end
    if challenged(page2_status, page2_body, page2_headers) then
        print("PROBE_COMMENTS_PAGE2 status=" .. page2_status .. " result=verification_required")
        cookie, page2_body = nil, nil
        return
    end
    if page2_status ~= 200 then
        print("PROBE_COMMENTS_PAGE2 status=" .. page2_status .. " result=denied_or_unavailable")
        cookie, page2_body = nil, nil
        return
    end
    local p2ok, page2 = pcall(json.decode, page2_body)
    if not p2ok or type(page2) ~= "table" or type(page2.data) ~= "table" or type(page2.paging) ~= "table" then
        print("PROBE_COMMENTS_PAGE2 status=200 result=invalid_response")
        cookie, page2_body, page2 = nil, nil, nil
        return
    end
    local page2_nonempty = 0
    for _, item in ipairs(page2.data) do
        if type(item) == "table" and type(item.content) == "string" and item.content ~= "" then page2_nonempty = page2_nonempty + 1 end
    end
    print("PROBE_COMMENTS_PAGE2 status=200 items=" .. #page2.data .. " nonempty=" .. page2_nonempty
        .. " is_end=" .. tostring(page2.paging.is_end)
        .. " next_cursor=" .. tostring(type(page2.paging.next) == "string" and page2.paging.next ~= ""))
    cookie, page2_body, page2 = nil, nil, nil
end
cookie, next_cursor, plain_content, plain_excerpt = nil, nil, nil, nil
'''


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

    answer_url = input("Paste a long Zhihu answer URL (visible input): ").strip()
    match = re.fullmatch(r"https?://(?:www\.)?zhihu\.com/question/\d+/answer/(\d+)/?(?:[?#].*)?", answer_url)
    if not match:
        print("ERROR: expected a Zhihu URL like https://www.zhihu.com/question/<id>/answer/<id>")
        return 2
    answer_id = match.group(1)
    cookie = getpass.getpass("Paste your browser Cookie header value (input hidden; do not paste it into chat): ").strip()
    if cookie[:7].lower() == "cookie:":
        cookie = cookie[7:].strip()
    if not cookie:
        print("ERROR: no input was received; nothing was sent to the device")
        return 2
    if "\r" in cookie or "\n" in cookie:
        print("ERROR: input contains line breaks; paste the single-line Cookie value")
        return 2
    if len(cookie) > 16384:
        print("ERROR: input exceeds the allowed size; nothing was sent to the device")
        return 2

    client = None
    sftp = None
    channel = None
    try:
        client = connect()
        sftp = client.open_sftp()
        with sftp.file(REMOTE_LUA, "w") as remote_file:
            remote_file.write(LUA)
        channel = client.get_transport().open_session(timeout=8)
        channel.settimeout(8)
        channel.exec_command("cd /mnt/us/koreader && ./luajit " + REMOTE_LUA)
        channel.sendall(answer_id.encode("ascii") + b"\n" + cookie.encode("utf-8") + b"\n")
        channel.shutdown_write()

        stdout = bytearray()
        stderr = bytearray()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if channel.recv_ready():
                stdout.extend(channel.recv(8192))
            if channel.recv_stderr_ready():
                stderr.extend(channel.recv_stderr(8192))
            if channel.exit_status_ready() and not channel.recv_ready() and not channel.recv_stderr_ready():
                break
            time.sleep(0.05)
        if not channel.exit_status_ready():
            print("ERROR: probe timed out; no credential or response body was collected")
            return 1
        output_lines = [line for line in stdout.decode("utf-8", "replace").splitlines()
                        if line.startswith("PROBE_")]
        for line in output_lines:
            print(line)
        if channel.recv_exit_status() != 0:
            print("ERROR: device probe exited abnormally")
            return 1
        answer_ok = any("PROBE_ANSWER status=200" in line
                        and "content_present=true" in line and "answer_id_match=true" in line
                        and "paid_marker=false" in line and "truncated_marker=false" in line
                        for line in output_lines)
        comments_ok = any(line.startswith("PROBE_COMMENTS status=200 ") for line in output_lines)
        page2_ok = any(line.startswith("PROBE_COMMENTS_PAGE2 status=200 ") for line in output_lines)
        session_ok = any(line == "PROBE_SESSION_VERIFY status=200 profile_valid=true" for line in output_lines)
        if session_ok and answer_ok and comments_ok and page2_ok:
            try:
                try:
                    sftp.remove(REMOTE_IMPORT + ".tmp")
                except OSError:
                    pass
                payload = str(int(time.time())) + "\n" + cookie + "\n"
                with sftp.file(REMOTE_IMPORT + ".tmp", "w") as import_file:
                    import_file.write(payload)
                sftp.chmod(REMOTE_IMPORT + ".tmp", 0o600)
                try:
                    sftp.remove(REMOTE_IMPORT)
                except OSError:
                    pass
                sftp.rename(REMOTE_IMPORT + ".tmp", REMOTE_IMPORT)
                print("PROBE_SESSION handoff=ready expires_seconds=" + str(IMPORT_TTL_SECONDS))
            except Exception as exc:
                print("PROBE_SESSION handoff=failed error=" + type(exc).__name__)
        return 0
    except Exception as exc:
        print("ERROR: probe failed (" + type(exc).__name__ + ")")
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
