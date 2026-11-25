"""Shared helpers for MCP stdio integration tests."""

import os
import sqlite3
from contextlib import asynccontextmanager, closing
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

DB = "drafts.sqlite3"


@asynccontextmanager
async def isolated_session(binary, home):
    env = dict.fromkeys(("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME"), str(home))
    env.update(PANACHE_MCP_HOME=str(home), PANACHE_USER_FONT_DIR=str(home / "fonts"))
    for name in ("PANACHE_FONT_DIR", "PANACHE_MARKDOWN_WORKER"):
        if name in os.environ:
            env[name] = str(Path(os.environ[name]).resolve())
    params = StdioServerParameters(command=str(binary), cwd=str(home), env=env)
    async with stdio_client(params) as streams, ClientSession(*streams) as client:
        yield client, await client.initialize()


def open_db(home):
    return closing(sqlite3.connect((home / DB).as_uri() + "?mode=ro", uri=True))


def clone_home(root, name):
    home = root / name
    home.mkdir()
    with open_db(root) as source, closing(sqlite3.connect(home / DB)) as target:
        source.backup(target)
    return home


async def call(client, name, **args):
    result = await client.call_tool(name, args)
    assert not result.isError, (name, result.content[0])
    return result
