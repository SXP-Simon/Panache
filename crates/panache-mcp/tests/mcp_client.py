"""Shared assertions for MCP stdio integration tests."""


async def call(client, name, **args):
    result = await client.call_tool(name, args)
    assert not result.isError, (name, result.content[0])
    return result
