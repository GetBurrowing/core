"""Burrow install manifest tooling (ADR 0053).

Standard library only (Python 3.11+, ``tomllib``) so it runs on a bare
customer host or a Mac with no pip step. Run with
``PYTHONPATH=deployment/installer python3 -m suite_install <command>``.
"""

SCHEMA_VERSION = 1
