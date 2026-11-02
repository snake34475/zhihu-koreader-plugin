"""Run offline tests in LuaJIT 2.1 or Lua 5.4. Python supplies only JSON and temp paths.

Usage: python3 tests/run.py [--deps PATH_TO_LUPA]
Development dependency: pip install lupa. Nothing is added to the device plugin.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--deps", type=Path)
args = parser.parse_args()
if args.deps:
    sys.path.insert(0, str(args.deps))
try:
    from lupa.luajit21 import LuaRuntime, lua_type
except ImportError:
    try:
        from lupa.lua54 import LuaRuntime, lua_type
    except ImportError:
        raise SystemExit("Install the development dependency: python -m pip install lupa")

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)


def to_lua(value):
    if isinstance(value, dict):
        return lua.table_from({k: to_lua(v) for k, v in value.items()})
    if isinstance(value, list):
        return lua.table_from([to_lua(v) for v in value])
    return value


def from_lua(value):
    if lua_type(value) != "table":
        return value
    keys = list(value.keys())
    if keys and all(type(k) is int for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [from_lua(value[k]) for k in range(1, len(keys) + 1)]
    return {str(k): from_lua(v) for k, v in value.items()}


def decode(text):
    return to_lua(json.loads(text))


def encode(value):
    return json.dumps(from_lua(value), ensure_ascii=False, allow_nan=False)


lua.globals().test_json_decode = decode
lua.globals().test_json_encode = encode
lua.globals().plugin_root = root.as_posix()
if os.name == "nt":
    # Device uses POSIX rename-over-existing semantics; Windows CRT rename does not.
    def posix_rename(source, destination):
        try:
            os.replace(source, destination)
            return True
        except OSError:
            return None, "rename failed"
    lua.globals().test_posix_rename = posix_rename
    lua.execute("os.rename = test_posix_rename")
with tempfile.TemporaryDirectory(prefix="zhihu-koreader-tests-") as temp:
    lua.globals().test_directory = Path(temp).as_posix()
    lua.execute('package.path = plugin_root .. "/?.lua;" .. package.path')
    lua.execute('package.preload["json"] = function() return {decode=test_json_decode, encode=test_json_encode} end')
    # Compile every Lua file, including the KOReader entry point and UI.
    for path in sorted(root.rglob("*.lua")):
        lua.globals().syntax_path = path.as_posix()
        lua.execute("assert(loadfile(syntax_path))")
    lua.execute((root / "tests" / "run.lua").read_text(encoding="utf-8"))
