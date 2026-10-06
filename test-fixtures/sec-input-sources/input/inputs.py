"""Synthetic untrusted-input entry points."""
import sys
from flask import request


def http_handlers():
    body = request.json
    form = request.form
    query = request.args
    return body, form, query


def cli_argv():
    return sys.argv


def stdin_read():
    return sys.stdin.read()


def stdin_other_forms():
    lines = []
    for raw in sys.stdin:
        lines.append(raw)
    first = sys.stdin.readline()
    rest = sys.stdin.readlines()
    data = sys.stdin.buffer.read()
    return lines, first, rest, data


def user_input():
    return input("? ")


def file_open(path):
    return open(path)
