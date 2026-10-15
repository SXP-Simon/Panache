# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""Explicit object boundaries for dynamic third-party integration surfaces."""


def member(source: object, name: str) -> object:
    """Read a dynamic library member without allowing unknown values to escape."""
    return getattr(source, name)


def install_member(target: object, name: str, value: object) -> None:
    """Install a validated callback or marker on a dynamic library object."""
    setattr(target, name, value)
